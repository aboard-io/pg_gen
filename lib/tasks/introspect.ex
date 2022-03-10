defmodule Mix.Tasks.Introspect do
  use Mix.Task

  @doc """
  Runs the database introspection and writes the raw results to a json file

  Usage:
  $ mix introspect db_name comma_separated_schema_list
  """
  def run([db_name, schema]) do
    Mix.Task.run("app.start")

    database_config = PgGen.LocalConfig.get_authenticator_db() || PgGen.LocalConfig.get_db()

    result = Introspection.run(database_config, String.split(schema, ","))
    File.write!("./#{db_name}-introspection.json", Jason.encode!(result))
  end
end
