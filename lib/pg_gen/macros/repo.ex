defmodule PgGen.Repo do
  defmacro schema(name, do: contents) do
    quote do
      @extensions [unquote(contents)] |> Enum.into(%{})

      def extensions do
        @extensions
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
