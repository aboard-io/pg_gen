defmodule EctoGen.FieldGenerator do
  @type_map %{
    "text" => "string",
    "citext" => "string",
    "timestamptz" => "utc_datetime_usec",
    "timestamp" => "utc_datetime",
    "uuid" => "Ecto.UUID",
    "jsonb" => "EctoJSON",
    "bool" => "boolean",
    "int4" => "integer",
    "int8" => "integer",
    "enum" => "Ecto.Enum"
  }

  @type_list Enum.map(@type_map, fn {k, _} -> k end)

  @doc """
  ID fields are inferred; Ecto doesn't want them in the schema
  """
  def to_string({:field, "id", _type, _options}) do
    ""
  end

  def to_string({:field, name, {:array, type}, options}) do
    options = Keyword.put(options, :array_type, true)
    EctoGen.FieldGenerator.to_string({:field, name, type, options})
  end

  def to_string({:field, name, {:enum_array, type, variants}, options}) do
    options =
      options
      |> Keyword.put(:enum_array_type, true)
      |> Keyword.put(:enum_variants, variants)

    EctoGen.FieldGenerator.to_string({:field, name, type, options})
  end

  def to_string({:field, name, type, options}) do
    case String.match?(type, ~r/(vector)$/) do
      true ->
        IO.puts("""
        Fix this to_string for field: #{name}: #{type}
        # See https://www.reddit.com/r/elixir/comments/72z762/how_to_use_postgrex_extension_to_create_an_ecto/
        #     https://hexdocs.pm/ecto/Ecto.Type.html
        """)

        ""

      false ->
        {is_virtual, options} = Keyword.pop(options, :virtual, false)

        type =
          cond do
            type in @type_list -> process_type_str(type)
            is_virtual -> process_type_str("any")
            true -> process_type_str(type)
          end

        {is_array_type, options} = Keyword.pop(options, :array_type, false)
        {is_enum_array_type, options} = Keyword.pop(options, :enum_array_type, false)

        type =
          cond do
            is_array_type ->
              "{:array, #{type}}"

            is_enum_array_type ->
              "{:array, Ecto.Enum}, values: [#{Enum.map(options[:enum_variants], fn v -> ":#{v}" end) |> Enum.join(", ")}]"

            true ->
              type
          end

        "field :#{name}, #{type}"
        |> process_options(options)
    end
  end

  def to_string({:belongs_to, name, queryable, options}) do
    "belongs_to :#{name}, #{queryable}"
    |> process_options(options)
  end

  def to_string({:has_many, name, queryable, options}) do
    {is_virtual, options} = Keyword.pop(options, :virtual, false)
    relationship = if is_virtual, do: "field", else: "has_many"

    "#{relationship} :#{name}, #{if is_virtual, do: ":any", else: queryable}"
    |> process_options(options)
  end

  def to_string({:many_to_many, name, queryable, options}) do
    "many_to_many :#{name}, #{queryable}"
    # we don't need foreign_key on many_to_many
    |> process_options(Keyword.drop(options, [:fk]))
  end

  def to_string({:has_one, name, queryable, options}) do
    {is_virtual, options} = Keyword.pop(options, :virtual, false)
    relationship = if is_virtual, do: "field", else: "has_one"

    "#{relationship} :#{Inflex.singularize(name)}, #{if is_virtual, do: ":any", else: queryable}"
    |> process_options(options)
  end

  defp process_options(base, options) do
    Enum.reduce(options, base, fn {k, v}, acc ->
      case k do
        :values ->
          "#{acc}, values: [#{Enum.map(v, &":#{&1}") |> Enum.join(", ")}]"

        :fk ->
          "#{acc}, foreign_key: :#{v}"

        :pk ->
          "#{acc}, primary_key: true"

        :type ->
          "#{acc}, type: #{process_type_str(v)}"

        :ref ->
          "#{acc}, references: :#{v}"

        :join_through ->
          "#{acc}, join_through: \"#{v}\""

        :join_keys ->
          [{current_id, _}, {associated_id, _}] = v
          "#{acc}, join_keys: [#{current_id}: :id, #{associated_id}: :id]"

        _ ->
          acc
      end
    end)
  end

  def process_type_str(type) do
    type = @type_map[type] || type

    case Regex.match?(~r/^[A-Z\{]/, type) do
      true -> type
      false -> ":#{type}"
    end
  end

  def type_map, do: @type_map
  def type_list, do: @type_list
end
