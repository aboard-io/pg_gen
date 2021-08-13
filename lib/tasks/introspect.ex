defmodule Mix.Tasks.Introspect do
  use Mix.Task

  @doc """
  Runs the database introspection and writes the raw results to a json file

  Usage:
  $ mix introspect db_name comma_separated_schema_list
  """
  def run([db_name, schemas]) do
    Mix.Task.run("app.start")

    result = Introspection.run(db_name, String.split(schemas, ","))
    File.write!("static/#{db_name}-introspection.json", Jason.encode!(result))
  end
end
