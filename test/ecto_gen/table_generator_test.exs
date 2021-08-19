defmodule EctoGen.TableGeneratorTest do
  use ExUnit.Case, async: true
  doctest EctoGen.TableGenerator
  # alias EctoGen.TableGenerator

  # @test_table Introspection.run("winslow", String.split("app_public", ","))
  #             |> Introspection.Model.from_introspection("app_public")
  #             |> Enum.at(9)
  #
  # test "it generates a table" do
  #   IO.inspect(@test_table)
  #   TableGenerator.generate(@test_table)
  #   assert true == true
  # end
end
