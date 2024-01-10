defmodule Introspection.Model do
  def from_introspection(
        %{"class" => tables, "index" => indexes, "procedure" => functions, "type" => types} =
          introspection_result,
        schema
      ) do
    references_and_tables =
      tables
      |> Stream.filter(fn table -> table["namespaceName"] == schema end)
      |> Stream.map(&build_table_objects/1)
      |> Stream.map(fn table -> add_attributes_for_table(table, introspection_result) end)
      |> Enum.to_list()

    {references, tables} =
      Enum.reduce(references_and_tables, {[], []}, fn
        {references, tables}, {ref_acc, table_acc} ->
          {[references | ref_acc], [tables | table_acc]}
      end)

    # flatten references list
    references =
      Enum.flat_map(references, fn
        x when is_list(x) -> x
        x -> [x]
      end)

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
      |> Stream.map(fn table -> add_indexes_to_table(table, indexes_by_table_id[table.id]) end)
      |> Stream.map(&Map.put(&1, :table_names, PgGen.Utils.get_table_names(&1.name)))
      |> Enum.sort(&(&1.name <= &2.name))

    functions =
      functions
      |> Enum.map(&process_function(&1, types))

    enum_types = lift_types(tables ++ functions)

    %{
      tables: tables,
      enum_types: enum_types,
      functions: sort_functions_by_type(functions, tables)
    }
  end

  def from_introspection(result, _schema) do
    IO.inspect(result, label: "Hmm")
  end

  def build_table_objects(%{
        "id" => id,
        "name" => name,
        "description" => description,
        "aclInsertable" => acl_insertable,
        "aclSelectable" => acl_selectable,
        "aclUpdatable" => acl_updatable,
        "aclDeletable" => acl_deletable,
        "isSelectable" => is_selectable,
        "isInsertable" => is_insertable,
        "isUpdatable" => is_updatable,
        "isDeletable" => is_deletable
      }) do
    %{
      id: id,
      name: name,
      description: description,
      insertable: acl_insertable,
      selectable: acl_selectable,
      updatable: acl_updatable,
      deletable: acl_deletable,
      is_selectable: is_selectable,
      is_insertable: is_insertable,
      is_updatable: is_updatable,
      is_deletable: is_deletable
    }
  end

  @doc """
  Notes on access for select/insert/update/delete

  - If a table is false of any of the is fields, no need to look further
  - If a table is true for the is field, and true for the related acl field, no need to look further
  - If a table if true for the is field and false for the related acl field, look to attributes
    - If an attribute is true for the related acl field, then it can be used for that select/insert/update/delete
    - If no attributes are true for that related acl field, it can't be used
  """
  def add_table_accessibility(
        %{
          insertable: insertable,
          selectable: selectable,
          updatable: updatable,
          deletable: deletable,
          is_selectable: is_selectable,
          is_insertable: is_insertable,
          is_updatable: is_updatable,
          is_deletable: is_deletable,
          attributes: attributes
        } = table
      ) do
    selectable = is_selectable && (selectable || !is_nil(Enum.find(attributes, & &1.selectable)))
    insertable = is_insertable && (insertable || !is_nil(Enum.find(attributes, & &1.insertable)))
    updatable = is_updatable && (updatable || !is_nil(Enum.find(attributes, & &1.updatable)))
    deletable = is_deletable && deletable

    Map.merge(table, %{
      selectable: selectable,
      insertable: insertable,
      updatable: updatable,
      deletable: deletable
    })
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
      |> Stream.filter(fn attr -> attr["classId"] == table_id end)
      |> Stream.map(
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
      |> Stream.map(fn attr -> add_type_for_attribute(attr, introspection_result["type"]) end)
      |> Stream.map(fn attr ->
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

    has_composite_pk =
      Enum.filter(attributes, fn %{constraints: constraints} ->
        Enum.find(constraints, fn
          %{type: :primary_key} -> true
          _ -> false
        end)
      end)
      |> length > 1

    table_with_attributes =
      table
      |> Map.put(:attributes, attributes)
      |> Map.put(:has_composite_pk, has_composite_pk)
      |> add_table_accessibility()

    {references ++ join_references, table_with_attributes}
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
      |> Map.put(:is_pg_array, type["isPgArray"])
      |> Map.put(:enum_variants, type["enumVariants"])

    my_type =
      if type["isPgArray"] do
        array_type = Enum.find(types, fn t -> t["id"] == type["arrayItemTypeId"] end)

        my_array_type =
          %{}
          |> Map.put(:type_id, array_type["id"])
          |> Map.put(:description, array_type["description"])
          |> Map.put(:tags, array_type["tags"])
          |> Map.put(:name, array_type["name"])
          |> Map.put(:category, array_type["category"])
          |> Map.put(:is_pg_array, array_type["isPgArray"])
          |> Map.put(:enum_variants, array_type["enumVariants"])

        Map.put(my_type, :array_type, my_array_type)
      else
        my_type
      end

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
      Stream.filter(constraints, fn %{"keyAttributeNums" => attrNums} ->
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

  # {
  #   "classId": "1031993",
  #   "description": null,
  #   "foreignClassId": null,
  #   "foreignKeyAttributeNums": null,
  #   "id": "1032002",
  #   "keyAttributeNums": [2, 4],
  #   "kind": "constraint",
  #   "name": "pinned_items_object_id_comment_id_key",
  #   "type": "u"
  # }
  def build_constraint(%{"type" => "u", "keyAttributeNums" => attr_nums, "name" => name}, _, _) do
    %{type: :uniq, with: attr_nums, name: name}
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
                attribute: reference,
                has_composite_pk:
                  Map.get(tables_by_id, reference.parent_table.id) |> Map.get(:has_composite_pk)
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
    |> Stream.map(fn reference ->
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

  def lift_types(tables_or_functions) do
    tables_or_functions
    |> Stream.map(&get_enum_types/1)
    |> Stream.flat_map(fn
      x when is_list(x) -> x
      x -> [x]
    end)
    |> Enum.uniq()
  end

  defp get_enum_types(%{args: args}) do
    get_enum_types(args)
  end

  defp get_enum_types(%{attributes: attrs}) do
    get_enum_types(attrs)
  end

  defp get_enum_types(attrs) when is_list(attrs) do
    Stream.filter(attrs, fn attr ->
      is_enum_type =
        case attr.type[:enum_variants] do
          nil -> false
          _ -> true
        end

      is_enum_array_type =
        with %{enum_variants: enum_variants} <- Map.get(attr.type, :array_type) do
          !!enum_variants
        else
          _ ->
            false
        end

      is_enum_type || is_enum_array_type
    end)
    |> Enum.map(fn attr -> attr.type end)
  end

  def add_indexes_to_table(table, nil), do: table

  def add_indexes_to_table(table, table_indexes) do
    indexed_attrs =
      Stream.map(
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

    boolean_cols =
      table.attributes
      |> Stream.filter(fn
        %{type: %{name: "bool"}} -> true
        _ -> false
      end)
      |> Enum.map(fn attr -> {attr.name, attr.type} end)

    # if table.name == "object_tasks" do
    #   IO.inspect(boolean_cols)
    #   require IEx; IEx.pry
    # end
    #
    indexed_attrs =
      (indexed_attrs ++ boolean_cols)
      |> Enum.uniq()

    Map.put(table, :indexed_attrs, indexed_attrs)
  end

  def process_function(
        %{
          "aclExecutable" => executable,
          "isStable" => is_stable,
          "isStrict" => is_strict,
          "argNames" => arg_names,
          "argDefaultsNum" => arg_defaults_num,
          "argTypeIds" => arg_type_ids,
          "description" => description,
          "inputArgsCount" => args_count,
          "name" => name,
          "returnTypeId" => return_type_id,
          "returnsSet" => returns_set,
          "isDeprecated" => is_deprecated
        },
        types
      ) do
    underscore_prefixed_arg_names =
      arg_names
      |> Enum.filter(fn name -> String.starts_with?(name, "_") end)

    arg_names =
      arg_names
      |> Enum.map(fn
        "_" <> name -> name
        name -> name
      end)

    trimmed_arg_names =
      arg_names
      |> Enum.slice(0, args_count)

    trimmed_arg_types =
      arg_type_ids
      |> Enum.slice(0, args_count)
      |> Stream.map(&add_type_for_attribute(%{type_id: &1}, types))
      |> Stream.with_index()
      |> Enum.map(fn {arg, index} -> Map.put(arg, :name, Enum.at(arg_names, index)) end)
      |> Enum.map(fn arg ->Map.put(arg, :prefixed_with_underscore, Enum.member?(underscore_prefixed_arg_names, "_#{arg.name}")) end)

    return_type =
      if args_count < length(arg_names) do
        return_type_names = Enum.slice(arg_names, args_count..-1//1)

        record_attr_types =
          arg_type_ids
          |> Enum.slice(args_count..-1//1)
          |> Enum.with_index(fn type_id, index ->
            add_type_for_attribute(
              %{type_id: type_id, name: Enum.at(return_type_names, index)},
              types
            )
          end)

        add_type_for_attribute(%{type_id: return_type_id}, types)
        |> Map.put(:attrs, record_attr_types)
        |> Map.put(:name, "#{name}_record")
        |> Map.put(:composite_type, true)
        |> put_in([:type, :name], "#{name}_record")
      else
        add_type_for_attribute(%{type_id: return_type_id}, types)
      end

    %{
      executable: executable,
      is_stable: is_stable,
      is_strict: is_strict,
      arg_names: trimmed_arg_names,
      description: description,
      args_count: args_count,
      args_with_default_count: arg_defaults_num,
      args: trimmed_arg_types,
      return_type: return_type,
      name: name,
      return_type_id: return_type_id,
      returns_set: returns_set,
      is_deprecated: is_deprecated
    }
  end

  def sort_functions_by_type(functions, tables) do
    table_names = Enum.map(tables, fn %{name: name} -> name end)

    acc = %{
      computed_columns_by_table: Enum.map(table_names, &{&1, []}) |> Enum.into(%{}),
      queries: [],
      mutations: []
    }

    functions
    |> Enum.reduce(acc, fn
      %{is_stable: true} = function, acc ->
        case belongs_to_table(function, table_names) do
          nil ->
            update_in(acc, [:queries], fn list -> [function | list] end)

          table_name ->
            func_name_re = Regex.compile!("^#{table_name}_")
            simplified_name = String.replace(function.name, func_name_re, "")

            update_in(acc, [:computed_columns_by_table, table_name], fn list ->
              [Map.put(function, :simplified_name, simplified_name) | list]
            end)
        end

      %{is_stable: false} = function, acc ->
        update_in(acc, [:mutations], fn list -> [function | list] end)
    end)
  end

  defp belongs_to_table(function, table_names) do
    table_name = function_prefix_matches_table_name(function.name, table_names)
    first_arg_is_record(function, table_name)
  end

  defp first_arg_is_record(_, nil), do: nil
  defp first_arg_is_record(%{args: []}, _table_name), do: nil

  defp first_arg_is_record(%{args: [first_arg | _]}, table_name) do
    if first_arg.type.name === table_name, do: table_name
  end

  defp function_prefix_matches_table_name(function_name, tables_by_name) do
    match_index =
      tables_by_name
      |> Enum.map(&Regex.compile!("^#{&1}_"))
      |> Enum.find_index(fn table_name_re -> String.match?(function_name, table_name_re) end)

    case match_index do
      n when is_number(n) -> Enum.at(tables_by_name, n)
      nil -> nil
    end
  end
end
