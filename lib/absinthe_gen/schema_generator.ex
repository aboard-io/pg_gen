defmodule AbsintheGen.SchemaGenerator do
  alias PgGen.{Utils, Builder}
  alias AbsintheGen.FieldGenerator

  def generate(%{name: name, attributes: attributes} = table, _schema) do
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
      |> Enum.map(&FieldGenerator.to_string/1)
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
          |> Enum.map(&FieldGenerator.to_string/1)
          |> Enum.join("\n")

          # |> Enum.map(&FieldGenerator.to_string/1)
      end

    fields = attributes <> "\n\n" <> references

    {name,
     Code.format_string!(simple_types_template(name, fields),
       locals_without_parens: [
         field: :*,
         belongs_to: :*,
         has_many: :*,
         has_one: :*,
         many_to_many: :*,
         object: :*,
         value: :*,
         enum: :*
       ]
     )}
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

  def simple_types_template(name, fields) do
    """
      object :#{name |> Inflex.singularize() |> Macro.underscore()} do
        #{fields}
      end

    """
  end

  def types_template(types, enum_types, query_defs, dataloader, mutations, inputs) do
    module_name = "#{PgGen.LocalConfig.get_app_name() |> Macro.camelize()}"
    module_name_web = "#{module_name}Web"

    """
    defmodule #{module_name_web}.Schema.Types do
      use Absinthe.Schema
      import Absinthe.Resolution.Helpers, only: [dataloader: 1]

      import_types Absinthe.Type.Custom
      import_types(#{module_name_web}.Schema.Types.Custom.JSON)
      import_types(#{module_name_web}.Schema.Types.Custom.UUID4)

      alias #{module_name_web}.Resolvers
      alias #{module_name}.Contexts

      #{types}

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

  def generate_mutations(table) do
    generate_insertable(table)
  end

  def generate_selectable(%{selectable: true, name: name}) do
    %{
      singular_camelized_table_name: singular_camelized_table_name,
      plural_underscore_table_name: plural_underscore_table_name,
      singular_underscore_table_name: singular_underscore_table_name
    } = get_table_names(name)

    """
    field :#{singular_underscore_table_name}, :#{singular_underscore_table_name} do
      arg :id, non_null(:id)
      resolve &Resolvers.#{singular_camelized_table_name}.#{singular_underscore_table_name}/3
    end
    field :#{plural_underscore_table_name}, list_of(non_null(:#{singular_underscore_table_name})) do
      resolve &Resolvers.#{singular_camelized_table_name}.#{plural_underscore_table_name}/3
    end
    """
  end

  def generate_selectable(_), do: ""

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

  def generate_create_mutation(
        %{
          singular_camelized_table_name: singular_camelized_table_name,
          singular_underscore_table_name: singular_underscore_table_name
        },
        input_name
      ) do
    app_name = PgGen.LocalConfig.get_app_name() |> Macro.camelize()

    """
    field :create_#{singular_underscore_table_name}, :#{singular_underscore_table_name} do
      arg :input, non_null(:#{input_name})
      # TODO move this callback to the resolver
      resolve fn _, %{input: input}, _ -> #{app_name}.Contexts.#{singular_camelized_table_name}.create_#{singular_underscore_table_name}(input) end
    end
    """
  end

  def get_fields(attributes) do
    attributes
    |> Enum.filter(&is_not_primary_key/1)
  end

  def generate_input_object(input_object_name, attributes) do
    fields =
      attributes
      |> get_fields
      |> Enum.map(&generate_field/1)
      |> Enum.join("\n")

    """
    input_object :#{input_object_name} do
      #{fields}
    end
    """
  end

  def generate_field(%{name: name, has_default: has_default, is_not_null: is_not_null, type: type}) do
    "field :#{name}, #{process_type(type, has_default, is_not_null)}"
  end

  def process_type(%{name: _name} = type) do
    case Builder.build_type(%{type: type}) do
      {:array, type} ->
        IO.puts("it's an array type")
        IO.inspect(type)
        IO.inspect(FieldGenerator.type_map()[type] || type)
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
  def is_not_primary_key(%{constraints: constraints} = attr) do
    if is_foreign_key(attr) do
      true
    else
      !(constraints |> Enum.member?(%{type: :primary_key}))
    end
  end

  def is_foreign_key(%{constraints: constraints}) do
    !(Enum.find(constraints, fn %{type: type} -> type == :foreign_key end)
      |> is_nil)
  end

  def generate_resolver(name) do
    {name, Code.format_string!(resolver_template(PgGen.LocalConfig.get_app_name(), name))}
  end

  def resolver_template(app_name, name) do
    module_name =
      "#{app_name}Web.Resolvers.#{Macro.camelize(name) |> Inflex.singularize()}"
      |> Macro.camelize()

    singular_camelized_table = Macro.camelize(name) |> Inflex.singularize()
    singular_table = Inflex.singularize(name)

    """
    defmodule #{module_name} do
      alias #{Macro.camelize(app_name)}.Contexts.#{singular_camelized_table}

      def #{singular_table}(_, %{id: id}, _) do
        {:ok, #{singular_camelized_table}.get_#{singular_table}!(id)}
      end

      def #{name}(_, _, _) do
        {:ok, #{singular_camelized_table}.list_#{name}()}
      end
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

  def get_table_names(name) do
    singular = Inflex.singularize(name)
    plural = Inflex.pluralize(name)

    %{
      singular_camelized_table_name: Macro.camelize(singular),
      plural_camelized_table_name: Macro.underscore(plural),
      singular_underscore_table_name: Macro.underscore(singular),
      plural_underscore_table_name: Macro.underscore(plural)
    }
  end
end
