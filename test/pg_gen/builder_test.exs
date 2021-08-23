defmodule PgGen.BuilderTest do
  use ExUnit.Case, async: true
  doctest PgGen.Builder
  alias PgGen.Builder

  test "it parses a basic primary key id field" do
    id_field = %{
      constraints: [%{type: :primary_key}],
      description: nil,
      has_default: true,
      is_not_null: true,
      name: "id",
      num: 1,
      type: %{
        category: "U",
        description: "UUID datatype",
        name: "uuid",
        tags: %{},
        enum_variants: nil
      },
      type_id: "2950"
    }

    assert Builder.build(id_field) ==
             {:field, "id", "uuid", [is_not_null: true, has_default: true]}
  end

  test "it handles an enum type" do
    field = %{
      constraints: [],
      description: nil,
      has_default: true,
      is_not_null: true,
      name: "enum_field",
      num: 1,
      type: %{
        category: "E",
        description: "Enum",
        name: "some_enum",
        enum_variants: ["foo", "bar"],
        tags: %{}
      },
      type_id: "2950"
    }

    assert Builder.build(field) ==
             {:field, "enum_field", "enum",
              is_not_null: true, has_default: true, values: ["foo", "bar"], enum_name: "some_enum"}
  end

  test "it generates a belongs_to relationship" do
    # Because it holds the foriegn key, it belongs_to the association
    foriegn_field = %{
      constraints: [
        %{
          referenced_table: %{
            attributes: [%{name: "id", num: 1}],
            table: %{id: "231270", name: "workflows"}
          },
          type: :foreign_key
        }
      ],
      description: nil,
      has_default: false,
      is_not_null: true,
      name: "workflow_id",
      num: 2,
      type: %{
        category: "U",
        description: "UUID datatype",
        name: "uuid",
        tags: %{}
      },
      type_id: "2950"
    }

    assert Builder.build(foriegn_field) ==
             {:belongs_to, "workflow", "Workflow", []}
  end

  test "it generates a belongs_to relationship with an unexpected foreign_key" do
    # Because it holds the foriegn key, it belongs_to the association
    foriegn_field = %{
      constraints: [
        %{
          referenced_table: %{
            attributes: [%{name: "id", num: 1}],
            table: %{id: "231270", name: "workflows"}
          },
          type: :foreign_key
        }
      ],
      description: nil,
      has_default: false,
      is_not_null: true,
      name: "my_workflow_id",
      num: 2,
      type: %{
        category: "U",
        description: "UUID datatype",
        name: "uuid",
        tags: %{}
      },
      type_id: "2950"
    }

    assert Builder.build(foriegn_field) ==
             {:belongs_to, "my_workflow", "Workflow", [fk: "my_workflow_id"]}
  end

  test "it generates a belongs_to relationship with an unexpected referenced id" do
    # Because it holds the foriegn key, it belongs_to the association
    foriegn_field = %{
      constraints: [
        %{
          referenced_table: %{
            attributes: [%{name: "uuid", num: 1}],
            table: %{id: "231270", name: "workflows"}
          },
          type: :foreign_key
        }
      ],
      description: nil,
      has_default: false,
      is_not_null: true,
      name: "workflow_id",
      num: 2,
      type: %{
        category: "U",
        description: "UUID datatype",
        name: "uuid",
        tags: %{}
      },
      type_id: "2950"
    }

    assert Builder.build(foriegn_field) ==
             {:belongs_to, "workflow", "Workflow", [ref: "uuid"]}
  end

  test "it generates a has_many relationship" do
    # Because it holds the foriegn key, it belongs_to the association
    reference = %{
      table: %{
        attribute: %{
          constraints: [
            %{
              referenced_table: %{
                attributes: [%{name: "id", num: 1}],
                table: %{id: "231389", name: "object_comments"}
              },
              type: :foreign_key
            }
          ],
          description: nil,
          has_default: false,
          is_not_null: false,
          name: "object_comment_id",
          num: 3,
          parent_table: %{id: "231463", name: "user_activity_events"},
          type: %{
            category: "U",
            description: "UUID datatype",
            name: "uuid",
            tags: %{}
          },
          type_id: "2950"
        },
        id: "231463",
        name: "user_activity_events"
      },
      via: [%{name: "id", num: 1}]
    }

    assert Builder.build(reference) ==
             {:has_many, "user_activity_events", "UserActivityEvent", []}
  end

  test "it generates a has_many relationship with an unexpected foreign_key" do
    # Because it holds the foriegn key, it belongs_to the association
    reference = %{
      table: %{
        attribute: %{
          constraints: [
            %{
              referenced_table: %{
                attributes: [%{name: "id", num: 1}],
                table: %{id: "231389", name: "object_comments"}
              },
              type: :foreign_key
            }
          ],
          description: nil,
          has_default: false,
          is_not_null: false,
          name: "comment_id",
          num: 3,
          parent_table: %{id: "231463", name: "user_activity_events"},
          type: %{
            category: "U",
            description: "UUID datatype",
            name: "uuid",
            tags: %{}
          },
          type_id: "2950"
        },
        id: "231463",
        name: "user_activity_events"
      },
      via: [%{name: "id", num: 1}]
    }

    assert Builder.build(reference) ==
             {:has_many, "user_activity_events", "UserActivityEvent", [fk: "comment_id"]}
  end

  test "it generates a has_one relationship" do
    # Because it holds the foriegn key, it belongs_to the association
    reference = %{
      table: %{
        attribute: %{
          constraints: [
            %{
              referenced_table: %{
                attributes: [%{name: "id", num: 1}],
                table: %{id: "231389", name: "object_comments"}
              },
              type: :foreign_key
            },
            %{
              type: :uniq,
              with: [3]
            }
          ],
          description: nil,
          has_default: false,
          is_not_null: false,
          name: "object_comment_id",
          num: 3,
          parent_table: %{id: "231463", name: "user_activity_events"},
          type: %{
            category: "U",
            description: "UUID datatype",
            name: "uuid",
            tags: %{}
          },
          type_id: "2950"
        },
        id: "231463",
        name: "user_activity_events"
      },
      via: [%{name: "id", num: 1}]
    }

    assert Builder.build(reference) ==
             {:has_one, "user_activity_events", "UserActivityEvent", []}
  end

  test "it handles many_to_many join relationships" do
    join = %{
      table: %{
        attribute: %{
          constraints: [
            %{
              referenced_table: %{
                attributes: [%{name: "id", num: 1}],
                table: %{id: "231356", name: "objects"}
              },
              type: :foreign_key
            },
            %{type: :uniq, with: [2, 3]}
          ],
          description: nil,
          has_default: false,
          is_not_null: true,
          joined_to: %{
            constraints: [
              %{type: :uniq, with: [2, 3]},
              %{
                referenced_table: %{
                  attributes: [%{name: "id", num: 1}],
                  table: %{id: "231079", name: "users"}
                },
                type: :foreign_key
              }
            ],
            description: nil,
            has_default: true,
            is_not_null: true,
            name: "user_id",
            num: 2,
            parent_table: %{id: "231957", name: "user_objects"},
            type: %{category: "U", description: "UUID datatype", name: "uuid", tags: %{}},
            type_id: "2950"
          },
          name: "object_id",
          num: 3,
          parent_table: %{id: "231957", name: "user_objects"},
          type: %{category: "U", description: "UUID datatype", name: "uuid", tags: %{}},
          type_id: "2950"
        }
      }
    }

    assert(
      Builder.build(join) ==
        {:many_to_many, "users", "User", join_through: "user_objects"}
    )
  end
end
