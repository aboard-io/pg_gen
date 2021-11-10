defmodule PgGen.Repo do
  # Currently only supporting field overrides, not relationships like belongs_to, etc
  defmacro schema(name, do: contents) do
    {:__block__, [], contents} = contents

    overrides_stringified = PgGen.Extend.stringify_overrides(contents)

    stringified =
      contents
      |> Enum.filter(fn
        {:@, _, [{:override, _, _}]} -> false
        {_, _, _} -> true
      end)
      |> Enum.map(&Macro.to_string/1)
      # TODO this is pretty brittle, should prob change at some point. It's
      # cosmetic b/c Macro.to_string/1 will return defs like `def(foo(bar)) do`
      # |> Enum.map(&String.replace(&1, "def(", "def "))
      # |> Enum.map(&String.replace(&1, ")) do", ") do"))

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

  # defmacro resolve(contents), do: IO.inspect(contents, label: "resolve")
  defmacro field(field_name, type, opts \\ []) when is_atom(field_name) do
    quote do
      {:field, {:field, unquote(field_name), unquote(type), unquote(opts)}}
    end
  end
end
