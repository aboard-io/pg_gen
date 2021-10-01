defmodule AbsintheGen.SchemaGenerator do
  alias PgGen.{Utils, Builder}
  alias AbsintheGen.FieldGenerator
  import Utils, only: [get_table_names: 1]

  @scalar_types [
    "text",
    "citext",
    "timestamptz",
    "uuid",
    "jsonb",
    "bool",
    "int4",
    "enum",
    "void"
  ]

  def generate_types(
        %{name: name, attributes: attributes} = table,
        computed_fields,
        tables,
        _schema
      ) do
    app_name = PgGen.LocalConfig.get_app_name()

    built_attributes =
      attributes
      |> Enum.map(&Builder.build/1)

    %{
      singular_camelized_table_name: singular_camelized_table_name,
      singular_underscore_table_name: singular_underscore_table_name
    } = Utils.get_table_names(name)

    module_name =
      "#{app_name}Web.Schema.#{singular_camelized_table_name}Types"
      |> Macro.camelize()

    extensions_module = Module.concat(Elixir, "#{module_name}.Extend")
    extensions_module_exists = Utils.does_module_exist(extensions_module)

    attributes =
      built_attributes
      |> Utils.deduplicate_associations()
      |> Enum.map(fn {a, b, c, opts} ->
        {a, b, c, Keyword.put_new(opts, :resolve_method, {:dataloader, prefix: app_name})}
      end)
      |> Enum.map(fn {_, name, _, _} = attr ->
        unless extensions_module_exists &&
                 name in Utils.maybe_apply(
                   extensions_module,
                   "#{singular_underscore_table_name}_overrides",
                   [],
                   []
                 ) do
          FieldGenerator.to_string(attr)
        end
      end)

    attributes =
      (attributes ++
         if(extensions_module_exists,
           do:
             Utils.maybe_apply(
               extensions_module,
               "#{singular_underscore_table_name}_extensions",
               [],
               []
             ),
           else: []
         ))
      |> Enum.join("\n")

    computed_fields =
      computed_fields
      |> Enum.map(&Builder.build/1)
      |> Enum.filter(&(!is_nil(&1)))
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
          |> Utils.deduplicate_references()
          |> Enum.map(fn {a, b, c, opts} ->
            {a, b, c, Keyword.put_new(opts, :resolve_method, {:dataloader, prefix: app_name})}
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

    fields = attributes <> "\n\n" <> computed_fields <> "\n\n" <> references

    conditions_and_input_objects = conditions_and_filters <> "\n\n" <> order_by_enums

    mutation_input_objects_and_payloads =
      generate_mutation_inputs_and_payloads(table, extensions_module, extensions_module_exists)

    {name,
     simple_types_template(
       name,
       fields,
       conditions_and_input_objects,
       mutation_input_objects_and_payloads,
       app_name
     )}
  end

  def filter_accessible(tables, _functions) do
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

  def simple_types_template(
        name,
        fields,
        conditions_and_input_objects,
        mutation_input_objects_and_payloads,
        app_name
      ) do
    %{
      singular_camelized_table_name: singular_camelized_table_name,
      singular_underscore_table_name: singular_underscore_table_name
    } = PgGen.Utils.get_table_names(name)

    module_name_web = "#{app_name}Web"

    body = """
      object :#{singular_underscore_table_name} do
        #{fields}
      end

      #{conditions_and_input_objects}
    """

    uses_connections = String.match?(body, ~r/Connections\./)
    uses_dataloader = String.match?(body, ~r/dataloader\(/)

    """
    defmodule #{module_name_web}.Schema.#{singular_camelized_table_name}Types do
      use Absinthe.Schema.Notation
      #{if uses_dataloader, do: "import Absinthe.Resolution.Helpers, only: [dataloader: 1]", else: ""}
      #{if uses_connections, do: "alias #{module_name_web}.Resolvers.Connections", else: ""}
      #{if String.contains?(body, "Repo"), do: "alias #{app_name}.Repo", else: ""}

      #{body}
      #{mutation_input_objects_and_payloads}
    end
    """
  end

  def schema_template(
        enum_types,
        query_defs,
        custom_record_defs,
        dataloader,
        mutations,
        mutation_payloads,
        scalar_filters,
        connections,
        subscriptions,
        table_names
      ) do
    module_name = "#{PgGen.LocalConfig.get_app_name() |> Macro.camelize()}"
    module_name_web = "#{module_name}Web"

    extensions_module = Module.concat(Elixir, "#{module_name_web}.Schema.Extends")
    extensions_module_exists = Utils.does_module_exist(extensions_module)

    if !extensions_module_exists do
      require IEx
      IEx.pry()
    else
      IO.inspect(extensions_module.imports)
    end

    """
    defmodule #{module_name_web}.Schema do
      use Absinthe.Schema

      import_types Absinthe.Type.Custom
      import_types #{module_name_web}.Schema.Types.Custom.JSON
      import_types #{module_name_web}.Schema.Types.Custom.UUID4
      import_types #{module_name_web}.Schema.Types.Custom.UUID62
      import_types #{module_name_web}.Schema.Types.Custom.Cursor
      #{Enum.map(table_names, fn name -> "import_types #{module_name_web}.Schema.#{get_table_names(name).singular_camelized_table_name}Types" end) |> Enum.join("\n")}
        #{if extensions_module_exists && Kernel.function_exported?(extensions_module, :imports, 0) do
      [imports] = extensions_module.imports()
      Enum.map(imports, fn name -> "import_types #{name}" end) |> Enum.join("\n")
    end}

      alias #{module_name_web}.Resolvers
      alias #{module_name_web}.Resolvers.Connections
      alias #{module_name}.Contexts

      #{connections}

      #{scalar_filters}

      #{enum_types}

      object :page_info do
        field :start_cursor, :cursor
        field :end_cursor, :cursor
        field :has_next_page, non_null(:boolean)
        field :has_previous_page, non_null(:boolean)
      end

      #{custom_record_defs}

      query do
        #{query_defs}
      end

      mutation do
        #{mutations}
      end

      # Payloads for custom Postgres mutation functions
      #{mutation_payloads}

      #{if subscriptions != "" do
      """
      subscription do
        #{subscriptions}
      end
      """
    end}

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
    generate_create_mutation(table_names, input_name)
  end

  def generate_insertable(_), do: ""

  def generate_updatable(%{updatable: true, name: name} = table) do
    primary_key = Enum.find(table.attributes, fn attr -> !is_not_primary_key(attr) end)

    if is_nil(primary_key) do
      ["", ""]
    else
      %{
        singular_underscore_table_name: singular_underscore_table_name
      } = table_names = get_table_names(name)

      input_name = "update_#{singular_underscore_table_name}"
      generate_update_mutation(table_names, input_name)
    end
  end

  def generate_updatable(_), do: ""

  def generate_deletable(%{deletable: true, name: name} = table) do
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
      field :delete_#{singular_underscore_table_name}, :delete_#{singular_underscore_table_name}_payload do
        arg :id, non_null(#{type})
        resolve &Resolvers.#{singular_camelized_table_name}.delete_#{singular_underscore_table_name}/3
      end
      """
    end
  end

  def generate_deletable(_), do: ""

  def generate_create_mutation(
        %{
          singular_camelized_table_name: singular_camelized_table_name,
          singular_underscore_table_name: singular_underscore_table_name
        },
        input_name
      ) do
    """
    field :create_#{singular_underscore_table_name}, :create_#{singular_underscore_table_name}_payload do
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
    field :update_#{singular_underscore_table_name}, :update_#{singular_underscore_table_name}_payload do
      arg :input, non_null(:#{input_name}_input)
      resolve &Resolvers.#{singular_camelized_table_name}.update_#{singular_underscore_table_name}/3
    end
    """
  end

  def generate_mutation_inputs_and_payloads(table, extensions_module, extensions_module_exists) do
    {create_input_object, create_payload} =
      generate_insertable_input_and_payload(table, extensions_module, extensions_module_exists)

    {update_input_object, update_payload} =
      generate_updatable_input_and_payload(table, extensions_module, extensions_module_exists)

    delete_payload = generate_deletable_payload(table)

    [create_input_object, create_payload, update_input_object, update_payload, delete_payload]
    |> Enum.join("\n\n")
  end

  def generate_insertable_input_and_payload(
        %{insertable: true, name: name} = table,
        extensions_module,
        extensions_module_exists
      ) do
    %{
      singular_underscore_table_name: singular_underscore_table_name
    } = get_table_names(name)

    input_name = "create_#{singular_underscore_table_name}_input"

    input_object =
      generate_create_input_object(
        input_name,
        table.attributes,
        extensions_module,
        extensions_module_exists
      )

    payload = generate_mutation_payload(singular_underscore_table_name, "create")

    {input_object, payload}
  end

  def generate_insertable_input_and_payload(_, _, _), do: {"", ""}

  def generate_updatable_input_and_payload(
        %{updatable: true, name: name} = table,
        extensions_module,
        extensions_module_exists
      ) do
    %{
      singular_underscore_table_name: singular_underscore_table_name
    } = get_table_names(name)

    input_name = "update_#{singular_underscore_table_name}"

    input_object =
      generate_update_input_object(
        input_name,
        table.attributes,
        extensions_module,
        extensions_module_exists
      )

    payload = generate_mutation_payload(singular_underscore_table_name, "update")

    {input_object, payload}
  end

  def generate_updatable_input_and_payload(_, _, _), do: {"", ""}

  def generate_deletable_payload(%{deletable: true, name: name}) do
    %{
      singular_underscore_table_name: singular_underscore_table_name
    } = get_table_names(name)

    generate_mutation_payload(singular_underscore_table_name, "delete")
  end

  def generate_deletable_payload(_), do: ""

  def generate_create_input_object(
        input_object_name,
        attributes,
        extensions_module,
        extensions_module_exists
      ) do
    fields =
      attributes
      |> Enum.filter(fn %{name: name} ->
        if extensions_module_exists &&
             name in Utils.maybe_apply(
               extensions_module,
               "#{input_object_name}_overrides",
               [],
               []
             ) do
          false
        else
          true
        end
      end)
      |> Enum.map(&generate_field/1)

    field_strs =
      if extensions_module_exists do
        fields ++ Utils.maybe_apply(extensions_module, "#{input_object_name}_extensions", [], [])
      else
        fields
      end
      |> Enum.join("\n")

    """
    input_object :#{input_object_name} do
      #{field_strs}
    end
    """
  end

  def generate_update_input_object(
        input_object_name,
        attributes,
        extensions_module,
        extensions_module_exists
      ) do
    primary_key = Enum.find(attributes, fn attr -> !is_not_primary_key(attr) end)

    patch_fields =
      attributes
      |> Enum.filter(fn %{name: name} ->
        if extensions_module_exists &&
             name in Utils.maybe_apply(
               extensions_module,
               "#{input_object_name}_patch_overrides",
               [],
               []
             ) do
          false
        else
          true
        end
      end)
      |> Enum.map(fn field -> generate_field(field, true) end)

    patch_field_strs =
      if extensions_module_exists do
        patch_fields ++
          Utils.maybe_apply(extensions_module, "#{input_object_name}_patch_extensions", [], [])
      else
        patch_fields
      end
      |> Enum.join("\n")

    """
    input_object :#{input_object_name}_patch do
      #{patch_field_strs}
    end
    input_object :#{input_object_name}_input do
      field :#{primary_key.name}, non_null(#{process_type(primary_key.type)})
      field :patch, non_null(:#{input_object_name}_patch)
    end
    """
  end

  def generate_custom_function_mutations(mutation_functions, tables) do
    functions =
      mutation_functions
      |> Enum.map(&generate_custom_function_query(&1, tables))

    payloads =
      mutation_functions
      |> Enum.filter(fn
        %{return_type: %{type: %{name: name}}} when name in @scalar_types -> false
        _ -> true
      end)
      |> Enum.map(fn %{return_type: %{type: %{name: name}}} -> Inflex.singularize(name) end)
      |> Enum.uniq()
      |> Enum.map(fn return_type_name -> generate_mutation_payload(return_type_name, "mutate") end)

    {functions, payloads}
  end

  # def generate_custom_function_mutation(function, tables) do
  # end

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
        "list_of(:#{FieldGenerator.type_map()[type] || Inflex.singularize(type)})"

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

  def generate_dataloader(tables, functions) do
    app_name = PgGen.LocalConfig.get_app_name()

    sources =
      tables
      |> filter_accessible(functions)
      |> Enum.map(fn %{name: name} ->
        singular_camelized_table = name |> Inflex.singularize() |> Macro.camelize()

        "|> Dataloader.add_source(#{app_name}.Repo.#{singular_camelized_table}, Contexts.#{singular_camelized_table}.data())"
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
        fn parent, args, %{context: %{loader: loader}} = info ->
          {table_selections, computed_selections} =
            #{module_name}.Resolvers.Utils.get_selections(info, repo)

          args =
            Map.put(args, :__selections, %{
              table_selections: table_selections,
              computed_selections: computed_selections
            })

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
        IO.inspect(changeset, label: "changeset")
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
      The JSON scalar type allows arbitrary JSON values to be passed in and out.
      Requires `{ :jason, "~> 1.1" }` package: https://github.com/michalmuskala/jason
      \"\"\"
      use Absinthe.Schema.Notation

      scalar :json, name: "JSON" do
        description(\"\"\"
        The `JSON` scalar type represents arbitrary json string data, represented as UTF-8
        character sequences. The JSON type is most often used to represent a free-form
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

      defp decode(%{value: ""}) do
        :error
      end

      defp decode(%{value: value}) do
        case String.length(value) do
          22 -> {:ok, Base62UUID.decode!(value)}
          _ -> :error
        end
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

    if Utils.does_module_exist(module) do
      module.subscriptions() |> Enum.join("\n\n")
    else
      ""
    end
  end

  def inject_custom_queries(query_defs, functions, tables, module_prefix) do
    module = Module.concat(Elixir, "#{module_prefix}.Schema.Extends")

    query_defs = query_defs ++ db_function_queries(functions, tables)

    if Utils.does_module_exist(module) do
      query_defs ++ module.query_extensions()
    else
      query_defs
    end
  end

  def db_function_queries(functions, tables) do
    functions
    |> Enum.map(&generate_custom_function_query(&1, tables))
  end

  def generate_custom_function_query(
        %{return_type: %{type: %{name: type_name}}} = function,
        tables
      )
      when type_name in @scalar_types,
      do: generate_custom_function_returning_scalar_to_string(function, tables)

  def generate_custom_function_query(%{returns_set: true} = function, tables),
    do: generate_custom_function_returning_set_to_string(function, tables)

  def generate_custom_function_query(%{returns_set: false} = function, tables),
    do: generate_custom_function_returning_record_to_string(function, tables)

  def generate_custom_function_returning_set_to_string(
        %{name: name, return_type: %{type: %{name: type_name}} = return_type, args: args},
        tables
      ) do
    arg_strs = generate_custom_function_args_str(args, tables)

    table = Enum.find(tables, fn %{name: name} -> name == type_name end)

    connection_arg_str =
      if is_nil(table) do
        ""
      else
        FieldGenerator.generate_args_for_object(table)
      end

    resolver_module_str =
      if Map.get(return_type, :composite_type, false) do
        "PgFunctions"
      else
        Macro.camelize(type_name) |> Inflex.singularize()
      end

    """
    field :#{name}, #{FieldGenerator.process_type(type_name, [])}_connection do
      #{arg_strs}
      #{connection_arg_str}
      resolve &Resolvers.#{resolver_module_str}.#{name}/3
    end
    """
  end

  def generate_custom_function_returning_record_to_string(
        %{
          name: name,
          return_type: %{type: %{name: type_name, category: category}},
          is_stable: is_stable,
          args: args
        } = function,
        tables
      ) do
    arg_strs = generate_custom_function_args_str(args, tables)

    if category == "E" do
      generate_custom_function_returning_scalar_to_string(function, tables)
    else
      resolver_module_str = Macro.camelize(type_name) |> Inflex.singularize()

      return_type_str =
        if is_stable,
          do: FieldGenerator.process_type(type_name, []),
          else: ":mutate_#{Inflex.singularize(type_name)}_payload"

      """
      field :#{name}, #{return_type_str} do
        #{arg_strs}
        resolve &Resolvers.#{resolver_module_str}.#{name}/3
      end
      """
    end
  end

  def generate_custom_function_returning_scalar_to_string(
        %{
          name: name,
          return_type: %{type: %{name: type_name}},
          args: args,
          returns_set: returns_set
        },
        tables
      ) do
    arg_strs = generate_custom_function_args_str(args, tables)

    return_type =
      if returns_set do
        "list_of(#{FieldGenerator.process_type(type_name, [])})"
      else
        "#{FieldGenerator.process_type(type_name, [])}"
      end

    """
    field :#{name}, #{return_type} do
      #{arg_strs}
      resolve &Resolvers.PgFunctions.#{name}/3
    end
    """
  end

  def generate_custom_function_args_str(args, tables) do
    table_names = Enum.map(tables, fn %{name: name} -> name end)

    Enum.map(args, fn
      %{name: name, type: type} ->
        normalized_name = String.replace(type.name, ~r/^[_]/, "")

        if normalized_name in table_names do
          """
          arg :#{name}, #{process_type(Map.put(type, :name, "create_#{Inflex.singularize(normalized_name)}_input"))}
          """
        else
          """
          arg :#{name}, #{process_type(type)}
          """
        end
    end)
    |> Enum.join("")
  end

  def generate_custom_records(functions) do
    functions
    |> Enum.filter(fn %{return_type: return_type} ->
      Map.get(return_type, :composite_type, false)
    end)
    |> Enum.map(fn %{return_type: %{name: name, attrs: attrs}} ->
      fields =
        attrs
        |> Enum.map(fn attr ->
          Map.merge(
            attr,
            %{
              is_not_null: false,
              has_default: false,
              description: nil,
              constraints: []
            }
          )
        end)
        |> Enum.map(&Builder.build/1)
        |> Enum.map(fn attr ->
          FieldGenerator.to_string(attr)
        end)
        |> Enum.join("\n")

      """
      object :#{name}_connection do
        field :nodes, list_of(non_null(:#{name}))
        field :page_info, non_null(:page_info) do
          resolve Connections.resolve_page_info()
        end
        field :total_count, :integer do
          resolve(fn %{nodes: nodes}, _, _ -> {:ok, length(nodes)} end)
        end
      end

      object :#{name} do
        #{fields}
      end
      """
    end)
    |> Enum.join("\n\n")

    #   %{
    #   attrs: [
    #     %{
    #       name: "workflow_id",
    #       type: %{
    #         category: "U",
    #         description: "UUID datatype",
    #         enum_variants: nil,
    #         name: "uuid",
    #         tags: %{}
    #       },
    #       type_id: "2950"
    #     },
    #     %{
    #       name: "email",
    #       type: %{
    #         category: "S",
    #         description: nil,
    #         enum_variants: nil,
    #         name: "citext",
    #         tags: nil
    #       },
    #       type_id: "230816"
    #     },
    #     %{
    #       name: "workflow_name",
    #       type: %{
    #         category: "S",
    #         description: "variable-length string, no limit specified",
    #         enum_variants: nil,
    #         name: "text",
    #         tags: %{}
    #       },
    #       type_id: "25"
    #     }
    #   ],
    #   composit_type: true,
    #   name: "get_workflow_invitation_record",
    #   type: %{
    #     category: "P",
    #     description: "pseudo-type representing any composite type",
    #     enum_variants: nil,
    #     name: "record",
    #     tags: %{}
    #   },
    #   type_id: "2249"
    # }
  end

  def generate_mutation_payload(singular_table_name, type) do
    """
    object :#{type}_#{singular_table_name}_payload do
      field :#{singular_table_name}, :#{singular_table_name}
      field :query, :query
    end
    """
  end
end
