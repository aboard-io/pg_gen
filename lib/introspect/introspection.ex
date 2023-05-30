defmodule Introspection do
  @moduledoc """
  This module ports most of the basic functionality from the
  introspect() function in graphile PgIntrospectionPlugin. See:

  https://github.com/graphile/graphile-engine/blob/v4/packages/graphile-build-pg/src/plugins/PgIntrospectionPlugin.js
  """

  def run(db_config, schemas) do
    introspection_results_by_kind = run_introspection(schemas, db_config)

    known_schemas =
      introspection_results_by_kind["namespace"]
      |> Enum.map(fn %{"name" => name} -> name end)

    missing_schemas =
      schemas
      |> Enum.filter(fn schema -> !Enum.member?(known_schemas, schema) end)

    if length(missing_schemas) > 0 do
      error_message = """
      You requested to use the following schemas:

      '#{schemas |> Enum.join(",")}',

      However we couldn't find some of those! Missing schemas are:

      '#{missing_schemas |> Enum.join(",")}'

      """

      IO.warn("⚠️ WARNING⚠️ : #{error_message}")
    else
      introspection_results_by_kind
    end
  end

  def run_introspection(schemas, db_options) do
    server_version_num = get_version_number(db_options)
    introspection_query = Introspection.Query.make_introspection_query(server_version_num)
    %{rows: rows} = run_query(introspection_query, db_options, [schemas, false])

    result =
      Stream.map(rows, fn [row] -> row end)
      |> Enum.reduce(
        %{
          "_pg_version" => server_version_num,
          "namespace" => [],
          "class" => [],
          "attribute" => [],
          "type" => [],
          "constraint" => [],
          "procedure" => [],
          "extension" => [],
          "index" => []
        },
        fn row, acc ->
          tags = parse_tags(row["description"])

          row =
            if is_map(tags) do
              row
              |> Map.put("comment", row["description"])
              |> Map.put("description", tags.text)
              |> Map.put("tags", tags.tags)
            else
              row
            end

          Map.put(acc, row["kind"], [row | acc[row["kind"]]])
        end
      )

    extension_configuration_class_ids =
      Enum.map(result["extension"], fn e -> e["configurationClassIds"] end)

    # TODO LINE 727
    # this is incredibly janky...
    classes =
      result["class"]
      |> Enum.map(fn class ->
        has_class_id =
          Enum.find(extension_configuration_class_ids, fn class_id ->
            class_id == class["id"]
          end)

        case has_class_id do
          result when is_nil(result) -> class
          _ -> Map.put(class, "isExtensionConfigurationTable", true)
        end
      end)

    Map.put(result, "class", classes)

    # NOTE: Not supporting enum tables b/c we don't currently use them
    # relevant code is here
    # https://github.com/graphile/graphile-engine/blob/v4/packages/graphile-build-pg/src/plugins/PgIntrospectionPlugin.js#L736
  end

  def get_version_number(db_options) do
    %{rows: [[version]]} = run_query("show server_version_num;", db_options)
    version |> String.to_integer()
  end

  def run_query(query, db_options, args \\ []) do
    {:ok, pid} =
      Postgrex.start_link(
        hostname: db_options.hostname,
        database: db_options.database,
        username: db_options.username,
        password: db_options.password
      )

    result = Postgrex.query!(pid, query, args)
    GenServer.stop(pid)
    result
  end

  @doc """
  Installs a schema that watches changes. See the full sql at `./watch_fixtures.sql`

  This schema is taken directly from Postgraphile
  """
  def install_watcher(db_options) do
    [
      "DROP SCHEMA IF EXISTS postgraphile_watch CASCADE;",
      "CREATE SCHEMA postgraphile_watch;",
      """
      CREATE FUNCTION postgraphile_watch.notify_watchers_ddl ()
        RETURNS event_trigger
        AS $$
      BEGIN
        PERFORM
          pg_notify('postgraphile_watch', json_build_object('type', 'ddl', 'payload', (
                SELECT
                  json_agg(json_build_object('schema', schema_name, 'command', command_tag))
                FROM pg_event_trigger_ddl_commands () AS x))::text);
      END;
      $$
      LANGUAGE plpgsql;
      """,
      """
      CREATE FUNCTION postgraphile_watch.notify_watchers_drop ()
        RETURNS event_trigger
        AS $$
      BEGIN
        PERFORM
          pg_notify('postgraphile_watch', json_build_object('type', 'drop', 'payload', (
                SELECT
                  json_agg(DISTINCT x.schema_name)
                FROM pg_event_trigger_dropped_objects () AS x))::text);
      END;
      $$
      LANGUAGE plpgsql;
      """,
      """
      CREATE EVENT TRIGGER postgraphile_watch_ddl ON ddl_command_end
      WHEN tag IN (
      -- Ref: https://www.postgresql.org/docs/10/static/event-trigger-matrix.html
      'ALTER AGGREGATE', 'ALTER DOMAIN', 'ALTER EXTENSION', 'ALTER FOREIGN TABLE', 'ALTER FUNCTION', 'ALTER POLICY',
      'ALTER SCHEMA', 'ALTER TABLE', 'ALTER TYPE', 'ALTER VIEW', 'COMMENT',
      'CREATE AGGREGATE', 'CREATE DOMAIN', 'CREATE EXTENSION', 'CREATE FOREIGN TABLE', 'CREATE FUNCTION',
      'CREATE INDEX', 'CREATE POLICY', 'CREATE RULE', 'CREATE SCHEMA', 'CREATE TABLE',
      'CREATE TABLE AS', 'CREATE VIEW', 'DROP AGGREGATE', 'DROP DOMAIN', 'DROP EXTENSION',
      'DROP FOREIGN TABLE', 'DROP FUNCTION', 'DROP INDEX', 'DROP OWNED', 'DROP POLICY',
      'DROP RULE', 'DROP SCHEMA', 'DROP TABLE', 'DROP TYPE', 'DROP VIEW',
      'GRANT', 'REVOKE', 'SELECT INTO')
      EXECUTE PROCEDURE postgraphile_watch.notify_watchers_ddl ();
      """,
      """
      CREATE EVENT TRIGGER postgraphile_watch_drop ON sql_drop
      EXECUTE PROCEDURE postgraphile_watch.notify_watchers_drop ();
      """
    ]
    |> Enum.map(fn sql -> run_query(sql, db_options) end)
  end

  def parse_tags(val) when is_nil(val), do: nil

  @doc ~S"""
  Parse tags from description strings

  ## Examples

    iex> Introspection.parse_tags("@filterable\n@sortable")
    %{tags: %{"filterable" => true, "sortable" => true}, text: ""}

  """
  def parse_tags(str) when is_binary(str) do
    str
    |> String.split(~r/\r?\n/)
    |> Enum.reduce(%{tags: %{}, text: ""}, fn curr, acc ->
      if acc.text != "" do
        Map.put(acc, :text, "#{acc.text}\n#{curr}")
      else
        match_re = ~r/^@[a-zA-Z][a-zA-Z0-9_]*($|\s)/

        case Regex.run(match_re, curr) do
          [match | _rest] ->
            key = String.slice(match, 1..-1)
            value = if match == curr, do: true, else: String.replace(curr, match, "")
            # const value = match[0] === curr ? true : curr.replace(match[0], "");

            new_value =
              case acc.tags[key] do
                old_val when is_list(old_val) -> [value | old_val]
                str when is_binary(str) -> [value, str]
                nil -> value
              end

            new_tag = %{key => new_value}

            Map.put(acc, :tags, Map.merge(new_tag, acc.tags))

          _ ->
            Map.put(acc, :text, curr)
        end
      end
    end)
  end
end
