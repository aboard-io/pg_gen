defmodule PgGen.Extend do
  defmacro extend(do: contents) do
    {:__block__, [], contents} = contents

    overrides_stringified = stringify_overrides(contents)

    stringified =
      contents
      |> Enum.filter(fn
        {:@, _, [{:override, _, _}]} -> false
        {_, _, _} -> true
      end)
      |> Enum.map(&Macro.to_string/1)
      # TODO this is pretty brittle, should prob change at some point. It's
      # cosmetic b/c Macro.to_string/1 will return defs like `def(foo(bar)) do`
      |> Enum.map(&String.replace(&1, "def(", "def "))
      |> Enum.map(&String.replace(&1, ")) do", ") do"))

    quote do
      Module.register_attribute(__MODULE__, :override, accumulate: true)

      @extensions unquote(stringified)
      @overrides unquote(overrides_stringified)
      def extensions do
        @extensions
      end

      def overrides do
        @overrides
      end
    end
  end

  def stringify_overrides(contents) do
      contents
      |> Enum.with_index(fn
        # @override :atom
        {_, _, [{:override, _, [fn_atom]}]}, _ ->
          to_string(fn_atom)

        # @override preceding a function call
        {_, _, [{:override, _, _}]}, index ->
          case Enum.at(contents, index + 1) do
            {:def, _, [{fn_atom, _, _} | _]} -> to_string(fn_atom)
            {:field, _, [fn_atom | _ ]} -> to_string(fn_atom)
          end

        _, _ ->
          ""
      end)
      |> Enum.filter(&(&1 != ""))
      |> Enum.uniq()
  end
end
