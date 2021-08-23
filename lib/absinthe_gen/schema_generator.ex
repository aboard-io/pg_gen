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

  def types_template(types, enum_types, query_defs, dataloader) do
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

      #{dataloader}

    end
    """
  end

  def generate_queries(
        %{
          name: name,
          selectable: selectable,
          updatable: updatable,
          insertable: insertable,
          deletable: deletable
        } = table
      ) do
    generate_selectable(table)
  end

  def generate_selectable(%{selectable: true, name: name} = table) do
    %{table_name: table_name, lower_case_table_name: lower_case_table_name} =
      get_table_names(name)

    singular_lowercase = Inflex.singularize(lower_case_table_name)

    """
    field :#{singular_lowercase}, :#{singular_lowercase} do
      arg :id, non_null(:id)
      resolve &Resolvers.#{table_name}.#{singular_lowercase}/3
      # resolve &Resolvers.Vacation.place/3
    end
    field :#{lower_case_table_name}, list_of(non_null(:#{singular_lowercase})) do
      resolve &Resolvers.#{table_name}.#{lower_case_table_name}/3
    end
    """
  end

  def generate_selectable(_), do: ""

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
    %{
      table_name: name |> Inflex.singularize() |> Macro.camelize(),
      lower_case_table_name: String.downcase(name)
    }
  end
end
