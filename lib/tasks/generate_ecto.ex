defmodule Mix.Tasks.PgGen.GenerateEcto do
  use Mix.Task
  alias EctoGen.TableGenerator

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

    # [:database, :schema]
    # |> Enum.map(fn key ->
    #   if is_nil(options[key]) do
    #     usage()
    #
    #     IO.puts("""
    #
    #       Missing options:
    #
    #         --#{key} is required
    #
    #     """)
    #
    #     exit(1)
    #   end
    # end)
    #
    # [database: db, schema: schema] = options

    file_path = PgGen.LocalConfig.get_repo_path()

    if !File.exists?(file_path) do
      File.mkdir!(file_path)
    end

    Introspection.run(database_config, String.split(schema, ","))
    |> Introspection.Model.from_introspection(schema)
    |> Enum.map(fn table -> TableGenerator.generate(table, schema) end)
    |> Enum.map(fn {name, file} -> File.write!("#{file_path}/#{name}.ex", file) end)

    ecto_json_type_path = "#{file_path}/ecto_json.ex"

    if !File.exists?(ecto_json_type_path) do
      File.write!(ecto_json_type_path, TableGenerator.ecto_json_type())
    end

    # |> IO.inspect()

    # AbsintheGen.introspect_schema(url)
    # |> AbsintheGen.process_schema()

    # AbsintheGen.process_schema(File.read!("./static/introspection_query_result.json"))
  end

  def usage do
    IO.puts("""

      Usage:

        $ mix pg_gen.generate_ecto --database <db_name> --schema <schema_name>
    """)
  end
end
