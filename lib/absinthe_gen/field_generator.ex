defmodule AbsintheGen.FieldGenerator do
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

  def to_string({:field, name, type, options}) do
    # don't need a resolve method on scalar fields
    options = Keyword.delete(options, :resolve_method)

    "field :#{name}, "
    |> process_options(options, process_type(@type_map[type] || type, options))
  end

  def to_string({:belongs_to, name, type, options}) do
    "field :#{Inflex.singularize(name)}, "
    |> process_options(options, process_type(type, options), type)
  end

  def to_string({:has_many, name, type, options}) do
    "field :#{Inflex.pluralize(name)}, "
    |> process_options(options, "list_of(non_null(#{process_type(type, options)}))", type)
  end

  def to_string({:many_to_many, name, type, options}) do
    "field :#{name}, "
    |> process_options(options, "list_of(non_null(#{process_type(type, options)}))", type)
  end

  def process_type("enum", options) do
    ":" <> Keyword.get(options, :enum_name)
  end

  def process_type(":" <> type, options), do: process_type(type, options)

  def process_type({:array, type}, options) do
    "list_of(#{process_type(@type_map[type] || type, options)})"
  end

  def process_type(type, _options) do
    ":" <> (type |> Inflex.singularize() |> Macro.underscore())
  end

  def process_options(base, options, type, original_type \\ "") do
    wrapped_type =
      Enum.reduce(options, type, fn {k, _v}, acc ->
        case k do
          :is_not_null ->
            "non_null(#{acc})"

          _ ->
            acc
        end
      end)

    Enum.reduce(options, base <> wrapped_type, fn {k, v}, acc ->
      case k do
        :description ->
          "#{acc}, description: \"#{v}\""

        :resolve_method ->
          case v do
            {:dataloader, opts} ->
              prefix =
                if is_nil(opts[:prefix]) do
                  ""
                else
                  opts[:prefix] <> "."
                end

              "#{acc}, resolve: dataloader(#{prefix}Repo.#{original_type})"
          end

        # :values ->
        #   "#{acc}, values: [#{Enum.map(v, &":#{&1}") |> Enum.join(", ")}]"
        #
        # :fk ->
        #   "#{acc}, foreign_key: :#{v}"
        #
        # :ref ->
        #   "#{acc}, references: :#{v}"
        #
        # :join_through ->
        #   "#{acc}, join_through: \"#{v}\""
        #
        # :join_keys ->
        #   [{current_id, _}, {associated_id, _}] = v
        #   "#{acc}, join_keys: [#{current_id}: :id, #{associated_id}: :id]"

        _ ->
          acc
      end
    end)
  end

  def type_map, do: @type_map
end
