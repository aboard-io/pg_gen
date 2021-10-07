defmodule PgGen.Schema do
  def generate_strings(name, contents) do
    contents =
      contents
      |> get_quoted_contents()

    overrides_stringified =
      contents
      |> PgGen.Extend.stringify_overrides()
      |> Enum.concat(PgGen.Extend.stringify_omits(contents))
      |> Enum.uniq()


    contents =
      contents
      |> Enum.filter(fn
        {:@, _, [{:override, _, _}]} -> false
        {:@, _, [{:omit, _, _}]} -> false
        _ -> true
      end)

    quote do
      def unquote(:"#{name}")() do
        unquote(contents)
      end

      def unquote(:"#{name}_overrides")() do
        unquote(overrides_stringified)
      end
    end
  end

  defmacro subscription(do: contents) do
    generate_strings(:subscriptions, contents)
  end

  defmacro query(do: contents) do
    generate_strings(:query_extensions, contents)
  end

  defmacro mutation(do: contents) do
    generate_strings(:mutations, contents)
  end

  defmacro field(name, type, opts \\ [])

  defmacro field(name, type, do: do_block) do
    stringified = Macro.to_string(do_block)

    quote do
      """
      field :#{unquote(name)}, :#{unquote(type)} do
        #{unquote(stringified)}
      end
      """
    end
  end

  defmacro field(name, type, opts) do
    stringified = Macro.to_string(opts)

    quote do
      """
      field :#{unquote(name)}, :#{unquote(type)}, #{unquote(stringified)}
      """
    end
  end

  defmacro resolve(contents) do
    stringified = Macro.to_string(contents)

    quote do
      """
        resolve #{unquote(stringified)}
      """
    end
  end

  defmacro import_types(contents) do
    generate_strings(:imports, contents)
  end

  def get_quoted_contents(contents) do
    case contents do
      {:__block__, [], contents} -> contents
      contents -> [contents]
    end
  end
end
