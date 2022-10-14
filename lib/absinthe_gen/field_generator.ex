defmodule AbsintheGen.FieldGenerator do
  import PgGen.Utils, only: [get_table_names: 1]

  @type_map %{
    "text" => "string",
    "citext" => "string",
    "tsvector" => "string",
    "timestamptz" => "datetime",
    "timestamp" => "datetime",
    "uuid" => "uuid62",
    "jsonb" => "json",
    "bool" => "boolean",
    "int4" => "integer",
    "int8" => "integer",
    "bytea" => "string",
    # for postgres functions that return void, we'll return a success object
    "void" => "success_object"
  }

  @type_list Enum.map(@type_map, fn {k, _} -> k end)

  def to_string(attr, table \\ %{})

  def to_string({:field, name, type, options}, _table) do
    # don't need a resolve method on non-virtual scalar fields
    options = Keyword.delete(options, :resolve_method)

    type_str =
      process_type(@type_map[type] || type, options)
      |> wrap_non_null_type(options)

    is_virtual = Keyword.get(options, :virtual, false)
    str = "field :#{name}, #{type_str} #{if is_virtual, do: "do\n"}"

    {description, options} = Keyword.pop(options, :description)

    str =
      case description do
        nil ->
          str

        "" ->
          str

        description ->
          str <>
            "#{if !is_virtual, do: ","} description#{if !is_virtual, do: ":"} \"#{String.trim(description)}\""
      end

    str =
      str
      |> process_options({:field, name, type, options})

    if is_virtual do
      str |> with_end
    else
      str
    end
  end

  def to_string({:belongs_to, name, _type, options} = field, _table) do
    relation = single_relation(field)

    column =
      __MODULE__.to_string(
        {:field, Keyword.get(options, :fk) || "#{name}_id",
         process_type(Keyword.get(options, :fk_type), options), options}
      )

    column <> "\n" <> relation
  end

  def to_string({:has_one, name, type, options}, _table) do
    single_relation({:has_one, Inflex.singularize(name), type, options})
  end

  def to_string({:has_many, name, type, options} = field, table) do
    type_str = "non_null(#{Inflex.pluralize(process_type(type, options))}_connection)"
    args_str = generate_args_for_object(table)

    "field :#{Inflex.pluralize(name)}, #{type_str} do"
    |> process_options(field)
    |> append_line(args_str)
    |> with_end
  end

  def to_string({:many_to_many, name, type, options} = field, table) do
    type_str = "non_null(#{Inflex.pluralize(process_type(type, options))}_connection)"
    args_str = generate_args_for_object(table)

    "field :#{name}, #{type_str} do"
    |> process_options(field)
    |> append_line(args_str)
    |> with_end
  end

  def process_type(type, options) when type in @type_list do
    process_type(@type_map[type], options)
  end

  def process_type("enum", options) do
    ":" <> Keyword.get(options, :enum_name)
  end

  # type should not have preceding :
  def process_type(":" <> type, options), do: process_type(type, options)

  def process_type({:array, type}, options) do
    "list_of(#{process_type(@type_map[type] || type, options)})"
  end

  def process_type({:enum_array, enum_name, _variants}, _options) do
    "list_of(:" <> (enum_name |> Inflex.singularize() |> Macro.underscore()) <> ")"
  end

  def process_type(type, _options) do
    ":" <> (type |> Inflex.singularize() |> Macro.underscore())
  end

  def wrap_non_null_type(type, options) do
    case Keyword.get(options, :is_not_null) do
      true -> "non_null(#{type})"
      false -> type
      nil -> type
    end
  end

  def process_options(base, {field_or_assoc, name, type, options}) do
    Enum.reduce(options, base, fn {k, v}, acc ->
      case k do
        :description ->
          case v do
            nil ->
              acc

            "" ->
              acc

            description ->
              """
              #{acc}
                description \"#{String.trim(description)}\"
              """
          end

        :resolve_method ->
          case v do
            {:dataloader, _opts} ->
              case field_or_assoc do
                :belongs_to ->
                  """
                  #{acc}
                    resolve Connections.resolve_one(Repo.#{type}, :#{name})
                  """

                :has_one ->
                  """
                  #{acc}
                    resolve Connections.resolve_one(Repo.#{type}, :#{name})
                  """

                _ ->
                  """
                  #{acc}
                    resolve Connections.resolve(Repo.#{type}, :#{name})
                  """
              end
          end

        :virtual ->
          """
          #{acc}
          resolve &#{name}/3
          """

        _ ->
          acc
      end
    end)
  end

  def with_end(str), do: append_line(str, "end")

  def generate_args_for_object(map) when map == %{}, do: ""

  def generate_args_for_object(table) do
    %{
      singular_underscore_table_name: singular_underscore_table_name,
      plural_underscore_table_name: plural_underscore_table_name
    } = get_table_names(table.name)

    has_indexes = Map.has_key?(table, :indexed_attrs) && length(table.indexed_attrs) > 0

    """
    arg :after, :cursor
    arg :before, :cursor
    arg :first, :integer
    arg :last, :integer
    #{if has_indexes do
      """
      arg :condition, :#{singular_underscore_table_name}_condition
      arg :filter, :#{singular_underscore_table_name}_filter
      arg :order_by, list_of(:#{plural_underscore_table_name}_order_by), default_value: #{default_order_by(table)}
      """
    else
      ""
    end}
    """
  end

  def default_order_by(%{indexed_attrs: indexed_attrs}) do
    {name, _} = indexed_attrs |> List.first()
    "{:asc, :#{name}}"
  end

  def default_order_by(_), do: ""

  def type_map, do: @type_map

  defp single_relation({_, name, type, options} = field) do
    type_str =
      process_type(type, options)
      |> wrap_non_null_type(options)

    "field :#{Inflex.singularize(name)}, #{type_str} do"
    |> process_options(field)
    |> with_end
  end

  defp append_line(str1, str2), do: str1 <> "\n" <> str2
end
