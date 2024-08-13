defmodule PgGen.Builder do
  @moduledoc """
  Takes data from Introspection and builds the attributes/fields that we will
  use to generate the Ecto and Absinthe schemas.
  """
  require Logger

  def build(%{constraints: constraints} = attribute) do
    case get_reference_constraint(constraints) do
      nil ->
        {:field, build_field(attribute), build_type(attribute), build_field_options(attribute)}

      constraint ->
        build_reference_type(constraint, attribute)
    end
  end

  # build a computed column
  def build(
        %{return_type: return_type, simplified_name: simplified_name, returns_set: returns_set} =
          attr
      ) do
    {relation, type} =
      cond do
        return_type.type.name in EctoGen.FieldGenerator.type_list() ->
          {:field, build_type(return_type)}

        get_in(return_type, [:type, :array_type, :name]) in EctoGen.FieldGenerator.type_list() ->
          {:field, build_type(return_type)}

        true ->
          relation_type =
            if returns_set do
              :has_many
            else
              :has_one
            end

          {relation_type, table_name_to_queryable(return_type.type.name)}
      end

    {relation, simplified_name, type,
     [description: attr.description, virtual: true, is_not_null: false]}
  end

  def build(%{
        table: %{
          attribute: %{
            joined_to: joined_to,
            parent_table: parent_table,
            name: attr_name,
            constraints: constraints
          }
        }
      }) do
    %{referenced_table: join_referenced_table} = get_reference_constraint(joined_to.constraints)
    %{referenced_table: referenced_table} = get_reference_constraint(constraints)
    joined_table_name = join_referenced_table.table.name

    join_keys =
      case is_standard_foreign_key(attr_name, referenced_table.table.name) &&
             is_standard_foreign_key(joined_to.name, joined_table_name) do
        true -> []
        false -> [join_keys: [{attr_name, "id"}, {joined_to.name, "id"}]]
      end

    options =
      build_reference_options(joined_to, join_referenced_table, joined_table_name,
        external_reference: true
      )
      |> Keyword.merge(join_keys)

    {:many_to_many, joined_table_name, table_name_to_queryable(joined_table_name),
     Keyword.merge([join_through: parent_table.name], options)}
  end

  def build(%{table: table}) do
    # This is an external reference; some other table is referencing
    # this table
    %{referenced_table: referenced_table} = get_reference_constraint(table.attribute.constraints)

    options =
      build_reference_options(table.attribute, referenced_table, referenced_table.table.name,
        external_reference: true
      )

    column_num = table.attribute.num

    relationship =
      case get_unique_constraint(table.attribute.constraints) do
        %{type: :uniq, with: [^column_num]} ->
          :has_one

        nil ->
          case has_primary_key_constraint(table.attribute.constraints) do
            true ->
              if Map.get(table, :has_composite_pk) do
                :has_many
              else
                :has_one
              end

            false ->
              :has_many
          end

        _ ->
          :has_many
      end

    {relationship, table.name, table_name_to_queryable(table.name), options}
  end

  def has_primary_key_constraint(constraints) do
    !is_nil(Enum.find(constraints, fn %{type: type} -> type == :primary_key end))
  end

  def get_reference_constraint(constraints) do
    Enum.find(constraints, fn %{type: type} -> type == :foreign_key end)
  end

  def get_unique_constraint(constraints) do
    Enum.find(constraints, fn %{type: type} -> type == :uniq end)
  end

  def build_field(%{name: name}), do: name

  def build_type(%{
        type: %{
          name: name,
          category: "A",
          array_type: %{category: "E", enum_variants: enum_variants}
        }
      })
      when not is_nil(enum_variants) and length(enum_variants) > 0 do
    {:enum_array, String.replace(name, ~r/^[_]/, ""), enum_variants}
  end

  def build_type(%{type: %{name: name, category: "A"}}) do
    {:array, String.replace(name, ~r/^[_]/, "")}
  end

  def build_type(%{type: %{name: name, enum_variants: nil}}) do
    name
  end

  def build_type(%{type: %{enum_variants: _enum_variants}}) do
    "enum"
  end

  def build_field_options(
        %{
          is_not_null: is_not_null,
          has_default: has_default,
          description: description,
          type: %{enum_variants: enum_variants, name: name}
        } = attr
      ) do
    [
      is_not_null: is_not_null,
      has_default: has_default,
      default_value:
        if(has_default && is_nil(Map.get(attr, :default_value, :nope)),
          do: "nullable",
          else: Map.get(attr, :default_value)
        ),
      description: description,
      values: enum_variants,
      enum_name: if(is_nil(enum_variants), do: nil, else: name)
    ]
    |> Stream.filter(fn {_k, v} -> !is_nil(v) end)
    |> Enum.into(Keyword.new())
  end

  def build_reference_type(
        %{type: :foreign_key, referenced_table: %{table: %{name: table_name}} = referenced_table},
        attribute
      ) do
    options =
      build_reference_options(attribute, referenced_table, table_name, external_reference: false)
      # manually adding default value b/c references don't apply here anyway
      |> Keyword.merge(build_field_options(Map.put(attribute, :default_value, nil)))
      |> Keyword.put(:type, attribute.type.name)

    {:belongs_to, (format_assoc(options[:fk], table_name) || table_name) |> Inflex.singularize(),
     table_name_to_queryable(table_name), Keyword.put_new(options, :fk_type, attribute.type.name)}
  end

  def build_reference_options(attribute, referenced_table, table_name,
        external_reference: external_reference
      ) do
    [:fk, :ref, :pk, :type]
    |> Stream.map(fn key ->
      case key do
        :fk ->
          if !is_standard_foreign_key(attribute.name, table_name) do
            {:fk, attribute.name}
          else
            {:standard_fk, attribute.name}
          end

        :pk ->
          if !external_reference && has_primary_key_constraint(attribute.constraints) do
            {:pk, attribute.name}
          end

        :type ->
          if !external_reference && has_primary_key_constraint(attribute.constraints) do
            {:type, attribute.type.name}
          end

        :ref ->
          referenced_id = hd(referenced_table.attributes).name

          if length(referenced_table.attributes) == 1 && referenced_id != "id" do
            {:ref, referenced_id}
          end
      end
    end)
    |> Stream.filter(fn v -> v end)
    |> Enum.into([])
  end

  def format_assoc(nil, _), do: nil

  @doc """
  Formats the association string, trimming _id at the end

  Example:
    
    iex> PgGen.Builder.format_assoc("comment_id", "comments")
    "comment"
  """
  def format_assoc(str, table_name) when is_binary(str) do
    id_regex = ~r/_id$/

    case String.match?(str, id_regex) do
      # if the association ends with _id, trim it and return
      true ->
        String.split(str, ~r/_id$/) |> List.first()

      # if the foreign_key does not end with _id, append the table name
      # to avoid conflicts (ecto does not allow association and foreign_key
      # to be the same
      false ->
        (str <> "_" <> Macro.underscore(table_name)) |> Inflex.singularize()
    end
  end

  defp table_name_to_queryable(name), do: name |> Inflex.singularize() |> Macro.camelize()

  defp is_standard_foreign_key(name, table_name) do
    name == "#{Inflex.singularize(table_name)}_id"
  end
end
