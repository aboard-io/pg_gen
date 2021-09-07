defmodule PgGen.Extend do
  defmacro extend(do: contents) do
    {:__block__, [], contents} = contents
    stringified = Enum.map(contents, &Macro.to_string/1)

    quote do
      @extensions unquote(stringified)
      def extensions do
        @extensions
      end
    end
  end
end
