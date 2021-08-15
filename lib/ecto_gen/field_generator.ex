defmodule EctoGen.FieldGenerator do
  def generate(%{constraints: constraints} = attribute) do
    case get_reference_constraint(constraints) do
      nil -> {:field, generate_field(attribute), generate_type(attribute)}
      constraint -> generate_reference_type(constraint, attribute)
    end
  end

  def get_reference_constraint(constraints) do
    Enum.find(constraints, fn %{type: type} -> type == :foreign_key end)
  end

  def generate_field(%{name: name}), do: name
  def generate_type(%{type: %{name: name}}), do: name

  def generate_reference_type(
        %{type: :foreign_key, referenced_table: %{table: %{name: name}} = referenced_table},
        attribute
      ) do
    options =
      [:fk, :ref]
      |> Enum.map(fn key ->
        case key do
          :fk ->
            if attribute.name != "#{Inflex.singularize(name)}_id" do
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

    {:belongs_to, name, name |> Inflex.singularize() |> Macro.camelize(), options}
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
end
