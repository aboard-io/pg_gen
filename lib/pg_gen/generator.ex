defmodule PgGen.Generator do
  @moduledoc """
  This module coordinates the generation of all the code from the
  introspectin schema.
  """
  alias EctoGen.{TableGenerator, ContextGenerator}
  alias AbsintheGen.{SchemaGenerator, EnumGenerator}

  def generate_ecto(tables, schema, app) do
    %{
      repos: generate_ecto_repos(tables, schema),
      contexts: generate_ecto_contexts(tables, app.camelized)
    }
  end

  def generate_ecto_repos(tables, schema) do
    tables
    |> Enum.map(fn table -> TableGenerator.generate(table, schema) end)
    |> Enum.into(%{})
  end

  def generate_ecto_contexts(tables, app_name) do
    tables
    |> Enum.map(fn table -> ContextGenerator.generate(table, app_name) end)
    |> Enum.into(%{})
  end

  def generate_absinthe(tables, enum_types, schema, app) do
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
      |> SchemaGenerator.inject_custom_queries(app.camelized <> "Web")
      |> Enum.join("\n\n")

    subscription_str = SchemaGenerator.custom_subscriptions(app.camelized <> "Web")

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

    graphql_schema =
      SchemaGenerator.types_template(
        def_strings,
        enum_defs,
        query_defs,
        dataloader_strings,
        mutation_strings,
        input_strings,
        scalar_and_enum_filters,
        connection_defs,
        subscription_str
      )

    resolvers =
      type_defs
      |> Enum.map(fn {name, _} ->
        SchemaGenerator.generate_resolver(
          name,
          Enum.find(filtered_tables, fn %{name: t_name} ->
            t_name == name
          end)
        )
      end)
      |> Enum.into(%{})

    %{resolvers: resolvers, graphql_schema: graphql_schema}
  end
end
