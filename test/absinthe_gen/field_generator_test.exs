defmodule AbsintheGen.FieldGeneratorTest do
  use ExUnit.Case, async: true
  doctest AbsintheGen.FieldGenerator
  alias AbsintheGen.FieldGenerator

  test "it converts field tuple to string" do
    assert FieldGenerator.to_string({:field, "id", ":uuid", []}) ==
             "field :id, :uuid62"
  end

  test "it converts field tuple to non-null string" do
    assert FieldGenerator.to_string({:field, "id", ":uuid", [is_not_null: true]}) ==
             "field :id, non_null(:uuid62)"
  end

  test "it adds a description to a field" do
    assert FieldGenerator.to_string(
             {:field, "id", ":uuid", [is_not_null: true, description: "A unique identifier"]}
           ) ==
             "field :id, non_null(:uuid62), description: \"A unique identifier\""
  end

  test "it references another object" do
    assert FieldGenerator.to_string({:belongs_to, "workflows", "Workflow", []}) ==
             "field :workflow, :workflow do\nend"
  end

  test "it references another non_null object" do
    assert FieldGenerator.to_string({:belongs_to, "workflows", "Workflow", [is_not_null: true]}) ==
             "field :workflow, non_null(:workflow) do\nend"
  end

  # for now i'm assuming that a list always has non-null objects...
  test "it references a non_null connection" do
    assert FieldGenerator.to_string({:has_many, "workflows", "Workflow", []}) ==
             "field :workflows, non_null(:workflows_connection) do\n\nend"
  end

  test "it takes a resolve method" do
    assert FieldGenerator.to_string(
             {:has_many, "workflows", "Workflow",
              [is_not_null: true, resolve_method: {:dataloader, prefix: "Example"}]}
           ) ==
             """
             field :workflows, non_null(:workflows_connection) do
               resolve Connections.resolve(Repo.Workflow, :workflows)


             end
             """
             |> String.trim()
  end

  test "it takes a resolve method and a description" do
    assert FieldGenerator.to_string(
             {:has_many, "workflows", "Workflow",
              [
                description: "Here we gooo",
                is_not_null: true,
                resolve_method: {:dataloader, prefix: "Example"}
              ]}
           ) ==
             """
             field :workflows, non_null(:workflows_connection) do
               description "Here we gooo"

               resolve Connections.resolve(Repo.Workflow, :workflows)


             end
             """
             |> String.trim()
  end
end
