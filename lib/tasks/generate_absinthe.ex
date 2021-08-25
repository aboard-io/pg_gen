defmodule Mix.Tasks.PgGen.GenerateAbsinthe do
  use Mix.Task
  alias AbsintheGen.{SchemaGenerator, EnumGenerator}

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
      |> Enum.map(fn table -> SchemaGenerator.generate(table, schema) end)

    def_strings =
      type_defs
      |> Enum.reduce("", fn {_name, def}, acc -> "#{acc}\n\n#{def}" end)

    enum_defs =
      enum_types
      |> Enum.map(&EnumGenerator.to_string/1)
      |> Enum.join("\n\n")

    query_defs =
      filtered_tables
      |> Enum.map(&SchemaGenerator.generate_queries/1)
      |> Enum.join("\n\n")

    mutation_and_input_defs =
      filtered_tables
      |> Enum.map(&SchemaGenerator.generate_mutations/1)

    {mutations, inputs} =
      mutation_and_input_defs
      |> Enum.reduce({[], []}, fn [mutation, input], {mut, inp} = acc ->
        {[mutation | mut], [input | inp]}
      end)

    mutation_strings = Enum.join(mutations, "\n\n")
    input_strings = Enum.join(inputs, "\n\n")

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
        input_strings
      )
      |> Code.format_string!()
    )

    resolver_path = PgGen.LocalConfig.get_graphql_resolver_path()

    if !File.exists?(resolver_path) do
      File.mkdir!(resolver_path)
    end

    type_defs
    |> Enum.map(fn {name, _} -> SchemaGenerator.generate_resolver(name) end)
    |> Enum.map(fn {name, file} -> File.write!("#{resolver_path}/#{name}.ex", file) end)

    module_name = "#{PgGen.LocalConfig.get_app_name()}_web.Schema" |> Macro.camelize()

    # type_names = Enum.map(type_defs, fn {name, _} -> name end)
    # File.write!("#{file_path}/schema.ex", schema_template(module_name, type_names))

    File.write!("#{types_path}/json.ex", json_type(module_name))
    File.write!("#{types_path}/uuid4.ex", uuid_type(module_name))

    #
    # ecto_json_type_path = "#{file_path}/ecto_json.ex"
    #
    # if !File.exists?(ecto_json_type_path) do
    #   File.write!(ecto_json_type_path, TableGenerator.ecto_json_type())
    # end
    # Mix.Task.run("app.start")

    # AbsintheGen.introspect_schema(url)
    # |> AbsintheGen.process_schema()

    # AbsintheGen.process_schema(File.read!("./static/introspection_query_result.json"))
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
  end
end
