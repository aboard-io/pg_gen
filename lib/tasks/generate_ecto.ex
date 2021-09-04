defmodule Mix.Tasks.PgGen.GenerateEcto do
  use Mix.Task
  alias EctoGen.{TableGenerator, ContextGenerator}
  alias PgGen.Utils

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

    filter_path = "#{contexts_file_path}/filter.ex"

    if !File.exists?(filter_path) do
      File.write!(filter_path, dynamic_query_template(Macro.camelize(module_name)))
    end
  end

  def usage do
    IO.puts("""

      Usage:

        $ mix pg_gen.generate_ecto --database <db_name> --schema <schema_name>
    """)
  end

  def dynamic_query_template(module_name) do
    """
      defmodule #{module_name}.Repo.Filter do
        @moduledoc \"\"\"
        Basic concept for dynamic querying from:

        https://github.com/pentacent/keila/blob/2af0a2f91b0916f7d757f3c24d2955d9550cc6b3/lib/keila/contacts/query.ex

        Module for dynamic querying.
        The `apply/2` function takes two arguments: a query (`Ecto.Query.t()`) and options
        for filtering and sorting the resulting data set.
        ## Filtering
        Using the `:filter` option, you can supply a MongoDB-style query map.
        ### Supported operators:
        - after: Cursor
        - before: Cursor
        - condition
        - filter:
          - equalTo
          - greaterThan
          - greaterThanOrEqualTo
          - isNull
          - lessThan
          - lessThanOrEqualTo
          - notEqualTo
        - first: Int
        - last: Int
        - orderBy
        \"\"\"

        import Ecto.Query, warn: false

        @type opts :: map()

        @spec apply(Ecto.Query.t(), opts) :: Ecto.Query.t()
        def apply(query, opts) do
          query
          |> maybe_condition(opts)
          |> maybe_filter(opts)
          |> maybe_paginate(opts)
          |> maybe_sort(opts)
          |> maybe_limit(opts)
        end

        defp maybe_condition(query, opts) do
          case Map.get(opts, :condition) do
            input when is_map(input) -> condition(query, input)
            _ -> query
          end
        end

        defp condition(query, input), do: query |> where(^Enum.into(input, Keyword.new()))

        defp maybe_filter(query, opts) do
          case Map.get(opts, :filter) do
            input when is_map(input) -> filter(query, input)
            _ -> query
          end
        end

        defp filter(query, input) do
          from(q in query, where: ^build_and(input))
        end

        defp build_and(input) do
          Enum.reduce(input, nil, fn {k, v}, conditions ->
            condition = build_condition(k, v)

            if conditions == nil,
              do: condition,
              else: dynamic([c], ^condition and ^conditions)
          end)
        end

        defp build_or(input) do
          Enum.reduce(input, nil, fn input, conditions ->
            condition = build_and(input)

            if conditions == nil,
              do: condition,
              else: dynamic([c], ^condition or ^conditions)
          end)
        end

        defp build_condition(field, input) when is_binary(field),
          do: build_condition(String.to_existing_atom(field), input)

        defp build_condition(field, %{greater_than: value}),
          do: dynamic([c], field(c, ^field) > ^value)

        defp build_condition(field, %{greater_than_or_equal_to: value}),
          do: dynamic([c], field(c, ^field) >= ^value)

        defp build_condition(field, %{less_than: value}),
          do: dynamic([c], field(c, ^field) < ^value)

        defp build_condition(field, %{less_than_or_equal_to: value}),
          do: dynamic([c], field(c, ^field) <= ^value)

        defp build_condition(field, %{equal_to: value}),
          do: dynamic([c], field(c, ^field) == ^value)

        defp build_condition(field, %{not_equal_to: value}),
          do: dynamic([c], field(c, ^field) != ^value)

        defp build_condition(field, %{is_null: true}),
          do: dynamic([c], is_nil(field(c, ^field)))

        defp build_condition(field, %{is_null: false}),
          do: dynamic([c], not is_nil(field(c, ^field)))

        defp build_condition(field, value) when is_binary(value) or is_number(value),
          do: dynamic([c], field(c, ^field) == ^value)

        defp build_condition(field, %{"$in" => value}) when is_list(value),
          do: dynamic([c], field(c, ^field) in ^value)

        defp build_condition("$or", input),
          do: build_or(input)

        defp build_condition("$not", input),
          do: dynamic(not (^build_and(input)))

        defp build_condition(field, value),
          do: raise(~s{Unsupported filter "\#{field}": "\#{inspect(value)}"})

        defp maybe_sort(query, opts) do
          case Map.get(opts, :order_by) do
            nil -> query
            order_opts -> query |> order_by(^sort_with_limit(order_opts, opts))
          end
        end

        def sort_with_limit(order_opts, opts) do
          case Map.get(opts, :last) do
            nil ->
              order_opts

            # If we want the get the last N rows, flip the order in the query,
            # then reverse results later (in the resolver?)
            num when is_integer(num) ->
              case order_opts do
                [{:asc, column} | rest] -> [{:desc, column} | rest]
                [{:desc, column} | rest] -> [{:asc, column} | rest]
                {:asc, column} -> {:desc, column}
                {:desc, column} -> {:asc, column}
              end
          end
        end

        defp maybe_limit(query, opts) do
          case Map.get(opts, :first) do
            nil ->
              case Map.get(opts, :last) do
                nil -> query
                num -> query |> limit(^num)
              end

            num ->
              query |> limit(^num)
          end
        end

        defp maybe_paginate(query, opts) do
          case Map.get(opts, :after) do
            nil ->
              case Map.get(opts, :before) do
                nil ->
                  query

                {{_dir, field} = order_by, value} ->
                  query
                  |> where(^build_condition(field, %{less_than: value}))
                  |> order_by(^sort_with_limit(order_by, opts))
              end

            {{_dir, field} = order_by, value} ->
              query
              |> where(^build_condition(field, %{greater_than: value}))
              |> order_by(^sort_with_limit(order_by, opts))
          end
        end
      end
    """
    |> Utils.format_code!()
  end
end
