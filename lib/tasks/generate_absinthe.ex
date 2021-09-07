defmodule Mix.Tasks.PgGen.GenerateAbsinthe do
  use Mix.Task
  alias AbsintheGen.{SchemaGenerator, EnumGenerator}
  alias PgGen.Utils

  @doc """
  Generate Absinthe schema
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

    file_path = PgGen.LocalConfig.get_graphql_schema_path()
    types_path = file_path <> "/types"

    if !File.exists?(file_path) do
      File.mkdir!(file_path)
    end

    if !File.exists?(types_path) do
      File.mkdir!(types_path)
    end

    %{tables: tables, enum_types: enum_types} =
      Introspection.run(database_config, String.split(schema, ","))
      |> Introspection.Model.from_introspection(schema)

    # Filter out tables that aren't selectable/insertable/updatable/deletable
    filtered_tables =
      tables
      |> SchemaGenerator.filter_accessible()

    type_defs =
      filtered_tables
      |> Enum.map(fn table -> SchemaGenerator.generate_types(table, filtered_tables, schema) end)

    connection_defs =
      filtered_tables
      |> Enum.map(&SchemaGenerator.generate_connection/1)
      |> Enum.join("\n\n")

    def_strings =
      type_defs
      |> Enum.reduce("", fn {_name, def}, acc -> "#{acc}\n\n#{def}" end)

    enum_defs =
      enum_types
      |> Enum.map(&EnumGenerator.to_string/1)
      |> Enum.join("\n\n")

    enum_filters =
      enum_types
      |> Enum.map(fn %{name: name} -> SchemaGenerator.generate_input_filter(name) end)
      |> Enum.join("\n\n")

    scalar_filters = SchemaGenerator.generate_scalar_filters()
    scalar_and_enum_filters = scalar_filters <> "\n\n" <> enum_filters

    query_defs =
      filtered_tables
      |> Enum.map(&SchemaGenerator.generate_queries/1)
      |> Enum.join("\n\n")

    create_mutation_and_input_defs =
      filtered_tables
      |> Enum.map(&SchemaGenerator.generate_insertable/1)

    {create_mutations, create_inputs} =
      create_mutation_and_input_defs
      |> Enum.reduce({[], []}, fn [mutation, input], {mut, inp} ->
        {[mutation | mut], [input | inp]}
      end)

    update_mutation_and_input_defs =
      filtered_tables
      |> Enum.map(&SchemaGenerator.generate_updatable/1)

    {update_mutations, update_inputs} =
      update_mutation_and_input_defs
      |> Enum.reduce({[], []}, fn [mutation, input], {mut, inp} ->
        {[mutation | mut], [input | inp]}
      end)

    delete_mutations =
      filtered_tables
      |> Enum.map(&SchemaGenerator.generate_deletable/1)

    mutation_strings = Enum.join(create_mutations ++ update_mutations ++ delete_mutations, "\n\n")
    input_strings = Enum.join(create_inputs ++ update_inputs, "\n\n")

    dataloader_strings =
      filtered_tables
      |> SchemaGenerator.generate_dataloader()

    # |> Enum.map(fn {name, file} ->
    #   File.write!("#{types_path}/#{name |> Inflex.singularize()}.ex", file)
    # end)
    File.write!(
      "#{file_path}/types.ex",
      SchemaGenerator.types_template(
        def_strings,
        enum_defs,
        query_defs,
        dataloader_strings,
        mutation_strings,
        input_strings,
        scalar_and_enum_filters,
        connection_defs
      )
      |> Utils.format_code!()
    )

    resolver_path = PgGen.LocalConfig.get_graphql_resolver_path()

    if !File.exists?(resolver_path) do
      File.mkdir!(resolver_path)
    end

    type_defs
    |> Enum.map(fn {name, _} ->
      SchemaGenerator.generate_resolver(
        name,
        Enum.find(filtered_tables, fn %{name: t_name} ->
          t_name == name
        end)
      )
    end)
    |> Enum.map(fn {name, file} -> File.write!("#{resolver_path}/#{name}.ex", file) end)

    module_name = "#{PgGen.LocalConfig.get_app_name()}_web.Schema" |> Macro.camelize()

    File.write!(
      "#{resolver_path}/connections.ex",
      SchemaGenerator.connections_resolver_template(module_name |> String.split(".Schema") |> hd)
    )

    File.write!("#{types_path}/json.ex", SchemaGenerator.json_type(module_name))
    File.write!("#{types_path}/uuid4.ex", SchemaGenerator.uuid_type(module_name))
    File.write!("#{types_path}/cursor.ex", SchemaGenerator.cursor_type(module_name))
    File.write!("#{types_path}/uuid62.ex", SchemaGenerator.uuid62_type(module_name))
  end

  def schema_template(module_name, type_names) do
    imports =
      Enum.map(type_names, fn name ->
        "import_types #{module_name}.#{name |> Inflex.singularize() |> Macro.camelize()}Types"
      end)
      |> Enum.join("\n")

    """
    defmodule #{module_name} do
      use Absinthe.Schema
      #{imports}

      # query do
      #   @desc "Get a list of blog posts"
      #   field :posts, list_of(:post) do
      #     resolve &Blog.PostResolver.all/2
      #   end
      # end
    end
    """
  end
end
