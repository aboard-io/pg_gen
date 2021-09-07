defmodule AbsintheGen.SchemaGenerator do
  alias PgGen.{Utils, Builder}
  alias AbsintheGen.FieldGenerator
  import Utils, only: [get_table_names: 1]

  def generate_types(%{name: name, attributes: attributes} = table, tables, _schema) do
    IO.puts("====================#{name}===============")

    dataloader_prefix = PgGen.LocalConfig.get_app_name() |> Macro.camelize()

    built_attributes =
      attributes
      |> Enum.map(&Builder.build/1)

    attributes =
      built_attributes
      |> Utils.deduplicate_associations()
      |> Enum.map(fn {a, b, c, opts} ->
        {a, b, c,
         Keyword.put_new(opts, :resolve_method, {:dataloader, prefix: dataloader_prefix})}
      end)
      |> Enum.map(fn attr ->
        FieldGenerator.to_string(attr)
      end)
      |> Enum.join("\n")

    references =
      case Map.get(table, :external_references) do
        nil ->
          ""

        references ->
          references
          |> Enum.map(&Builder.build/1)
          |> Utils.deduplicate_associations()
          |> Utils.deduplicate_joins()
          |> Enum.map(fn {a, b, c, opts} ->
            {a, b, c,
             Keyword.put_new(opts, :resolve_method, {:dataloader, prefix: dataloader_prefix})}
          end)
          |> Enum.map(fn attr ->
            # Pass the referenced table so we know if it has indexes we can use in arguments on the field
            FieldGenerator.to_string(
              attr,
              Enum.find(tables, fn %{name: name} ->
                {_, _, rel_table, _} = attr

                %{plural_underscore_table_name: plural_underscore_table_name} =
                  get_table_names(rel_table)

                name == plural_underscore_table_name
              end)
            )
          end)
          |> Enum.join("\n")
      end

    conditions_and_filters = generate_condition_and_filter_input(table)

    order_by_enums =
      if Map.has_key?(table, :indexed_attrs),
        do: generate_order_by_enum(table.name, table.indexed_attrs),
        else: ""

    fields = attributes <> "\n\n" <> references

    conditions_and_input_objects = conditions_and_filters <> "\n\n" <> order_by_enums

    {name, Utils.format_code!(simple_types_template(name, fields, conditions_and_input_objects))}
  end

  def filter_accessible(tables) do
    Enum.filter(tables, &is_accessible/1)
  end

  def is_accessible(%{
        insertable: insertable,
        selectable: selectable,
        updatable: updatable,
        deletable: deletable
      }) do
    insertable || selectable || updatable || deletable
  end

  def is_accessible(_), do: false

  def simple_types_template(name, fields, conditions_and_input_objects) do
    """
      object :#{name |> Inflex.singularize() |> Macro.underscore()} do
        #{fields}
      end

      #{conditions_and_input_objects}
    """
  end

  def types_template(
        types,
        enum_types,
        query_defs,
        dataloader,
        mutations,
        inputs,
        scalar_filters,
        connections,
        subscriptions
      ) do
    module_name = "#{PgGen.LocalConfig.get_app_name() |> Macro.camelize()}"
    module_name_web = "#{module_name}Web"

    """
    defmodule #{module_name_web}.Schema.Types do
      use Absinthe.Schema
      import Absinthe.Resolution.Helpers, only: [dataloader: 1]

      import_types Absinthe.Type.Custom
      import_types(#{module_name_web}.Schema.Types.Custom.JSON)
      import_types(#{module_name_web}.Schema.Types.Custom.UUID4)
      import_types(#{module_name_web}.Schema.Types.Custom.UUID62)
      import_types(#{module_name_web}.Schema.Types.Custom.Cursor)

      alias #{module_name_web}.Resolvers
      alias #{module_name_web}.Resolvers.Connections
      alias #{module_name}.Contexts
      alias #{module_name}.Repo

      #{types}

      #{connections}

      #{scalar_filters}

      #{enum_types}

      object :page_info do
        field :start_cursor, :cursor
        field :end_cursor, :cursor
        field :has_next_page, non_null(:boolean)
        field :has_previous_page, non_null(:boolean)
      end

      query do
        #{query_defs}
      end

      mutation do
        #{mutations}
      end

      #{if subscriptions != "" do
      """
      subscription do
        #{subscriptions}
      end
      """
    end}

      #{inputs}

      #{dataloader}

    end
    """
  end

  def generate_queries(table) do
    generate_selectable(table)
  end

  def generate_selectable(%{selectable: true, name: name} = table) do
    %{
      singular_camelized_table_name: singular_camelized_table_name,
      plural_underscore_table_name: plural_underscore_table_name,
      singular_underscore_table_name: singular_underscore_table_name
    } = get_table_names(name)

    args = FieldGenerator.generate_args_for_object(table)

    """
    field :#{singular_underscore_table_name}, :#{singular_underscore_table_name} do
      arg :id, non_null(:uuid62)
      resolve &Resolvers.#{singular_camelized_table_name}.#{singular_underscore_table_name}/3
    end
    field :#{plural_underscore_table_name}, non_null(:#{singular_underscore_table_name}_connection) do
      #{args}
      resolve &Resolvers.#{singular_camelized_table_name}.#{plural_underscore_table_name}/3
    end
    """
  end

  def generate_selectable(_), do: ""

  def generate_condition_and_filter_input(%{indexed_attrs: indexed_attrs, name: name}) do
    %{singular_underscore_table_name: singular_underscore_table_name} = get_table_names(name)

    condition_fields =
      indexed_attrs
      |> Enum.map(fn {name, type} ->
        type = process_type(type)

        """
        field :#{name}, #{type}
        """
      end)

    filter_fields =
      indexed_attrs
      |> Enum.map(fn {name, type} ->
        type = process_type(type)

        """
        field :#{name}, #{type}_filter
        """
      end)

    """
    input_object :#{singular_underscore_table_name}_condition do
      #{condition_fields}
    end

    input_object :#{singular_underscore_table_name}_filter do
      #{filter_fields}
    end
    """
  end

  def generate_condition_and_filter_input(_), do: ""

  def generate_scalar_filters() do
    ["datetime", "uuid4", "boolean", "string", "date", "integer", "uuid62"]
    |> Enum.map(&generate_input_filter/1)
    |> Enum.join("\n\n")
  end

  def generate_input_filter(type) do
    """
    input_object :#{type}_filter do
      field :is_null, :boolean
      field :equal_to, :#{type}
      field :not_equal_to, :#{type}
      field :greater_than, :#{type}
      field :greater_than_or_equal_to, :#{type}
      field :less_than, :#{type}
      field :less_than_or_equal_to, :#{type}
    end
    """
  end

  def generate_order_by_enum(_name, indexes) when length(indexes) == 0, do: ""

  def generate_order_by_enum(name, indexes) do
    %{
      plural_underscore_table_name: plural_underscore_table_name
    } = get_table_names(name)

    values =
      Enum.map(indexes, fn {name, _type} ->
        """
        value :#{String.upcase(name)}_ASC, as: {:asc, :#{name}}
        value :#{String.upcase(name)}_DESC, as: {:desc, :#{name}}
        """
      end)
      |> Enum.join("\n")

    """
    enum :#{plural_underscore_table_name}_order_by do
      #{values}
    end
    """
  end

  def generate_insertable(%{insertable: true, name: name} = table) do
    %{
      singular_underscore_table_name: singular_underscore_table_name
    } = table_names = get_table_names(name)

    input_name = "create_#{singular_underscore_table_name}_input"
    input_object = generate_input_object(input_name, table.attributes)

    mutation = generate_create_mutation(table_names, input_name)

    [mutation, input_object]
  end

  def generate_insertable(_), do: ["", ""]

  def generate_updatable(%{updatable: true, name: name} = table) do
    primary_key = Enum.find(table.attributes, fn attr -> !is_not_primary_key(attr) end)

    if is_nil(primary_key) do
      ["", ""]
    else
      %{
        singular_underscore_table_name: singular_underscore_table_name
      } = table_names = get_table_names(name)

      input_name = "update_#{singular_underscore_table_name}"
      input_object = generate_update_input_object(input_name, table.attributes)

      mutation = generate_update_mutation(table_names, input_name)

      [mutation, input_object]
    end
  end

  def generate_updatable(_), do: ["", ""]

  def generate_deletable(%{updatable: true, name: name} = table) do
    primary_key = Enum.find(table.attributes, fn attr -> !is_not_primary_key(attr) end)

    if is_nil(primary_key) do
      ["", ""]
    else
      %{
        singular_underscore_table_name: singular_underscore_table_name,
        singular_camelized_table_name: singular_camelized_table_name
      } = get_table_names(name)

      type = process_type(primary_key.type)

      """
      field :delete_#{singular_underscore_table_name}, :#{singular_underscore_table_name} do
        arg :id, non_null(#{type})
        resolve &Resolvers.#{singular_camelized_table_name}.delete_#{singular_underscore_table_name}/3
      end
      """
    end
  end

  def generate_deletable(_), do: ["", ""]

  def generate_create_mutation(
        %{
          singular_camelized_table_name: singular_camelized_table_name,
          singular_underscore_table_name: singular_underscore_table_name
        },
        input_name
      ) do
    """
    field :create_#{singular_underscore_table_name}, :#{singular_underscore_table_name} do
      arg :input, non_null(:#{input_name})
      resolve &Resolvers.#{singular_camelized_table_name}.create_#{singular_underscore_table_name}/3
    end
    """
  end

  def generate_update_mutation(
        %{
          singular_camelized_table_name: singular_camelized_table_name,
          singular_underscore_table_name: singular_underscore_table_name
        },
        input_name
      ) do
    """
    field :update_#{singular_underscore_table_name}, :#{singular_underscore_table_name} do
      arg :input, non_null(:#{input_name}_input)
      resolve &Resolvers.#{singular_camelized_table_name}.update_#{singular_underscore_table_name}/3
    end
    """
  end

  def generate_input_object(input_object_name, attributes) do
    fields =
      attributes
      |> Enum.map(&generate_field/1)
      |> Enum.join("\n")

    """
    input_object :#{input_object_name} do
      #{fields}
    end
    """
  end

  def generate_update_input_object(input_object_name, attributes) do
    primary_key = Enum.find(attributes, fn attr -> !is_not_primary_key(attr) end)

    patch_fields =
      attributes
      |> Enum.map(fn field -> generate_field(field, true) end)
      |> Enum.join("\n")

    """
    input_object :#{input_object_name}_patch do
      #{patch_fields}
    end
    input_object :#{input_object_name}_input do
      field :#{primary_key.name}, non_null(#{process_type(primary_key.type)})
      field :patch, non_null(:#{input_object_name}_patch)
    end
    """
  end

  def generate_field(
        %{name: name, has_default: has_default, is_not_null: is_not_null, type: type},
        ignore_null_constraints \\ false
      ) do
    type =
      if ignore_null_constraints do
        process_type(type)
      else
        process_type(type, has_default, is_not_null)
      end

    "field :#{name}, #{type}"
  end

  def process_type(%{name: _name} = type) do
    case Builder.build_type(%{type: type}) do
      {:array, type} ->
        "list_of(:#{FieldGenerator.type_map()[type] || type})"

      "enum" ->
        ":#{type.name}"

      type ->
        ":#{FieldGenerator.type_map()[type] || type}"
    end
  end

  def process_type(type, false = _has_default, true = _is_not_null),
    do: "non_null(#{process_type(type)})"

  def process_type(type, _, _), do: process_type(type)

  @doc """
  Checks if the current attribute is the primary key for this table.

  Don't want to include primary key in "create" input.
  """
  def is_not_primary_key(%{constraints: constraints}) do
    !(constraints |> Enum.member?(%{type: :primary_key}))
  end

  def is_foreign_key(%{constraints: constraints}) do
    !(Enum.find(constraints, fn %{type: type} -> type == :foreign_key end)
      |> is_nil)
  end

  def generate_resolver(name, table) do
    {name, Utils.format_code!(resolver_template(PgGen.LocalConfig.get_app_name(), name, table))}
  end

  def resolver_template(app_name, name, table) do
    %{
      selectable: selectable,
      insertable: insertable,
      updatable: updatable,
      deletable: deletable
    } = table

    %{
      singular_camelized_table_name: singular_camelized_table_name,
      singular_underscore_table_name: singular_underscore_table_name
    } = Utils.get_table_names(name)

    module_name =
      "#{app_name}Web.Resolvers.#{singular_camelized_table_name}"
      |> Macro.camelize()

    extensions_module = Module.concat(Elixir, "#{module_name}.Extends")

    """
    defmodule #{module_name} do
      alias #{Macro.camelize(app_name)}.Contexts.#{singular_camelized_table_name}
      #{if insertable || updatable || deletable do
      "alias #{app_name}Web.Schema.ChangesetErrors"
    end}

      #{if selectable do
      """
      def #{singular_underscore_table_name}(_, %{id: id}, _) do
        {:ok, #{singular_camelized_table_name}.get_#{singular_underscore_table_name}!(id)}
      end
    
      def #{name}(_, args, _) do
        {:ok, %{ nodes: #{singular_camelized_table_name}.list_#{name}(args), args: args }}
      end
      """
    else
      ""
    end}

      #{if insertable do
      """
      def create_#{singular_underscore_table_name}(_, %{input: input}, _) do
        case #{app_name}.Contexts.#{singular_camelized_table_name}.create_#{singular_underscore_table_name}(input) do
          {:ok, #{singular_underscore_table_name}} -> {:ok, #{singular_underscore_table_name}}
          {:error, changeset} ->
            {:error,
              message: "Could not create #{singular_camelized_table_name}",
              details: ChangesetErrors.error_details(changeset)
            }
        end
      end
      """
    else
      ""
    end}

      #{if updatable do
      """
      def update_#{singular_underscore_table_name}(_, %{input: input}, _) do
        #{singular_underscore_table_name} = #{app_name}.Contexts.#{singular_camelized_table_name}.get_#{singular_underscore_table_name}!(input.id)
        case #{app_name}.Contexts.#{singular_camelized_table_name}.update_#{singular_underscore_table_name}(#{singular_underscore_table_name}, input.patch) do
          {:ok, #{singular_underscore_table_name}} -> {:ok, #{singular_underscore_table_name}}
          {:error, changeset} ->
            {:error,
              message: "Could not update #{singular_camelized_table_name}",
              details: ChangesetErrors.error_details(changeset)
            }
        end
      end
      """
    else
      ""
    end}
      #{if deletable do
      """
      def delete_#{singular_underscore_table_name}(_, %{id: id}, _) do
        #{singular_underscore_table_name} = #{app_name}.Contexts.#{singular_camelized_table_name}.get_#{singular_underscore_table_name}!(id)
        case #{app_name}.Contexts.#{singular_camelized_table_name}.delete_#{singular_underscore_table_name}(#{singular_underscore_table_name}) do
          {:ok, #{singular_underscore_table_name}} -> {:ok, #{singular_underscore_table_name}}
          {:error, changeset} ->
            {:error,
              message: "Could not update #{singular_camelized_table_name}",
              details: ChangesetErrors.error_details(changeset)
            }
        end
      end
      """
    else
      ""
    end}

      #{if does_module_exist(extensions_module) do
      """
        #{extensions_module.extensions() |> Enum.join("\n\n")}
      """
    else
      ""
    end}
    end
    """
  end

  def generate_dataloader(tables) do
    sources =
      Enum.map(tables, fn %{name: name} ->
        singular_camelized_table = name |> Inflex.singularize() |> Macro.camelize()

        "|> Dataloader.add_source(Example.Repo.#{singular_camelized_table}, Contexts.#{singular_camelized_table}.data())"
      end)
      |> Enum.join("\n")

    """
    def context(ctx) do
      loader =
        Dataloader.new
        #{sources}

      Map.put(ctx, :loader, loader)
    end

    def plugins do
      [Absinthe.Middleware.Dataloader] ++ Absinthe.Plugin.defaults()
    end
    """
  end

  def generate_connection(table) do
    %{singular_underscore_table_name: singular_underscore_table_name} =
      Utils.get_table_names(table.name)

    """
    object :#{singular_underscore_table_name}_connection do
      field :nodes, list_of(non_null(:#{singular_underscore_table_name}))

      field :page_info, non_null(:page_info) do
        resolve Connections.resolve_page_info()
      end

      field :total_count, :integer do
        resolve(fn %{nodes: nodes}, _, _ -> {:ok, length(nodes)} end)
      end
    end
    """
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

  def changeset_errors_template(module_name) do
    """
    defmodule #{module_name}.Schema.ChangesetErrors do
      @doc \"\"\"
      Traverses the changeset errors and returns a map of 
      error messages. For example:

      %{start_date: ["can't be blank"], end_date: ["can't be blank"]}
      \"\"\"
      def error_details(changeset) do
        Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
          Enum.reduce(opts, msg, fn {key, value}, acc ->
            String.replace(acc, "%{\#{key}}", to_string(value))
          end)
        end)
      end
    end
    """
    |> Utils.format_code!()
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

  def custom_subscriptions(module_prefix) do
    module = Module.concat(Elixir, "#{module_prefix}.Schema.Extends")

    if does_module_exist(module) do
      module.subscriptions() |> Enum.join("\n\n")
    else
      ""
    end
  end

  def inject_custom_queries(query_defs, module_prefix) do
    module = Module.concat(Elixir, "#{module_prefix}.Schema.Extends")

    if does_module_exist(module) do
      query_defs ++ module.query_extensions()
    else
      query_defs
    end
  end

  def does_module_exist(mod_str) when is_binary(mod_str) do
    module = Module.concat(Elixir, mod_str)
    does_module_exist(module)
  end

  def does_module_exist(module) when is_atom(module) do
    IO.puts("Does module #{module} exist?")

    case Code.ensure_compiled(module) do
      {:module, ^module} -> true
      _ -> false
    end
    |> IO.inspect()
  end
end
