defmodule AbsintheGen.FieldGeneratorTest do
  use ExUnit.Case, async: true
  doctest AbsintheGen.FieldGenerator
  alias AbsintheGen.FieldGenerator

  test "it converts field tuple to string" do
    assert FieldGenerator.to_string({:field, "id", ":uuid", []}) ==
             "field :id, :uuid"
  end

  test "it converts field tuple to non-null string" do
    assert FieldGenerator.to_string({:field, "id", ":uuid", [is_not_null: true]}) ==
             "field :id, non_null(:uuid)"
  end

  test "it adds a description to a field" do
    assert FieldGenerator.to_string(
             {:field, "id", ":uuid", [is_not_null: true, description: "A unique identifier"]}
           ) ==
             "field :id, non_null(:uuid), description: \"A unique identifier\""
  end

  test "it references another object" do
    assert FieldGenerator.to_string({:belongs_to, "workflows", "Workflow", []}) ==
             "field :workflow, :workflow"
  end

  test "it references another non_null object" do
    assert FieldGenerator.to_string({:belongs_to, "workflows", "Workflow", [is_not_null: true]}) ==
             "field :workflow, non_null(:workflow)"
  end

  # for now i'm assuming that a list always has non-null objects...
  test "it references a list of non_null objects" do
    assert FieldGenerator.to_string({:has_many, "workflows", "Workflow", []}) ==
             "field :workflows, list_of(non_null(:workflow))"
  end

  test "it references a non_null list of non_null objects" do
    assert FieldGenerator.to_string({:has_many, "workflows", "Workflow", [is_not_null: true]}) ==
             "field :workflows, non_null(list_of(non_null(:workflow)))"
  end

  test "it takes a custom resolve method" do
    assert FieldGenerator.to_string(
             {:has_many, "workflows", "Workflow",
              [is_not_null: true, resolve_method: {:dataloader, prefix: "Example"}]}
           ) ==
             "field :workflows, non_null(list_of(non_null(:workflow))), resolve: dataloader(Example.Repo.Workflow)"
  end

  #
  # test "it sets foriegn key if it's not {singular_table}_id" do
  #   assert FieldGenerator.to_string({:belongs_to, "workflows", "Workflow", fk: "wf"}) ==
  #            "belongs_to :workflows, Workflow, foreign_key: :wf"
  # end
  #
  # test "it sets reference id if it's not id" do
  #   assert FieldGenerator.to_string({:belongs_to, "workflows", "Workflow", ref: "uuid"}) ==
  #            "belongs_to :workflows, Workflow, references: :uuid"
  # end
  #
  # test "it converts enum type to string" do
  #
  #   assert FieldGenerator.to_string({:field, "enum_field", "Ecto.Enum", values: ["foo", "bar"]}) ==
  #            "field :enum_field, Ecto.Enum, values: [:foo, :bar]"
  # end
  #
  # test "it converts has_many to string" do
  #   assert FieldGenerator.to_string({:has_many, "workflows", "Workflow", []}) ==
  #            "has_many :workflows, Workflow"
  # end
  #
  # test "it converts has_one to string" do
  #   assert FieldGenerator.to_string({:has_one, "workflow", "Workflow", []}) ==
  #            "has_one :workflow, Workflow"
  # end
  #
  # test "it converts many_to_many to string" do
  #   ref = {:many_to_many, "users", "User", join_through: "user_objects"}
  #
  #   assert FieldGenerator.to_string(ref) ==
  #            "many_to_many :users, User, join_through: \"user_objects\""
  # end
end
