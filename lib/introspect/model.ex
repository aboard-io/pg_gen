defmodule Introspection.Model do
  def from_introspection(
        %{"class" => tables} = introspection_result,
        schema
      ) do
    tables
    |> Enum.filter(fn table -> table["namespaceName"] == schema end)
    |> Enum.map(&build_table_objects/1)
    |> Enum.map(fn table -> add_attributes_for_table(table, introspection_result) end)
  end

  def from_introspection(result, _schema) do
    IO.inspect(Map.keys(result))
    IO.puts("Hmm")
  end

  def build_table_objects(%{"id" => id, "name" => name}) do
    %{id: id, name: name}
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
        %{id: table_id} = table,
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
      |> Enum.map(fn %{
                       "aclInsertable" => true,
                       "aclSelectable" => true,
                       "aclUpdatable" => true,
                       "columnLevelSelectGrant" => false,
                       "identity" => "",
                       "kind" => "attribute",
                       "typeModifier" => nil
                     } = attr ->
        %{
          name: attr["name"],
          description: attr["description"],
          num: attr["num"],
          is_not_null: attr["isNotNull"],
          has_default: attr["hasDefault"],
          type_id: attr["typeId"],
          # below will be added in another step
          # TODO delete later
          type: nil,
          constraints: nil
        }
      end)
      |> Enum.map(fn attr -> add_type_for_attribute(attr, introspection_result["type"]) end)
      |> Enum.map(fn attr ->
        add_constraints_for_attribute(
          attr,
          contraints_for_table,
          attrs_by_class_id_and_num,
          table_name_by_id
        )
      end)

    Map.put(table, :attributes, attributes)
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
        build_constraint(constraints, attrs_by_class_id_and_num, table_name_by_id)
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
        # Enum.find(table.attributes, fn attr -> attr.num == num end)
      end)

    %{
      type: :foreign_key,
      meta: %{table: %{id: foriegn_table_id, name: table_name}, attributes: attributes}
    }
  end
end
