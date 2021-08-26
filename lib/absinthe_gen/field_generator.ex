defmodule AbsintheGen.FieldGenerator do
  import PgGen.Utils, only: [get_table_names: 1]

  @type_map %{
    "text" => "string",
    "citext" => "string",
    "tsvector" => "string",
    "timestamptz" => "datetime",
    "uuid" => "uuid4",
    "jsonb" => "json",
    "bool" => "boolean",
    "int4" => "integer"
  }

  def to_string(attr, table \\ %{})

  def to_string({:field, name, type, options}, _table) do
    # don't need a resolve method on scalar fields
    options = Keyword.delete(options, :resolve_method)

    type_str =
      process_type(@type_map[type] || type, options)
      |> wrap_non_null_type(options)

    field = "field :#{name}, #{type_str}"

    {description, options} = Keyword.pop(options, :description)

    field =
      case description do
        nil -> field
        description -> field <> ", description: \"#{description}\""
      end

    field
    |> process_options(options, type)
  end

  def to_string({:belongs_to, name, type, options}, _table) do
    type_str =
      process_type(type, options)
      |> wrap_non_null_type(options)

    "field :#{Inflex.singularize(name)}, #{type_str} do"
    |> process_options(options, type)
    |> with_end
  end

  def to_string({:has_many, name, type, options}, table) do
    type_str = "list_of(non_null(#{process_type(type, options)}))"
    args_str = generate_args_for_object(table)

    "field :#{Inflex.pluralize(name)}, #{type_str} do"
    |> process_options(options, type)
    |> append_line(args_str)
    |> with_end
  end

  def to_string({:many_to_many, name, type, options}, table) do
    type_str = "list_of(non_null(#{process_type(type, options)}))"
    args_str = generate_args_for_object(table)

    "field :#{name}, #{type_str} do"
    |> process_options(options, type)
    |> append_line(args_str)
    |> with_end
  end

  def process_type("enum", options) do
    ":" <> Keyword.get(options, :enum_name)
  end

  # type should not have preceding :
  def process_type(":" <> type, options), do: process_type(type, options)

  def process_type({:array, type}, options) do
    "list_of(#{process_type(@type_map[type] || type, options)})"
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

  def process_options(base, options, original_type \\ "") do
    Enum.reduce(options, base, fn {k, v}, acc ->
      case k do
        :description ->
          """
          #{acc}
            description \"#{v}\"
          """

        :resolve_method ->
          case v do
            {:dataloader, opts} ->
              prefix =
                if is_nil(opts[:prefix]) do
                  ""
                else
                  opts[:prefix] <> "."
                end

              """
              #{acc}
                resolve dataloader(#{prefix}Repo.#{original_type})
              """
          end

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
    arg :after, :string # TODO make :cursor
    arg :before, :string # TODO make :cursor
    arg :first, :integer
    arg :last, :integer
    #{if has_indexes do
      """
      arg :condition, :#{singular_underscore_table_name}_condition
      arg :order_by, list_of(:#{plural_underscore_table_name}_order_by), default_value: #{default_order_by(table)}
      """
    else
      ""
    end}
    """
  end

  def default_order_by(%{indexed_attrs: indexed_attrs}) do
    {name, _} = indexed_attrs |> hd
    "{:asc, :#{name}}"
  end

  def default_order_by(_), do: ""

  def type_map, do: @type_map

  defp append_line(str1, str2), do: str1 <> "\n" <> str2
end
