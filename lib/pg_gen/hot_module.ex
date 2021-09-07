defmodule PgGen.HotModule do
  def load(code_str, opts) when is_binary(code_str) do
    try do
      lines =
        code_str
        |> to_string
        |> String.trim()
        |> String.split("\n")

      code_body =
        lines
        |> tl
        |> Enum.reverse()
        |> tl
        |> Enum.reverse()
        |> Enum.join("\n")

      module_name = opts[:module_name] || get_module_name(hd(lines))
      IO.puts("Generating #{module_name}")

      contents = Code.string_to_quoted!(code_body)
      module = Module.concat(Elixir, module_name)

      Code.compiler_options(ignore_module_conflict: true)
      module_opts = Macro.Env.location(__ENV__)
      Module.create(module, contents, module_opts)

      # TODO Figure out how to write to file _and_ override w/module.create
      case opts[:file_path] do
        nil ->
          nil

        path ->
          # enxure path exists
          File.mkdir_p!(Path.dirname(path))
          # write files as exs to avoid compilation
          File.write!(path <> "s", code_str |> PgGen.Utils.format_code!())
      end

      module
    catch
      _ ->
        IO.puts(code_str)
        IO.puts("something wrong with that code string")
    end
  end

  def load(code_str, opts),
    do: code_str |> to_string |> load(opts)

  def get_module_name(str) do
    [_, module_name] =
      ~r/defmodule ([a-zA-Z0-9\.]+) do/
      |> Regex.run(String.trim(str))

    module_name
  end
end
