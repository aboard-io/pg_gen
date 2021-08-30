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

  def types_template(types, enum_types, query_defs, dataloader, mutations, inputs, scalar_filters) do
    module_name = "#{PgGen.LocalConfig.get_app_name() |> Macro.camelize()}"
    module_name_web = "#{module_name}Web"

    """
    defmodule #{module_name_web}.Schema.Types do
      use Absinthe.Schema
      import Absinthe.Resolution.Helpers, only: [dataloader: 1]

      import_types Absinthe.Type.Custom
      import_types(#{module_name_web}.Schema.Types.Custom.JSON)
      import_types(#{module_name_web}.Schema.Types.Custom.UUID4)
      import_types(#{module_name_web}.Schema.Types.Custom.Cursor)

      alias #{module_name_web}.Resolvers
      alias #{module_name}.Contexts

      #{types}

      #{scalar_filters}

      #{enum_types}

      query do
        #{query_defs}
      end

      mutation do
        #{mutations}
      end

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
      arg :id, non_null(:id)
      resolve &Resolvers.#{singular_camelized_table_name}.#{singular_underscore_table_name}/3
    end
    field :#{plural_underscore_table_name}, list_of(non_null(:#{singular_underscore_table_name})) do
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
    ["datetime", "uuid4", "boolean", "string", "date", "integer"]
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

    module_name =
      "#{app_name}Web.Resolvers.#{Macro.camelize(name) |> Inflex.singularize()}"
      |> Macro.camelize()

    singular_camelized_table = Macro.camelize(name) |> Inflex.singularize()
    singular_table = Inflex.singularize(name)

    """
    defmodule #{module_name} do
      alias #{Macro.camelize(app_name)}.Contexts.#{singular_camelized_table}

      #{if selectable do
      """
      def #{singular_table}(_, %{id: id}, _) do
        {:ok, #{singular_camelized_table}.get_#{singular_table}!(id)}
      end
    
      def #{name}(_, args, _) do
        {:ok, #{singular_camelized_table}.list_#{name}(args)}
      end
      """
    else
      ""
    end}

      #{if insertable do
      """
      def create_#{singular_table}(_, %{input: input}, _) do
        #{app_name}.Contexts.#{singular_camelized_table}.create_#{singular_table}(input)
      end
      """
    else
      ""
    end}

      #{if updatable do
      """
      def update_#{singular_table}(_, %{input: input}, _) do
        #{singular_table} = #{app_name}.Contexts.#{singular_camelized_table}.get_#{singular_table}!(input.id)
        #{app_name}.Contexts.#{singular_camelized_table}.update_#{singular_table}(#{singular_table}, input.patch)
      end
      """
    else
      ""
    end}
      #{if deletable do
      """
      def delete_#{singular_table}(_, %{id: id}, _) do
        #{singular_table} = #{app_name}.Contexts.#{singular_camelized_table}.get_#{singular_table}!(id)
        #{app_name}.Contexts.#{singular_camelized_table}.delete_#{singular_table}(#{singular_table})
      end
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
end
