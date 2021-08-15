defmodule Introspection do
  @moduledoc """
  This module ports most of the basic functionality from the
  introspect() function in graphile PgIntrospectionPlugin. See:

  https://github.com/graphile/graphile-engine/blob/v4/packages/graphile-build-pg/src/plugins/PgIntrospectionPlugin.js
  """

  def run(db_name, schemas) do
    introspection_results_by_kind = run_introspection(schemas, db_name)

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

  def run_introspection(schemas, db_name) do
    server_version_num = get_version_number()
    introspection_query = Introspection.Query.make_introspection_query(server_version_num)
    %{rows: rows} = run_query(introspection_query, db_name, [schemas, false])
    rows = Enum.map(rows, fn [row] -> row end)

    result =
      Enum.reduce(
        rows,
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

  def get_version_number do
    %{rows: [[version]]} = run_query("show server_version_num;", "")
    version |> String.to_integer()
  end

  def run_query(query, db_name, args \\ []) do
    {:ok, pid} = Postgrex.start_link(username: "ap", database: db_name)
    Postgrex.query!(pid, query, args)
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

  # remove below for now since i'm skipping enums... i don't believe we
  # have any enum constraints

  # def is_enum_constraint(class, constraint, is_enum_table) do
  #   if constraint["classId"] == class["id"] do
  #     true
  #     is_primary_key = constraint["type"] == "p"
  #     is_unique_constraint = constraint["type"] == "u"
  #
  #     if is_primary_key || is_unique_constraint do
  #       is_explicit_enum_constraint =
  #         constraint["tags"]["enum"] == true || is_binary(constraint["tags"]["enum"])
  #
  #       is_primary_key_of_enum_table_constraint = is_primary_key && is_enum_table
  #
  #       if is_explicit_enum_constraint || is_primary_key_of_enum_table_constraint do
  #         has_exactly_one_column = constraint["keyAttributeNums"] |> length == 1
  #
  #         if !has_exactly_one_column do
  #           raise """
  #           Enum table \"#{class["namespaceName"]}\"."\#{class["name"]}" enum constraint '#{constraint["name"]}' is composite; it should have exactly one column (found: #{constraint["keyAttributeNums"] |> length})
  #           """
  #         end
  #
  #         true
  #       end
  #     end
  #   else
  #     false
  #   end
  # end
end
