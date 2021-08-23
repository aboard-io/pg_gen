defmodule Mix.Tasks.PgGen.GenerateEcto do
  use Mix.Task
  alias EctoGen.{TableGenerator, ContextGenerator}

  @doc """
  Generate Ecto schemas
  """
  def run(args) do
    {options, _, _} =
      OptionParser.parse(args,
        strict: [schema: :string, database: :string],
        aliases: [d: :database, s: :schema]
      )

    defaults = PgGen.LocalConfig.get_db()

    Mix.Task.run("app.start")

    database_config =
      case options[:database] do
        nil ->
          defaults

        database ->
          Map.put(defaults, :database, database)
      end

    schema = options[:schema] || "public"
    IO.puts("TODO: Check if schema exists with Introspection.run_query")

    file_path = PgGen.LocalConfig.get_repo_path()

    if !File.exists?(file_path) do
      File.mkdir!(file_path)
    end

    %{tables: tables} =
      Introspection.run(database_config, String.split(schema, ","))
      |> Introspection.Model.from_introspection(schema)

    tables
    |> Enum.map(fn table -> TableGenerator.generate(table, schema) end)
    |> Enum.map(fn {name, file} -> File.write!("#{file_path}/#{name}.ex", file) end)

    # Generate the contexts access functions
    contexts_file_path = PgGen.LocalConfig.get_contexts_path()

    if !File.exists?(contexts_file_path) do
      File.mkdir!(contexts_file_path)
    end

    module_name = PgGen.LocalConfig.get_app_name()

    tables
    |> Enum.map(fn table -> ContextGenerator.generate(table, module_name) end)
    |> Enum.map(fn {name, file} -> File.write!("#{contexts_file_path}/#{name}.ex", file) end)

    ecto_json_type_path = "#{file_path}/ecto_json.ex"

    if !File.exists?(ecto_json_type_path) do
      File.write!(ecto_json_type_path, TableGenerator.ecto_json_type())
    end
  end

  def usage do
    IO.puts("""

      Usage:

        $ mix pg_gen.generate_ecto --database <db_name> --schema <schema_name>
    """)
  end
end
