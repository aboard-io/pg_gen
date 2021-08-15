defmodule EctoGen.FieldGeneratorTest do
  use ExUnit.Case, async: true
  doctest EctoGen.FieldGenerator
  alias EctoGen.FieldGenerator

  # @test_table File.read!("static/parsed-stages.json") |> Jason.decode!()
  # @test_table Introspection.run("winslow", String.split("app_public", ","))
  #             |> Introspection.Model.from_introspection("app_public")
  #             |> Enum.at(9)

  test "it parses a basic primary key id field" do
    id_field = %{
      constraints: [%{type: :primary_key}],
      description: nil,
      has_default: true,
      is_not_null: true,
      name: "id",
      num: 1,
      type: %{category: "U", description: "UUID datatype", name: "uuid", tags: %{}},
      type_id: "2950"
    }

    assert FieldGenerator.generate(id_field) == {:field, "id", "uuid"}
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

    assert FieldGenerator.generate(foriegn_field) ==
             {:belongs_to, "workflows", "Workflow", []}
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

    assert FieldGenerator.generate(foriegn_field) ==
             {:belongs_to, "workflows", "Workflow", [fk: "my_workflow_id"]}
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

    assert FieldGenerator.generate(foriegn_field) ==
             {:belongs_to, "workflows", "Workflow", [ref: "uuid"]}
  end

  test "it converts tuple to string" do
    assert FieldGenerator.to_string({:belongs_to, "workflows", "Workflow"}) ==
             "belongs_to :workflows, Workflow"
  end

  test "it sets foriegn key if it's not {singular_table}_id" do
    assert FieldGenerator.to_string({:belongs_to, "workflows", "Workflow"}, fk: "wf") ==
             "belongs_to :workflows, Workflow, foreign_key: \"wf\""
  end

  test "it sets reference id if it's not id" do
    assert FieldGenerator.to_string({:belongs_to, "workflows", "Workflow"}, ref: "uuid") ==
             "belongs_to :workflows, Workflow, references: \"uuid\""
  end
end
