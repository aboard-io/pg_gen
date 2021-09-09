defmodule PgGen.FilePaths do
  alias PgGen.LocalConfig

  def get_paths(app_name) do
    module_name = app_name || (LocalConfig.get_app_name() |> Macro.camelize())
    module_name_web = module_name <> "Web"

    %{
      contexts: "lib/#{module_name}/contexts",
      repo: "lib/#{module_name}/repo",
      resolvers: "lib/#{module_name_web}/schema/resolvers",
      types: "lib/#{module_name_web}/schema/types",
      schema: "lib/#{module_name_web}/schema",
    }
  end
end
