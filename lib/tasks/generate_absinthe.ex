defmodule Mix.Tasks.PgGen.GenerateAbsinthe do
  use Mix.Task
  alias AbsintheGen.{SchemaGenerator, EnumGenerator}
  alias PgGen.Utils

  @doc """
  Generate Absinthe schema
  """
  def run(args) do
    {options, _, _} =
      OptionParser.parse(args,
        strict: [schema: :string, database: :string],
        aliases: [d: :database, s: :schema]
      )

    defaults = PgGen.LocalConfig.get_db()

    Mix.Task.run("app.start")

    database_config =
      case options[:database] do
        nil ->
          defaults

        database ->
          Map.put(defaults, :database, database)
      end

    schema = options[:schema] || "public"
    IO.puts("TODO: Check if schema exists with Introspection.run_query")

    file_path = PgGen.LocalConfig.get_graphql_schema_path()
    types_path = file_path <> "/types"

    if !File.exists?(file_path) do
      File.mkdir!(file_path)
    end

    if !File.exists?(types_path) do
      File.mkdir!(types_path)
    end

    %{tables: tables, enum_types: enum_types} =
      Introspection.run(database_config, String.split(schema, ","))
      |> Introspection.Model.from_introspection(schema)

    # Filter out tables that aren't selectable/insertable/updatable/deletable
    filtered_tables =
      tables
      |> SchemaGenerator.filter_accessible()

    type_defs =
      filtered_tables
      |> Enum.map(fn table -> SchemaGenerator.generate_types(table, filtered_tables, schema) end)

    connection_defs =
      filtered_tables
      |> Enum.map(&SchemaGenerator.generate_connection/1)
      |> Enum.join("\n\n")

    def_strings =
      type_defs
      |> Enum.reduce("", fn {_name, def}, acc -> "#{acc}\n\n#{def}" end)

    enum_defs =
      enum_types
      |> Enum.map(&EnumGenerator.to_string/1)
      |> Enum.join("\n\n")

    enum_filters =
      enum_types
      |> Enum.map(fn %{name: name} -> SchemaGenerator.generate_input_filter(name) end)
      |> Enum.join("\n\n")

    scalar_filters = SchemaGenerator.generate_scalar_filters()
    scalar_and_enum_filters = scalar_filters <> "\n\n" <> enum_filters

    query_defs =
      filtered_tables
      |> Enum.map(&SchemaGenerator.generate_queries/1)
      |> Enum.join("\n\n")

    create_mutation_and_input_defs =
      filtered_tables
      |> Enum.map(&SchemaGenerator.generate_insertable/1)

    {create_mutations, create_inputs} =
      create_mutation_and_input_defs
      |> Enum.reduce({[], []}, fn [mutation, input], {mut, inp} ->
        {[mutation | mut], [input | inp]}
      end)

    update_mutation_and_input_defs =
      filtered_tables
      |> Enum.map(&SchemaGenerator.generate_updatable/1)

    {update_mutations, update_inputs} =
      update_mutation_and_input_defs
      |> Enum.reduce({[], []}, fn [mutation, input], {mut, inp} ->
        {[mutation | mut], [input | inp]}
      end)

    delete_mutations =
      filtered_tables
      |> Enum.map(&SchemaGenerator.generate_deletable/1)

    mutation_strings = Enum.join(create_mutations ++ update_mutations ++ delete_mutations, "\n\n")
    input_strings = Enum.join(create_inputs ++ update_inputs, "\n\n")

    dataloader_strings =
      filtered_tables
      |> SchemaGenerator.generate_dataloader()

    # |> Enum.map(fn {name, file} ->
    #   File.write!("#{types_path}/#{name |> Inflex.singularize()}.ex", file)
    # end)
    File.write!(
      "#{file_path}/types.ex",
      SchemaGenerator.types_template(
        def_strings,
        enum_defs,
        query_defs,
        dataloader_strings,
        mutation_strings,
        input_strings,
        scalar_and_enum_filters,
        connection_defs
      )
      |> Utils.format_code!()
    )

    resolver_path = PgGen.LocalConfig.get_graphql_resolver_path()

    if !File.exists?(resolver_path) do
      File.mkdir!(resolver_path)
    end

    type_defs
    |> Enum.map(fn {name, _} ->
      SchemaGenerator.generate_resolver(
        name,
        Enum.find(filtered_tables, fn %{name: t_name} ->
          t_name == name
        end)
      )
    end)
    |> Enum.map(fn {name, file} -> File.write!("#{resolver_path}/#{name}.ex", file) end)

    module_name = "#{PgGen.LocalConfig.get_app_name()}_web.Schema" |> Macro.camelize()

    File.write!(
      "#{resolver_path}/connections.ex",
      connections_resolver_template(module_name |> String.split(".Schema") |> hd)
    )

    File.write!("#{types_path}/json.ex", json_type(module_name))
    File.write!("#{types_path}/uuid4.ex", uuid_type(module_name))
    File.write!("#{types_path}/cursor.ex", cursor_type(module_name))
    File.write!("#{types_path}/uuid62.ex", uuid62_type(module_name))
  end

  def schema_template(module_name, type_names) do
    imports =
      Enum.map(type_names, fn name ->
        "import_types #{module_name}.#{name |> Inflex.singularize() |> Macro.camelize()}Types"
      end)
      |> Enum.join("\n")

    """
    defmodule #{module_name} do
      use Absinthe.Schema
      #{imports}

      # query do
      #   @desc "Get a list of blog posts"
      #   field :posts, list_of(:post) do
      #     resolve &Blog.PostResolver.all/2
      #   end
      # end
    end
    """
  end

  def json_type(module_name) do
    """
      defmodule #{module_name}.Types.Custom.JSON do
      @moduledoc \"\"\"
      The Json scalar type allows arbitrary JSON values to be passed in and out.
      Requires `{ :jason, "~> 1.1" }` package: https://github.com/michalmuskala/jason
      \"\"\"
      use Absinthe.Schema.Notation

      scalar :json, name: "Json" do
        description(\"\"\"
        The `Json` scalar type represents arbitrary json string data, represented as UTF-8
        character sequences. The Json type is most often used to represent a free-form
        human-readable json string.
        \"\"\")

        serialize(&encode/1)
        parse(&decode/1)
      end

      @spec decode(Absinthe.Blueprint.Input.String.t()) :: {:ok, term()} | :error
      @spec decode(Absinthe.Blueprint.Input.Null.t()) :: {:ok, nil}
      defp decode(%Absinthe.Blueprint.Input.String{value: value}) do
        case Jason.decode(value) do
          {:ok, result} -> {:ok, result}
          _ -> :error
        end
      end

      defp decode(%Absinthe.Blueprint.Input.Null{}) do
        {:ok, nil}
      end

      defp decode(_) do
        :error
      end

      defp encode(value), do: value
    end
    """
    |> Utils.format_code!()
  end

  def uuid62_type(module_name) do
    """
    defmodule #{module_name}.Types.Custom.UUID62 do
      use Absinthe.Schema.Notation

      scalar :uuid62, name: "UUID62" do
        description(\"\"\"
        The `UUID62` scalar type represents UUID4 compliant string encoded to base62.
        \"\"\")

        serialize(&encode/1)
        parse(&decode/1)
      end

      @spec decode(Absinthe.Blueprint.Input.String.t()) :: {:ok, term()} | :error
      @spec decode(Absinthe.Blueprint.Input.Null.t()) :: {:ok, nil}
      defp decode(%Absinthe.Blueprint.Input.Null{}) do
        {:ok, nil}
      end

      defp decode(%{value: value}) do
        {:ok, Base62UUID.decode!(value)}
      end

      defp decode(_) do
        :error
      end

      defp encode(val) do
        Base62UUID.encode!(val)
      end
    end
    """
  end

  def uuid_type(module_name) do
    """
      defmodule #{module_name}.Types.Custom.UUID4 do
      @moduledoc \"\"\"
      The UUID4 scalar type allows UUID4 compliant strings to be passed in and out.
      Requires `{ :ecto, ">= 0.0.0" }` package: https://github.com/elixir-ecto/ecto
      \"\"\"
      use Absinthe.Schema.Notation

      alias Ecto.UUID

      scalar :uuid4, name: "UUID4" do
        description(\"\"\"
        The `UUID4` scalar type represents UUID4 compliant string data, represented as UTF-8
        character sequences. The UUID4 type is most often used to represent unique
        human-readable ID strings.
        \"\"\")

        serialize(&encode/1)
        parse(&decode/1)
      end

      @spec decode(Absinthe.Blueprint.Input.String.t()) :: {:ok, term()} | :error
      @spec decode(Absinthe.Blueprint.Input.Null.t()) :: {:ok, nil}
      defp decode(%Absinthe.Blueprint.Input.String{value: value}) do
        UUID.cast(value)
      end

      defp decode(%Absinthe.Blueprint.Input.Null{}) do
        {:ok, nil}
      end

      defp decode(_) do
        :error
      end

      defp encode(value), do: value
    end
    """
    |> Utils.format_code!()
  end

  def cursor_type(module_name) do
    """
      defmodule #{module_name}.Types.Custom.Cursor do
        @moduledoc \"\"\"
        The Cursor scalar type
        \"\"\"
        use Absinthe.Schema.Notation

        scalar :cursor, name: "Cursor" do
          description(\"\"\"
          A cursor that can be used for pagination.
          \"\"\")

          serialize(&encode/1)
          parse(&decode/1)
        end

        @spec decode(Absinthe.Blueprint.Input.String.t()) :: {:ok, term()} | :error
        @spec decode(Absinthe.Blueprint.Input.Null.t()) :: {:ok, nil}
        defp decode(%Absinthe.Blueprint.Input.String{value: value}) do
          [dir, col_name, value] = value |> Base.decode64!() |> Jason.decode!()
          {:ok, {{String.to_existing_atom(dir), String.to_existing_atom(col_name)}, value}}
        end

        defp decode(%Absinthe.Blueprint.Input.Null{}) do
          {:ok, nil}
        end

        defp decode(_) do
          :error
        end

        defp encode(nil), do: nil
        defp encode(""), do: nil
        defp encode({{dir, col_name}, value}),
          do: [dir, col_name, value] |> Jason.encode!() |> Base.encode64()

      end

    """
    |> Utils.format_code!()
  end

  def connections_resolver_template(module_name) do
    """
    defmodule #{module_name}.Resolvers.Connections do
      import Absinthe.Resolution.Helpers, only: [on_load: 2]

      @doc \"\"\"
      Usage in an Absinthe schema:

      ```elixir
      resolve Connections.resolve(Example.Repo.Workflow, :workflows_by_workflow_members)
      ```
      \"\"\"
      def resolve(repo, field_name) do
        fn parent, args, %{context: %{loader: loader}} ->
          loader
          |> Dataloader.load(repo, {field_name, args}, parent)
          |> on_load(fn loader_with_data ->
            nodes =
              Dataloader.get(
                loader_with_data,
                repo,
                {field_name, args},
                parent
              )

            # If user wants last n records, Repo.Filter.apply is swapping asc/desc order
            # to make the query work with  alimit.
            # Here we put the records back in the expected order
            nodes =
              case is_integer(Map.get(args, :last)) do
                false ->
                  nodes

                true ->
                  if is_integer(Map.get(args, :first)), do: nodes, else: Enum.reverse(nodes)
              end

            # passing args to children so we can use order_by to generate cursors
            {:ok, %{nodes: nodes, args: args}}
          end)
        end
      end

          @doc \"\"\"
          Usage in an Absinthe schema:

          ```elixir
          resolve Connections.resolve_page_info()
          ```
          \"\"\"
      def resolve_page_info() do
        fn %{nodes: nodes, args: parent_args}, _, _ ->
          {_dir, col} =
            order_by =
            case Map.get(parent_args, :order_by) do
              nil -> raise "All queries should have a default order_by"
              [{dir, col} | _] -> {dir, col}
              {dir, col} -> {dir, col}
            end

          start_cursor_val =
            case nodes do
              [] -> nil
              [node | _] -> {order_by, Map.get(node, col)}
            end

          end_cursor_val =
            case Enum.reverse(nodes) do
              [] -> nil
              [node | _] -> {order_by, Map.get(node, col)}
            end

          {:ok, %{start_cursor: start_cursor_val, end_cursor: end_cursor_val}}
        end
      end
    end
    """
    |> Utils.format_code!()
  end
end
