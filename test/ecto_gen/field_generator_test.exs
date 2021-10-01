defmodule EctoGen.FieldGeneratorTest do
  use ExUnit.Case, async: true
  doctest EctoGen.FieldGenerator
  alias EctoGen.FieldGenerator

  test "it converts field tuple to string" do
    assert FieldGenerator.to_string({:field, "name", "string", []}) ==
             "field :name, :string"
  end

  test "it converts belongs_to to string" do
    assert FieldGenerator.to_string({:belongs_to, "workflows", "Workflow", []}) ==
             "belongs_to :workflows, Workflow"
  end

  test "it sets foriegn key if it's not {singular_table}_id" do
    assert FieldGenerator.to_string({:belongs_to, "workflows", "Workflow", fk: "wf"}) ==
             "belongs_to :workflows, Workflow, foreign_key: :wf"
  end

  test "it sets reference id if it's not id" do
    assert FieldGenerator.to_string({:belongs_to, "workflows", "Workflow", ref: "uuid"}) ==
             "belongs_to :workflows, Workflow, references: :uuid"
  end

  test "it converts enum type to string" do
    assert FieldGenerator.to_string({:field, "enum_field", "Ecto.Enum", values: ["foo", "bar"]}) ==
             "field :enum_field, Ecto.Enum, values: [:foo, :bar]"
  end

  test "it converts has_many to string" do
    assert FieldGenerator.to_string({:has_many, "workflows", "Workflow", []}) ==
             "has_many :workflows, Workflow"
  end

  test "it converts has_one to string" do
    assert FieldGenerator.to_string({:has_one, "workflow", "Workflow", []}) ==
             "has_one :workflow, Workflow"
  end

  test "it converts many_to_many to string" do
    ref = {:many_to_many, "users", "User", join_through: "user_objects"}

    assert FieldGenerator.to_string(ref) ==
             "many_to_many :users, User, join_through: \"user_objects\""
  end

  test "it can have a foreign key as a primary key" do
    ref = {:belongs_to, "users", "User", pk: "user_id", type: "uuid"}

    assert FieldGenerator.to_string(ref) ==
             "belongs_to :users, User, primary_key: true, type: Ecto.UUID"
  end
end
