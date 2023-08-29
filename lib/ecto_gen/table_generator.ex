defmodule EctoGen.TableGenerator do
  alias PgGen.{Utils, Builder}
  alias EctoGen.FieldGenerator

  def generate(%{name: name, attributes: attributes} = table, computed_fields, schema) do
    built_attributes =
      attributes
      |> Enum.map(&Builder.build/1)
      |> Utils.deduplicate_associations()

    unique_constraints =
      attributes
      |> Stream.map(& &1.constraints)
      |> Stream.flat_map(& &1)
      |> Stream.filter(&(&1.type == :uniq))
      |> Stream.uniq_by(& &1.name)
      |> Stream.map(fn uniq_constraint ->
        named_fields =
          uniq_constraint.with
          |> Enum.map(fn field_index ->
            ":#{Enum.at(attributes, field_index - 1).name}"
          end)

        Map.put(uniq_constraint, :with, named_fields)
      end)
      |> Enum.to_list()

    required_fields =
      built_attributes
      |> Stream.filter(&is_required/1)
      |> Enum.map(fn
        {:field, name, _, _} ->
          ":#{name}"

        {:belongs_to, name, _, opts} ->
          ":" <> Keyword.get(opts, :fk, "#{name}_id")
      end)

    foreign_key_constraints =
      built_attributes
      |> Stream.filter(fn
        {:belongs_to, _, _, _} -> true
        {_, _, _, _} -> false
      end)
      |> Enum.map(fn
        {_, name, _, opts} ->
          ":" <> Keyword.get(opts, :fk, "#{name}_id")
      end)

    all_fields =
      built_attributes
      |> Enum.map(fn {field_or_assoc, name, _, options} ->
        case field_or_assoc do
          :field -> ":#{name}"
          :belongs_to -> ":#{options[:fk] || name <> "_id"}"
          type -> raise "Ooops didn't handle this attribute type# #{type}"
        end
      end)

    app_module_name = PgGen.LocalConfig.get_app_name()
    module_name = "#{app_module_name}.Repo.#{Macro.camelize(Inflex.singularize(name))}"
    extension_module_name = "#{module_name}Extend"
    overrides = get_overrides(extension_module_name)
    extensions = get_extensions(extension_module_name)

    attribute_string =
      built_attributes
      |> Stream.filter(fn
        {:field, name, _, _} -> !(name in overrides)
        _ -> true
      end)
      |> Stream.map(&FieldGenerator.to_string/1)
      |> Enum.sort()
      |> Enum.reverse()
      |> Stream.concat(extensions)
      |> Enum.join("\n")

    computed_fields_string =
      computed_fields
      |> Stream.map(&Builder.build/1)
      |> Stream.filter(&(!is_nil(&1)))
      |> Stream.map(&(FieldGenerator.to_string(&1) <> ", virtual: true"))
      |> Enum.join("\n")

    computed_fields_fun_str =
      computed_fields
      |> Stream.map(&":#{&1.simplified_name}")
      |> Enum.join(", ")

    computed_fields_with_types_fun_str =
      computed_fields
      |> Stream.map(&"{:#{&1.simplified_name}, #{process_return_type(&1)}}")
      |> Enum.join(", ")

    return_types =
      computed_fields
      |> Stream.map(&process_return_type/1)
      |> Enum.filter(fn
        ":" <> _ -> false
        _ -> true
      end)

    # if a table has no default primary key
    {_, _, primary_key_type, _} =
      Enum.find(built_attributes, fn
        {:field, "id", _type, _options} -> true
        _ -> false
      end) || {nil, nil, nil, nil}

    primary_key_type =
      if primary_key_type do
        FieldGenerator.process_type_str(primary_key_type)
      else
        nil
      end

    belongs_to_aliases =
      built_attributes
      |> Stream.filter(fn {type, _, _, _} -> type == :belongs_to end)
      |> Enum.map(fn {_, _, alias, _} -> alias end)

    {references, aliases} =
      case Map.get(table, :external_references) do
        nil ->
          {"", []}

        references ->
          built_references =
            references
            |> Enum.map(&Builder.build/1)
            |> Utils.deduplicate_references()

          aliases =
            built_references
            |> Stream.map(fn {_, _, alias, _} -> alias end)
            |> Enum.uniq()

          references =
            built_references
            |> Stream.filter(fn
              {:has_many, name, _, _} -> !(name in overrides)
              {:many_to_many, name, _, _} -> !(name in overrides)
              _ -> true
            end)
            |> Stream.map(&FieldGenerator.to_string/1)
            |> Enum.sort()
            |> Enum.join("\n")

          {references, aliases}
      end

    table_name = Inflex.singularize(name) |> Macro.camelize()

    aliases =
      (belongs_to_aliases ++ aliases ++ return_types)
      |> Stream.uniq()
      |> Enum.join(", ")

    app_name = PgGen.LocalConfig.get_app_name() |> Macro.camelize()
    singular_lowercase = Inflex.singularize(name)

    {name,
     Utils.format_code!("""
     defmodule #{app_name}.Repo.#{table_name} do
       #{if !is_nil(table.description) do
       """
       @moduledoc \"\"\"
       #{table.description}
       \"\"\"
       """
     end}
       use Ecto.Schema
       import Ecto.Changeset

       @pg_columns [
         #{Stream.map(attributes, &":#{&1.name}") |> Enum.join(", ")}
       ]

       @derive {Jason.Encoder, only: @pg_columns}

       alias #{app_name}.Repo
       alias #{app_name}.Repo.{#{aliases}}

       @schema_prefix "#{schema}"
       #{if primary_key_type, do: "@primary_key {:id, #{primary_key_type}, autogenerate: false}", else: "@primary_key false"}
       #{if primary_key_type && primary_key_type != ":integer", do: "@foreign_key_type :binary_id", else: ""}


       schema "#{name}" do
         #{attribute_string}

         #{if String.trim(computed_fields_string) != "" do
       """
       # Computed fields
       #{computed_fields_string}
       """
     end}

         #{if String.trim(references) != "" do
       """
       # Relations
       #{references}
       """
     end}

          # Changeset
            def changeset(#{singular_lowercase}, attrs) do
              fields = [#{Enum.join(all_fields, ", ")}]
              required_fields = [#{Enum.join(required_fields, ", ")}]

              #{singular_lowercase}
              |> cast(attrs, fields)
              |> validate_required(required_fields)
              #{Stream.map(foreign_key_constraints, fn field_name -> "|> foreign_key_constraint(#{field_name})" end) |> Enum.join("\n")}
              #{Stream.map(unique_constraints, fn %{with: with, name: name} -> "|> unique_constraint([#{Enum.join(with, ", ")}], name: \"#{name}\")" end) |> Enum.join("\n")}
            end

          # Computed fields helpers
          @doc \"\"\"
          A helper function that returns all fields in a schema, in the order Postgres
          expects them as columns.
          \"\"\"
          def pg_columns() do
            @pg_columns
          end


          def to_pg_row(%{} = map) do
          [#{Stream.map(attributes, &"{:#{&1.name}, :#{if &1.type.enum_variants == nil do
       &1.type.name
     else
       "enum"
     end}}") |> Enum.join(", ")}]
            |> Repo.Helper.cast_values_for_pg(map)
          end
          def computed_fields do
            [#{computed_fields_fun_str}]
          end

          def computed_fields_with_types([]) do
            [#{computed_fields_with_types_fun_str}]
          end

          def computed_fields_with_types(computed_fields) do
            computed_fields_with_types([])
            |> Enum.filter(fn {name, _} -> name in computed_fields end)
          end

       end
     end
     """)}
  end

  def ecto_json_type do
    """
    defmodule EctoJSON do
      @moduledoc \"\"\"
      EctoJSON type helps resolve the ambiguity of the jsonb Postgres type. Since
      jsonb can be either a JSON object or a JSON array, and since Ecto requires you
      to define the type as either :map or {:array, :map} in the field definition,
      this little hack type allows us to load both.
      \"\"\"
      use Ecto.Type
      def type, do: {:array, :map}

      # Provide custom casting rules.
      # We wrap all incoming JSON in an array when we store it in our cast
      # function; we unwrap it here. This allows objects or arrays to be retrieved,
      # since ecto requires us to make it one or the other.
      def cast(json) when is_binary(json) do
        decoded = Jason.decode!(json)

        {:ok, [decoded]}
      end

      def cast(data) when is_map(data) or is_list(data) do
        {:ok, [data]}
      end

      # Everything else is a failure though
      def cast(_), do: :error

      # In our load function, we expect our data to be wrapped in a list. We unwrapped_data
      # that and return the data inside, which may be a list or a map
      def load(data) when is_list(data) do
        if length(data) == 1 do
          [unwrapped_data] = data
          if is_list(unwrapped_data) do
            {:ok, data}
          else
            {:ok, unwrapped_data}
          end
        else
          {:ok, data}
        end
      end

      def load(data) when is_map(data) do
        {:ok, data}
      end

      def load(data) when is_binary(data) do
        data
        |> Jason.decode!()
        |> load()
      end

      def dump(data) when is_list(data) or is_map(data), do: {:ok, Jason.encode!(data)}
      def dump(_), do: :error
    end
    """
  end

  def dynamic_query_template(module_name) do
    app_name = PgGen.LocalConfig.get_app_name() |> Macro.camelize()
    extend_module = Module.concat(Elixir, "#{app_name}Web.Schema.Extends")

    [non_unique_sort_fields] =
      Utils.maybe_apply(
        extend_module,
        "non_unique_sort_fields",
        [],
        []
      )

    non_unique_sort_fields_query_conditions =
      non_unique_sort_fields
      |> Enum.map(fn field ->
        """
          defp get_pagination_query_condition(:desc, value, :#{field}) do
            %{less_than_or_equal_to: value}
          end

          defp get_pagination_query_condition(:asc, value, :#{field}) do
            %{greater_than_or_equal_to: value}
          end
        """
      end)

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

        defp condition(query, input) do
          where_condition =
            if is_nil(input |> Map.values() |> List.first()) do
              field = Map.keys(input) |> List.first()
              dynamic([c], is_nil(field(c, ^field)))
            else
              Enum.into(input, Keyword.new())
            end

          query |> where(^where_condition)
        end

        defp maybe_filter(query, opts) do
          case Map.get(opts, :filter) do
            input when is_map(input) -> filter(query, input)
            _ -> query
          end
        end

        defp filter(query, input) do
          source =
            case query do
              source when is_atom(source) ->
                source

              query ->
                {_, source} = query.from.source
                source
            end

          {filter_input, assoc_filter_input} =
            Enum.reduce(input, {%{}, %{}}, fn {k, v}, {filter_input, assoc_filter_input} ->
              if k in source.__schema__(:associations) do
                {filter_input, Map.put(assoc_filter_input, k, v)}
              else
                {Map.put(filter_input, k, v), assoc_filter_input}
              end
            end)

          query =
            if Map.keys(filter_input) |> length() > 0,
              do: from(q in query, where: ^build_and(filter_input)),
              else: query

          assoc_filter_input =
            assoc_filter_input
            |> Enum.map(fn {k, v} ->
              {k, convert_params_to_shorts(v)}
            end)
            |> Enum.into(%{})

          EctoShorts.CommonFilters.convert_params_to_filter(query, assoc_filter_input)
        end

        defp convert_params_to_shorts(input) do
          Enum.map(input, fn {k, v} ->
            {k, convert_param(v)}
          end)
          |> Enum.into(%{})
        end

        defp convert_param(%{equal_to: value}) do
          value
        end

        defp convert_param(%{not_equal_to: _value}) do
          # %{!=: value}
          raise "`not_equal_to` is not supported on association filters"
        end

        defp convert_param(%{greater_than: value}) do
          %{>: value}
        end

        defp convert_param(%{greater_than_or_equal_to: value}) do
          %{>=: value}
        end

        defp convert_param(%{less_than: value}) do
          %{<: value}
        end

        defp convert_param(%{less_than_or_equal_to: value}) do
          %{<=: value}
        end

        defp convert_param(%{is_null: true}) do
          %{==: nil}
        end

        defp convert_param(%{is_null: false}) do
          %{!=: nil}
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
            # then reverse results later (in AboardExWeb.Resolvers.Connections)
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
                num -> query |> limit(^(num + 1))
              end

            num ->
              query |> limit(^(num + 1))
          end
        end

        defp maybe_paginate(query, opts) do
          case Map.get(opts, :after) do
            nil ->
              case Map.get(opts, :before) do
                nil ->
                  query

                # We're paginating via before
                order_by_args when is_list(order_by_args) ->
                  Enum.reduce(order_by_args, query, fn {{_dir, field} = order_by, value}, query_acc ->
                    {final_dir, _column} = order_by = sort_with_limit(order_by, opts)

                    query_acc
                    |> where(
                      ^build_condition(field, get_pagination_query_condition(final_dir, value, field))
                    )
                  end)

                {{_dir, field} = order_by, value} ->
                  {final_dir, _column} = sort_with_limit(order_by, opts)

                  query
                  |> where(
                    ^build_condition(field, get_pagination_query_condition(final_dir, value, field))
                  )
              end

            # We're paginating via after
            order_by_args when is_list(order_by_args) ->
              Enum.reduce(order_by_args, query, fn {{dir, field}, value}, query_acc ->
                query_acc
                |> where(^build_condition(field, get_pagination_query_condition(dir, value, field)))

                # |> order_by(^sort_with_limit(order_by, opts))
              end)

            {{dir, field}, value} ->
              query
              |> where(^build_condition(field, get_pagination_query_condition(dir, value, field)))

              # |> order_by(^sort_with_limit(order_by, opts))
          end
        end

        #{non_unique_sort_fields_query_conditions |> Enum.join("\n")}

        defp get_pagination_query_condition(:desc, value, _column) do
          %{less_than: value}
        end

        defp get_pagination_query_condition(:asc, value, _column) do
          %{greater_than: value}
        end
      end
    """
    |> Utils.format_code!()
  end

  def is_required({_, _, _, opts}) do
    !Keyword.get(opts, :has_default) && Keyword.get(opts, :is_not_null)
  end

  defp process_return_type(%{return_type: %{type: %{name: name, category: "C"}}}) do
    name
    |> Inflex.singularize()
    |> Macro.camelize()
  end

  defp process_return_type(%{return_type: %{type: %{name: name}}}) do
    ":#{name}"
  end

  def get_overrides(module_name) do
    extensions_module = Module.concat(Elixir, module_name)
    Utils.maybe_apply(extensions_module, :overrides, [], [])
  end

  def get_extensions(module_name) do
    extensions_module = Module.concat(Elixir, module_name)
    Utils.maybe_apply(extensions_module, :extensions, [], [])
  end

  def repo_helper(module_name) do
    """
    defmodule #{module_name}.Repo.Helper do
      def cast_values_for_pg(values, map) do
        values
        |> Enum.map(fn
          {field, :uuid} -> case Map.get(map, field) do
            nil -> nil
            id -> Ecto.UUID.dump!(id)
          end
          {field, :enum} -> case Map.get(map, field) do
            nil -> nil
            atom when is_atom(atom) -> to_string(atom)
          end
          {field, _} -> Map.get(map, field)
        end)
        |> List.to_tuple()
      end
    end
    """
  end
end
