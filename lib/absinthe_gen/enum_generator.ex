defmodule AbsintheGen.EnumGenerator do
  def to_string(%{name: name, array_type: %{ enum_variants: enum_variants }}) do
    __MODULE__.to_string(%{name: String.replace(name, ~r/^_/, ""), enum_variants: enum_variants})
  end
  def to_string(%{name: name, enum_variants: enum_variants}) do
    """
    enum :#{name} do
      #{enum_variants |> Enum.map(fn value -> "value :#{value}" end) |> Enum.join("\n")}
    end
    """
  end
end
