defmodule Mix.Tasks.GenerateAbsinthe do
  use Mix.Task

  @doc """
  Generate Ecto schemas and Absinthe schemas
  """
  def run([_url]) do
    # Mix.Task.run("app.start")

    # AbsintheGen.introspect_schema(url)
    # |> AbsintheGen.process_schema()

    # AbsintheGen.process_schema(File.read!("./static/introspection_query_result.json"))
  end
end
