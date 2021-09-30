defmodule PgGen.Generator do
  @moduledoc """
  This module coordinates the generation of all the code from the
  introspectin schema.
  """
  alias EctoGen.{TableGenerator, ContextGenerator}
  alias AbsintheGen.{SchemaGenerator, EnumGenerator, ResolverGenerator}

  def generate_ecto(tables, functions, schema, app) do
    %{
      repos: generate_ecto_repos(tables, functions, schema),
      contexts: generate_ecto_contexts(tables, functions, schema, app.camelized)
    }
  end

  def generate_ecto_repos(tables, functions, schema) do
    tables
    |> Enum.map(fn table -> TableGenerator.generate(table, functions.computed_columns_by_table[table.name], schema) end)
    |> Enum.into(%{})
  end

  def generate_ecto_contexts(tables, functions, schema, app_name) do
    contexts =
      tables
      |> Enum.map(fn table -> ContextGenerator.generate(table, functions, app_name, schema) end)
      |> Enum.filter(fn
        {_, nil} -> false
        {_, _} -> true
      end)
      |> Enum.into(%{})

    pg_functions_context =
      ContextGenerator.generate_custom_functions_returning_scalars_and_custom_records(
        functions.queries ++ functions.mutations,
        schema,
        app_name
      )

    Map.put(contexts, :pg_functions_context, pg_functions_context)
  end

  def generate_absinthe(tables, enum_types, functions, schema, app) do
    type_defs =
      tables
      |> Enum.map(fn table -> SchemaGenerator.generate_types(table, functions.computed_columns_by_table[table.name], tables, schema) end)

    connection_defs =
      tables
      |> Enum.map(&SchemaGenerator.generate_connection/1)
      |> Enum.join("\n\n")

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
      tables
      |> Enum.map(&SchemaGenerator.generate_queries/1)
      |> SchemaGenerator.inject_custom_queries(functions.queries, tables, app.camelized <> "Web")
      |> Enum.join("\n\n")

    # TODO should support mutations here, too
    custom_record_defs = SchemaGenerator.generate_custom_records(functions.queries)

    subscription_str = SchemaGenerator.custom_subscriptions(app.camelized <> "Web")

    {create_mutations, create_inputs, create_payloads} =
      tables
      |> Enum.map(&SchemaGenerator.generate_insertable/1)
      |> Enum.reduce({[], [], []}, fn {mutation, input, payload}, {mut, inp, pay} ->
        {[mutation | mut], [input | inp], [payload | pay]}
      end)

    {update_mutations, update_inputs, update_payloads} =
      tables
      |> Enum.map(&SchemaGenerator.generate_updatable/1)
      |> Enum.reduce({[], [], []}, fn {mutation, input, payload}, {mut, inp, pay} ->
        {[mutation | mut], [input | inp], [payload | pay]}
      end)

    {delete_mutations, _, delete_payloads} =
      tables
      |> Enum.map(&SchemaGenerator.generate_deletable/1)
      |> Enum.reduce({[], [], []}, fn {mutation, _, payload}, {mut, _, pay} ->
        {[mutation | mut], [], [payload | pay]}
      end)

    {function_mutations, function_mutation_payloads} =
      SchemaGenerator.generate_custom_function_mutations(functions.mutations, tables)

    mutation_strings =
      Enum.join(
        create_mutations ++ update_mutations ++ delete_mutations ++ function_mutations,
        "\n\n"
      )

    mutation_payloads =
      create_payloads ++ update_payloads ++ delete_payloads ++ function_mutation_payloads
      |> Enum.join("\n\n")

    input_strings = Enum.join(create_inputs ++ update_inputs, "\n\n")

    dataloader_strings =
      tables
      |> SchemaGenerator.generate_dataloader(functions)

    table_names =
      tables
      |> Enum.map(fn %{name: name} -> name end)

    graphql_schema =
      SchemaGenerator.schema_template(
        enum_defs,
        query_defs,
        custom_record_defs,
        dataloader_strings,
        mutation_strings,
        mutation_payloads,
        input_strings,
        scalar_and_enum_filters,
        connection_defs,
        subscription_str,
        table_names
      )

    resolvers =
      type_defs
      |> Enum.map(fn {name, _} ->
        ResolverGenerator.generate(
          name,
          Enum.find(tables, fn %{name: t_name} ->
            t_name == name
          end),
          functions.queries ++ functions.mutations
        )
      end)
      |> Enum.into(%{})

    pg_function_resolver =
      ResolverGenerator.generate_custom_functions_returning_scalars_and_records_to_string(
        functions.queries ++ functions.mutations,
        app.camelized
      )

    %{
      resolvers: resolvers,
      graphql_schema: graphql_schema,
      type_defs: type_defs,
      pg_function_resolver: pg_function_resolver
    }
  end
end
