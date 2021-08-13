defmodule Introspection.ModelTest do
  use ExUnit.Case, async: true
  alias Introspection.Model
  doctest Introspection.Model

  @user_introspection_result File.read!("static/user-test-introspection.json")
                             |> Jason.decode!()

  test "adds attrs and types and constraints to a simple user database" do
    expected = %{
      id: "233794",
      name: "users",
      attributes: [
        %{
          name: "email",
          type: %{
            description: "variable-length string, no limit specified",
            name: "text",
            category: "S",
            tags: %{}
          },
          type_id: "25",
          description: nil,
          has_default: false,
          is_not_null: false,
          constraints: [
            %{
              type: :uniq,
              with: [3]
            }
          ],
          num: 3
        },
        %{
          name: "name",
          type: %{
            description: "variable-length string, no limit specified",
            name: "text",
            category: "S",
            tags: %{}
          },
          type_id: "25",
          description: nil,
          has_default: false,
          is_not_null: false,
          num: 2,
          constraints: []
        },
        %{
          name: "id",
          type: %{
            description: "-2 billion to 2 billion integer, 4-byte storage",
            name: "int4",
            tags: %{},
            category: "N"
          },
          type_id: "23",
          description: nil,
          has_default: true,
          is_not_null: true,
          num: 1,
          constraints: [
            %{
              type: :primary_key
            }
          ]
        }
      ]
    }

    schema = "app_public"

    assert(Model.from_introspection(@user_introspection_result, schema) |> hd == expected)
  end

  test "foreign key constrating" do
    fk_constraint =
      """
      {
        "classId": "236817",
        "description": null,
        "foreignClassId": "236802",
        "foreignKeyAttributeNums": [1],
        "id": "236832",
        "keyAttributeNums": [3],
        "kind": "constraint",
        "name": "comments_post_id_fkey",
        "type": "f"
      }
      """
      |> Jason.decode!()

    attrs_by_class_id_and_num = %{
      "236802_1" => %{"name" => "id", "num" => 1},
      "236802_2" => %{"name" => "body", "num" => 2}
    }

    table_name_by_id = %{
      "236802" => "posts"
    }

    expected = %{
      type: :foreign_key,
      meta: %{table: %{name: "posts", id: "236802"}, attributes: [%{name: "id", num: 1}]}
    }

    assert Model.build_constraint(fk_constraint, attrs_by_class_id_and_num, table_name_by_id) ==
             expected
  end
end
