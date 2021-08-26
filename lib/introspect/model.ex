defmodule Introspection.Model do
  def from_introspection(
        %{"class" => tables, "index" => indexes} = introspection_result,
        schema
      ) do
    references_and_tables =
      tables
      |> Enum.filter(fn table -> table["namespaceName"] == schema end)
      |> Enum.filter(fn table -> table["classKind"] != "c" end)
      |> Enum.map(&build_table_objects/1)
      |> Enum.map(fn table -> add_attributes_for_table(table, introspection_result) end)

    {references, tables} =
      Enum.reduce(references_and_tables, {[], []}, fn {references, tables},
                                                      {ref_acc, table_acc} ->
        {[references | ref_acc], [tables | table_acc]}
      end)

    # flatten references list
    references =
      Enum.flat_map(references, fn
        x when is_list(x) -> x
        x -> [x]
      end)

    enum_types = lift_types(tables)

    indexes_by_table_id =
      Enum.reduce(indexes, %{}, fn %{"classId" => table_id} = index, acc ->
        case Map.get(acc, table_id) do
          nil -> Map.put(acc, table_id, [index])
          table_indexes -> Map.put(acc, table_id, [index | table_indexes])
        end
      end)

    tables =
      add_references_to_foriegn_tables(
        tables,
        references
      )
      |> Enum.map(fn table -> add_indexes_to_table(table, indexes_by_table_id[table.id]) end)

    %{tables: tables, enum_types: enum_types}
  end

  def from_introspection(result, _schema) do
    IO.inspect(Map.keys(result))
    IO.puts("Hmm")
  end

  def build_table_objects(%{
        "id" => id,
        "name" => name,
        "description" => description,
        "aclInsertable" => acl_insertable,
        "aclSelectable" => acl_selectable,
        "aclUpdatable" => acl_updatable,
        "aclDeletable" => acl_deletable
      }) do
    %{
      id: id,
      name: name,
      description: description,
      insertable: acl_insertable,
      selectable: acl_selectable,
      updatable: acl_updatable,
      deletable: acl_deletable
    }
  end

  @doc """
  Attribute looks like this:

  ```
    %{
      "aclInsertable" => true,
      "aclSelectable" => true,
      "aclUpdatable" => true,
      "columnLevelSelectGrant" => false,
      "identity" => "",
      "kind" => "attribute",
      "typeModifier" => nil

      # I'm not sure if I need what's above, so I'm going to pattern match on that
      # and fix if there are errors

      "classId" => "233783",
      "description" => nil,
      "hasDefault" => true,
      "isNotNull" => true,
      "name" => "id",
      "num" => 1,
      "typeId" => "23",
    }
  ```
  """

  def add_attributes_for_table(
        %{id: table_id, name: table_name} = table,
        %{"attribute" => attributes} = introspection_result
      ) do
    contraints_for_table =
      Enum.filter(introspection_result["constraint"], fn constraint ->
        constraint["classId"] == table_id
      end)

    attrs_by_class_id_and_num =
      attributes
      |> Enum.reduce(%{}, fn %{"classId" => class_id, "num" => num} = attribute, acc ->
        Map.put(acc, class_id <> "_" <> Integer.to_string(num), attribute)
      end)

    table_name_by_id =
      introspection_result["class"]
      |> Enum.reduce(%{}, fn %{"id" => id, "name" => name}, acc ->
        Map.put(acc, id, name)
      end)

    attributes =
      attributes
      |> Enum.filter(fn attr -> attr["classId"] == table_id end)
      |> Enum.map(
        # "columnLevelSelectGrant" => ?,
        # atttypmod/typeModifier records type-specific data supplied at table creation time (for example, the maximum length of a varchar column). It is passed to type-specific input functions and length coercion functions. The value will generally be -1 for types that do not need atttypmod
        # currently ignoring this in the implementation
        # "typeModifier" => type_modifier
        fn %{
             "kind" => "attribute"
           } = attr ->
          %{
            insertable: attr["aclInsertable"],
            selectable: attr["aclSelectable"],
            updatable: attr["aclUpdatable"],
            name: attr["name"],
            description: attr["description"],
            num: attr["num"],
            is_not_null: attr["isNotNull"],
            has_default: attr["hasDefault"],
            type_id: attr["typeId"],
            type: nil,
            constraints: nil,
            parent_table: %{name: table_name, id: table_id}
          }
        end
      )
      |> Enum.map(fn attr -> add_type_for_attribute(attr, introspection_result["type"]) end)
      |> Enum.map(fn attr ->
        add_constraints_for_attribute(
          attr,
          contraints_for_table,
          attrs_by_class_id_and_num,
          table_name_by_id
        )
      end)
      |> Enum.sort(fn %{num: num1}, %{num: num2} -> num1 < num2 end)

    references =
      attributes
      |> Enum.filter(fn %{constraints: constraints} ->
        Enum.find(constraints, fn constraint ->
          constraint.type == :foreign_key
        end)
      end)

    join_references =
      if length(references) > 1 do
        generate_join_references(references)
      else
        []
      end

    {references ++ join_references, Map.put(table, :attributes, attributes)}
  end

  @doc """
  Types looks like this:

  ```
  %{
    "arrayItemTypeId" => nil,
    "classId" => nil,
    "comment" => "-2 billion to 2 billion integer, 4-byte storage",
    "domainBaseTypeId" => nil,
    "domainHasDefault" => false,
    "domainIsNotNull" => false,
    "domainTypeModifier" => nil,
    "enumVariants" => nil,
    "id" => "23",
    "isPgArray" => false,
    "kind" => "type",
    "namespaceId" => "11",
    "namespaceName" => "pg_catalog",
    "rangeSubTypeId" => nil,
    "type" => "b",
    "typeLength" => 4

    # all that I know I need is below

    "description" => "-2 billion to 2 billion integer, 4-byte storage",
    "tags" => %{},
    "name" => "int4",
    "category" => "N",
  }
  """
  def add_type_for_attribute(attr, types) do
    type = Enum.find(types, fn type -> type["id"] == attr.type_id end)

    my_type =
      %{}
      |> Map.put(:description, type["description"])
      |> Map.put(:tags, type["tags"])
      |> Map.put(:name, type["name"])
      |> Map.put(:category, type["category"])
      |> Map.put(:enum_variants, type["enumVariants"])

    Map.put(attr, :type, my_type)
  end

  @doc """
  Constraints looks like this:

  ```
  %{
    "classId" => "233794",
    "description" => nil,
    "foreignClassId" => nil,
    "foreignKeyAttributeNums" => nil,
    "id" => "233802",
    "keyAttributeNums" => [1],
    "kind" => "constraint",
    "name" => "users_pkey",
    "type" => "p"
  }

  Types I know so far:
    p: primary_key
    u: unique
    f: foreign_key
  """
  def add_constraints_for_attribute(
        attr,
        constraints,
        attrs_by_class_id_and_num,
        table_name_by_id
      ) do
    attr_constraints =
      Enum.filter(constraints, fn %{"keyAttributeNums" => attrNums} ->
        Enum.any?(attrNums, fn attrNum -> attrNum == attr.num end)
      end)
      |> Enum.map(fn constraints ->
        build_constraint(
          constraints,
          attrs_by_class_id_and_num,
          table_name_by_id
        )
      end)

    Map.put(attr, :constraints, attr_constraints)
  end

  def build_constraint(%{"type" => "p"}, _, _) do
    %{type: :primary_key}
  end

  def build_constraint(%{"type" => "u", "keyAttributeNums" => attr_nums}, _, _) do
    %{type: :uniq, with: attr_nums}
  end

  @doc """
  %{
      "classId" => "236817",
      "description" => nil,
      "foreignClassId" => "236802",
      "foreignKeyAttributeNums" => [1],
      "id" => "236832",
      "keyAttributeNums" => [3],
      "kind" => "constraint",
      "name" => "comments_post_id_fkey",
      "type" => "f"
    }
  """
  def build_constraint(
        %{
          "type" => "f",
          "foreignClassId" => foriegn_table_id,
          "foreignKeyAttributeNums" => fk_attr_nums
        },
        attrs_by_class_id_and_num,
        table_name_by_id
      ) do
    table_name = table_name_by_id[foriegn_table_id]

    attributes =
      fk_attr_nums
      |> Enum.map(fn num ->
        %{"name" => name} = attrs_by_class_id_and_num["#{foriegn_table_id}_#{num}"]
        %{name: name, num: num}
      end)

    %{
      type: :foreign_key,
      referenced_table: %{
        table: %{id: foriegn_table_id, name: table_name},
        attributes: attributes
      }
    }
  end

  def add_references_to_foriegn_tables(tables, references \\ []) when is_list(references) do
    tables_by_id =
      tables
      |> Enum.map(fn %{id: id} = table -> {id, table} end)
      |> Enum.into(%{})

    Enum.reduce(references, tables_by_id, fn reference, acc ->
      # if the parent table is not accessible, do not add it as a foreign reference
      case tables_by_id[reference.parent_table.id].selectable do
        false ->
          acc

        true ->
          %{attributes: attrs, table: %{id: id}} = get_referenced_table(reference)

          new_reference = %{
            table:
              Map.merge(reference.parent_table, %{
                attribute: reference
              }),
            via: attrs
          }

          referenced_by =
            case get_in(acc, [id, :external_references]) do
              nil -> [new_reference]
              existing_references -> [new_reference | existing_references]
            end

          put_in(acc, [id, :external_references], referenced_by)
      end
    end)
    |> Enum.map(fn {_, v} -> v end)
  end

  defp get_referenced_table(%{constraints: constraints}) do
    Enum.find(constraints, fn constraint ->
      constraint.type == :foreign_key && is_map(constraint.referenced_table)
    end)
    |> Map.get(:referenced_table)
  end

  def generate_join_references(references) do
    references
    |> Enum.map(fn reference ->
      other_references = references -- [reference]

      other_references
      |> Enum.map(fn other ->
        Map.put(reference, :joined_to, other)
      end)
    end)
    |> Enum.flat_map(fn
      x when is_list(x) -> x
      x -> [x]
    end)
  end

  def lift_types(tables) do
    tables
    |> Enum.map(&get_enum_types/1)
    |> Enum.flat_map(fn
      x when is_list(x) -> x
      x -> [x]
    end)
    |> Enum.uniq()
  end

  defp get_enum_types(%{attributes: attrs}) when is_list(attrs) do
    Enum.filter(attrs, fn attr ->
      case attr.type[:enum_variants] do
        nil -> false
        _ -> true
      end
    end)
    |> Enum.map(fn attr -> attr.type end)
  end

  def add_indexes_to_table(table, nil), do: table

  def add_indexes_to_table(table, table_indexes) do
    indexed_attrs =
      Enum.map(
        table_indexes,
        fn %{"attributeNums" => attr_nums} ->
          case attr_nums do
            [single_col] ->
              attr = Enum.find(table.attributes, fn %{num: num} -> num == single_col end)
              {attr.name, attr.type}

            _ ->
              nil
          end
        end
      )
      |> Enum.filter(&(!is_nil(&1)))

    Map.put(table, :indexed_attrs, indexed_attrs)
  end
end
