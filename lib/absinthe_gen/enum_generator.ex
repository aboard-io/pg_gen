defmodule AbsintheGen.EnumGenerator do
  def to_string(%{name: name, enum_variants: enum_variants}) do
    """
    enum :#{name} do
      #{enum_variants |> Enum.map(fn value -> "value :#{value}" end) |> Enum.join("\n")}
    end
    """
  end
end
