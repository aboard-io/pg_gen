defmodule PgGen.Schema do
  def generate_strings(name, contents) do
    contents = get_quoted_contents(contents)

    quote do
      def unquote(:"#{name}")() do
        unquote(contents)
      end
    end
  end

  defmacro subscription(do: contents) do
    generate_strings(:subscriptions, contents)
  end

  defmacro query(do: contents) do
    generate_strings(:query_extensions, contents)
  end

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

  def get_quoted_contents(contents) do
    case contents do
      {:__block__, [], contents} -> contents
      contents -> [contents]
    end
  end
end

