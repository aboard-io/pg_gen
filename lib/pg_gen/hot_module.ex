defmodule PgGen.HotModule do
  require Logger
  require IEx
  alias PgGen.Utils

  def load(code_str, opts) when is_binary(code_str) do
    try do
      path = opts[:file_path]
      code_str = Utils.format_code!(code_str)
      is_stale = PgGen.CodeRegistry.is_stale(path, code_str)

      if is_stale do
        lines =
          code_str
          |> to_string
          |> String.trim()
          |> String.split("\n")

        # code_body =
        #   lines
        #   |> tl
        #   |> Enum.reverse()
        #   |> tl
        #   |> Enum.reverse()
        #   |> Enum.join("\n")

        module_name = opts[:module_name] || get_module_name(hd(lines))
        if is_nil(module_name) do
          IO.puts code_str
          IO.inspect opts
          Logger.warn "Something wrong with the above"
        end

        # contents = Code.string_to_quoted!(code_body)
        # module = Module.concat(Elixir, module_name)
        #
        # Code.compiler_options(ignore_module_conflict: true)
        # module_opts = Macro.Env.location(__ENV__)
        # Module.create(module, contents, module_opts)
        # ensure path exists
        File.mkdir_p!(Path.dirname(path))
        # write files as exs to avoid compilation
        File.write!(path, code_str)
        # Could potentially speed this up with Kernel.ParallelCompiler.compile/2
        # Code.require_file(path)
        # IEx.Helpers.recompile()
        # Code.compile_file(path)
        :ok
      end
    catch
      _ ->
        IO.puts(code_str)
        IO.puts("something wrong with that code string")
    end
  end

  def load(code_str, opts),
    do: code_str |> to_string |> load(opts)

  def recompile() do
    if Utils.does_module_exist(Phoenix.CodeReloader) do
      module_name = PgGen.LocalConfig.get_app_name() <> "Web.Endpoint"

      Module.concat(Elixir, module_name)
      |> Phoenix.CodeReloader.reload!()
    else
      IEx.Helpers.recompile()
    end
  end

  def get_module_name(str) do
      module_name_re = ~r/defmodule ([a-zA-Z0-9\.]+) do/
      case Regex.run(module_name_re, String.trim(str)) do
        [_, module_name] -> module_name
        _ -> 
          IO.puts "There was a problem with #{str}"
          nil
      end
  end
end
