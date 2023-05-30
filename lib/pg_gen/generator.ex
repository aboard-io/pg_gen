defmodule PgGen.Generator do
  @moduledoc """
  This module coordinates the generation of all the code from the
  introspectin schema.
  """
  alias EctoGen.{TableGenerator, ContextGenerator}
  alias AbsintheGen.{SchemaGenerator, EnumGenerator, ResolverGenerator}
  alias PgGen.Utils

  def generate_ecto(tables, functions, schema, app) do
    %{
      repos: generate_ecto_repos(tables, functions, schema),
      contexts: generate_ecto_contexts(tables, functions, schema, app.camelized)
    }
  end

  def generate_ecto_repos(tables, functions, schema) do
    tables
    |> Enum.map(fn table ->
      TableGenerator.generate(table, functions.computed_columns_by_table[table.name], schema)
    end)
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
    [excluded_create_fields] =
      Utils.maybe_apply(
        PgGen.LocalConfig.get_schema_extend_module(),
        "exclude_fields_from_create",
        [],
        [%{}]
      )

    [excluded_update_fields] =
      Utils.maybe_apply(
        PgGen.LocalConfig.get_schema_extend_module(),
        "exclude_fields_from_update",
        [],
        [%{}]
      )

    type_defs =
      tables
      |> Enum.map(fn table ->
        SchemaGenerator.generate_types(
          table,
          functions.computed_columns_by_table[table.name],
          tables,
          schema,
          %{
            excluded_input_fields: %{
              create: excluded_create_fields,
              update: excluded_update_fields
            }
          }
        )
      end)

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

    extend_module = Module.concat(Elixir, "#{app.camelized}Web.Schema.Extends")

    allow_list =
      Utils.maybe_apply(
        extend_module,
        "allow_list",
        [],
        []
      )
      |> (fn
            [] -> []
            list -> hd(list)
          end).()

    query_overrides =
      Utils.maybe_apply(
        extend_module,
        "query_extensions_overrides",
        [],
        []
      )

    mutation_overrides =
      Utils.maybe_apply(
        extend_module,
        "mutations_overrides",
        [],
        []
      )

    query_defs =
      tables
      |> Enum.map(&SchemaGenerator.generate_queries(&1, query_overrides, allow_list))
      |> SchemaGenerator.inject_custom_queries(
        functions.queries,
        tables,
        app.camelized <> "Web",
        allow_list
      )
      |> Enum.join("\n\n")

    # TODO should support mutations here, too
    custom_record_defs = SchemaGenerator.generate_custom_records(functions.queries)

    web_app_name = app.camelized <> "Web"
    subscription_str = SchemaGenerator.custom_subscriptions(web_app_name)

    create_mutations =
      tables
      |> Enum.map(&SchemaGenerator.generate_insertable(&1, mutation_overrides, allow_list))

    update_mutations =
      tables
      |> Enum.map(&SchemaGenerator.generate_updatable(&1, mutation_overrides, allow_list))

    delete_mutations =
      tables
      |> Enum.map(&SchemaGenerator.generate_deletable(&1, mutation_overrides, allow_list))

    {function_mutations, function_mutation_payloads} =
      SchemaGenerator.generate_custom_function_mutations(functions.mutations, tables, allow_list)

    mutation_strings =
      Enum.join(
        create_mutations ++
          update_mutations ++
          delete_mutations ++
          function_mutations ++
          SchemaGenerator.user_mutations(web_app_name),
        "\n\n"
      )

    mutation_payloads =
      function_mutation_payloads
      |> Enum.join("\n\n")

    [plugin_modules] =
      Utils.maybe_apply(
        extend_module,
        "plugins",
        [],
        [nil]
      )

    dataloader_strings =
      tables
      |> SchemaGenerator.generate_dataloader(functions, plugin_modules)

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
          functions
        )
      end)
      |> Enum.filter(fn {_, code} -> !is_nil(code) end)
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
