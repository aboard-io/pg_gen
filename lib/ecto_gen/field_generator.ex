defmodule EctoGen.FieldGenerator do
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

    {relationship, table.name, table_name_to_queryable(table.name), options}
  end

  def get_reference_constraint(constraints) do
    Enum.find(constraints, fn %{type: type} -> type == :foreign_key end)
  end

  def get_unique_constraint(constraints) do
    Enum.find(constraints, fn %{type: type} -> type == :uniq end)
  end

  def generate_field(%{name: name}), do: name
  def generate_type(%{type: %{name: name}}), do: name

  def generate_reference_type(
        %{type: :foreign_key, referenced_table: %{table: %{name: table_name}} = referenced_table},
        attribute
      ) do
    options = generate_reference_options(attribute, referenced_table, table_name)

    {:belongs_to, table_name, table_name_to_queryable(table_name), options}
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

  def to_string({:belongs_to, name, queryable}, options \\ []) do
    base = "belongs_to :#{name}, #{queryable}"

    Enum.reduce(options, base, fn {k, v}, acc ->
      case k do
        :fk ->
          "#{acc}, foreign_key: \"#{v}\""

        :ref ->
          "#{acc}, references: \"#{v}\""
      end
    end)
  end

  defp table_name_to_queryable(name), do: name |> Inflex.singularize() |> Macro.camelize()

  defp is_standard_foreign_key(name, table_name) do
    name == "#{Inflex.singularize(table_name)}_id"
  end
end
