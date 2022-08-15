defmodule PgGen.Extend do
  defmacro extend(do: contents) do
    {:__block__, [], contents} = contents

    overrides_stringified = stringify_overrides(contents)

    stringified =
      contents
      |> Enum.filter(fn
        {:@, _, [{:override, _, _}]} -> false
        {:@, _, [{:override, _, _, _}]} -> false
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

  defmacro object(name, do: contents) do
    {:__block__, [], contents} = contents
    generate_code(to_string(name) <> "_objects", contents)
  end

  defmacro input_object(name, do: contents) do
    {:__block__, [], contents} = contents
    generate_code(to_string(name) <> "_input_objects", contents)
  end

  defmacro enum(name, do: contents) do
    {:__block__, [], contents} = contents
    generate_code(to_string(name) <> "_enums", contents)
  end

  def generate_code(name, contents) when is_atom(name), do: generate_code(to_string(name), contents)
  def generate_code(name, contents) do
    overrides_stringified = stringify_overrides(contents)

    stringified =
      contents
      |> Enum.filter(fn
        {:@, _, [{:override, _, _}]} -> false
        {_, _, _} -> true
      end)
      |> Enum.map(&Macro.to_string/1)

    quote do
      def unquote(:"#{name}_extensions")() do
        unquote(stringified)
      end

      def unquote(:"#{name}_overrides")() do
        unquote(overrides_stringified)
      end
    end
  end

  def stringify_overrides(contents) do
      contents
      |> Enum.with_index(fn
        # @override :atom
        {_, _, [{:override, _, [fn_atom]}]}, _ ->
          to_string(fn_atom)
        {_, _, [{:override, _, [fn_atom], _}]}, _ ->
          to_string(fn_atom)

        # @override preceding a function call
        {_, _, [{:override, _, _}]}, index ->
          case Enum.at(contents, index + 1) do
            {:def, _, [{fn_atom, _, _} | _]} -> to_string(fn_atom)
            {:field, _, [fn_atom | _ ]} -> to_string(fn_atom)
            {:has_many, _, [fn_atom | _ ]} -> to_string(fn_atom)
            {:input_object, _, [fn_atom | _ ]} -> to_string(fn_atom)
            {:object, _, [fn_atom | _ ]} -> to_string(fn_atom)
          end

        _, _ ->
          ""
      end)
      |> Enum.filter(&(&1 != ""))
      |> Enum.uniq()
  end

  def stringify_omits(contents) do
      contents
      |> Enum.with_index(fn
        # @override :atom
        {_, _, [{:omit, _, [omissions]}]}, _ ->
          Enum.map(omissions, &to_string/1)

        _, _ ->
          ""
      end)
      |> Enum.filter(&(&1 != ""))
      |> List.flatten()
      |> Enum.uniq()
  end
end
