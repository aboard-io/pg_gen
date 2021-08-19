defmodule EctoGen.FieldGenerator do
  @type_map %{
    "text" => "string",
    "citext" => "string",
    "timestamptz" => "utc_datetime",
    "uuid" => "Ecto.UUID",
    "jsonb" => "map",
    "bool" => "boolean",
    "int4" => "integer"
  }

  def generate(%{constraints: constraints} = attribute) do
    case get_reference_constraint(constraints) do
      nil -> {:field, generate_field(attribute), generate_type(attribute)}
      constraint -> generate_reference_type(constraint, attribute)
    end
  end

  def generate(%{table: table}) do
    # This is an external reference; some other table is referencing
    # this table
    %{referenced_table: referenced_table} = get_reference_constraint(table.attribute.constraints)

    options =
      generate_reference_options(table.attribute, referenced_table, referenced_table.table.name)

    column_num = table.attribute.num

    relationship =
      case get_unique_constraint(table.attribute.constraints) do
        %{type: :uniq, with: [^column_num]} -> :has_one
        nil -> :has_many
        _ -> :has_many
      end

    # association = format_assoc(options[:fk], table.name)
    #
    # association =
    #   case relationship do
    #     :has_many -> Inflex.pluralize(association)
    #     :has_one -> Inflex.singularize(association)
    #   end

    {relationship, table.name, table_name_to_queryable(table.name), options}
  end

  def get_reference_constraint(constraints) do
    Enum.find(constraints, fn %{type: type} -> type == :foreign_key end)
  end

  def get_unique_constraint(constraints) do
    Enum.find(constraints, fn %{type: type} -> type == :uniq end)
  end

  def generate_field(%{name: name}), do: name

  def generate_type(%{type: %{name: name}}) do
    name = String.replace(name, ~r/^[_]/, "")
    type = @type_map[name] || name

    case Regex.match?(~r/^[A-Z]/, type) do
      true -> type
      false -> ":#{type}"
    end
  end

  def generate_reference_type(
        %{type: :foreign_key, referenced_table: %{table: %{name: table_name}} = referenced_table},
        attribute
      ) do
    options = generate_reference_options(attribute, referenced_table, table_name)

    {:belongs_to, (format_assoc(options[:fk], table_name) || table_name) |> Inflex.singularize(),
     table_name_to_queryable(table_name), options}
  end

  def generate_reference_options(attribute, referenced_table, table_name) do
    [:fk, :ref]
    |> Enum.map(fn key ->
      case key do
        :fk ->
          if !is_standard_foreign_key(attribute.name, table_name) do
            {:fk, attribute.name}
          end

        :ref ->
          referenced_id = hd(referenced_table.attributes).name

          if length(referenced_table.attributes) == 1 && referenced_id != "id" do
            {:ref, referenced_id}
          end
      end
    end)
    |> Enum.filter(fn v -> v end)
    |> Enum.into([])
  end

  def to_string({:field, "id", _type}) do
    ""
  end

  def to_string({:field, name, type}) do
    IO.puts("""
    Fix this to_string for field
    # See https://dennisbeatty.com/use-the-new-enum-type-in-ecto-3-5.html
    """)

    case String.match?(type, ~r/(types?|role|vector)$/) do
      true -> ""
      false -> "field :#{name}, #{type}"
    end
  end

  def to_string({:belongs_to, name, queryable, options}) do
    "belongs_to :#{name}, #{queryable}"
    |> process_options(options)
  end

  def to_string({:has_many, name, queryable, options}) do
    "has_many :#{name}, #{queryable}"
    |> process_options(options)
  end

  def to_string({:has_one, name, queryable, options}) do
    "has_one :#{name}, #{queryable}"
    |> process_options(options)
  end

  defp process_options(base, options) do
    Enum.reduce(options, base, fn {k, v}, acc ->
      case k do
        :fk ->
          "#{acc}, foreign_key: :#{v}"

        :ref ->
          "#{acc}, references: :#{v}"
      end
    end)
  end

  defp table_name_to_queryable(name), do: name |> Inflex.singularize() |> Macro.camelize()

  defp is_standard_foreign_key(name, table_name) do
    name == "#{Inflex.singularize(table_name)}_id"
  end

  def format_assoc(nil, _), do: nil

  @doc """
  Formats the association string, trimming _id at the end

  Example:
    
    iex> EctoGen.FieldGenerator.format_assoc("comment_id", "comments")
    "comment"
  """
  def format_assoc(str, table_name) when is_binary(str) do
    id_regex = ~r/_id$/

    case String.match?(str, id_regex) do
      # if the association ends with _id, trim it and return
      true ->
        String.split(str, ~r/_id$/) |> hd

      # if the foreign_key does not end with _id, append the table name
      # to avoid conflicts (ecto does not allow association and foreign_key
      # to be the same
      false ->
        (str <> "_" <> Macro.underscore(table_name)) |> Inflex.singularize()
    end
  end
end
