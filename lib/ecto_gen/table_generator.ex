defmodule EctoGen.TableGenerator do
  alias PgGen.{Utils, Builder}
  alias EctoGen.FieldGenerator

  def generate(%{name: name, attributes: attributes} = table, computed_fields, schema) do
    built_attributes =
      attributes
      |> Enum.map(&Builder.build/1)
      |> Utils.deduplicate_associations()

    required_fields =
      built_attributes
      |> Enum.filter(&is_required/1)
      |> Enum.map(fn
        {:field, name, _, _} ->
          ":#{name}"

        {:belongs_to, name, _, opts} ->
          ":" <> Keyword.get(opts, :fk, "#{name}_id")
      end)

    foreign_key_constraints =
      built_attributes
      |> Enum.filter(fn
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

    app_module_name = PgGen.LocalConfig.get_app_name
    module_name = "#{app_module_name}.Repo.#{Macro.camelize(Inflex.singularize(name))}"
    extension_module_name = "#{module_name}Extend"
    overrides = get_overrides(extension_module_name)
    extensions = get_extensions(extension_module_name)

    attribute_string =
      built_attributes
      |> Enum.filter(fn 
        {:field, name, _, _} -> !(name in overrides)
        _ -> true
      end)
      |> Enum.map(&FieldGenerator.to_string/1)
      |> Enum.sort()
      |> Enum.reverse()
      |> Enum.concat(extensions)
      |> Enum.join("\n")

    computed_fields_string =
      computed_fields
      |> Enum.map(&Builder.build/1)
      |> Enum.filter(&(!is_nil(&1)))
      |> Enum.map(&(FieldGenerator.to_string(&1) <> ", virtual: true"))
      |> Enum.join("\n")

    computed_fields_fun_str =
      computed_fields
      |> Enum.map(&":#{&1.simplified_name}")
      |> Enum.join(", ")

    computed_fields_with_types_fun_str =
      computed_fields
      |> Enum.map(&"{:#{&1.simplified_name}, #{process_return_type(&1)}}")
      |> Enum.join(", ")

    return_types =
      computed_fields
      |> Enum.map(&process_return_type/1)
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
      |> Enum.filter(fn {type, _, _, _} -> type == :belongs_to end)
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
            |> Enum.map(fn {_, _, alias, _} -> alias end)
            |> Enum.uniq()

          references =
            built_references
            |> Enum.map(&FieldGenerator.to_string/1)
            |> Enum.sort()
            |> Enum.join("\n")

          {references, aliases}
      end

    table_name = Inflex.singularize(name) |> Macro.camelize()

    aliases =
      (belongs_to_aliases ++ aliases ++ return_types)
      |> Enum.uniq()
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
              #{Enum.map(foreign_key_constraints, fn field_name -> "|> foreign_key_constraint(#{field_name})" end) |> Enum.join("\n")}
              # TODO should we support unique constraints in ecto
              # or just let Postgres do it?
              # |> unique_constraint(:email)
            end

          # Computed fields helpers
          @doc \"\"\"
          A helper function that returns all fields in a schema, in the order Postgres
          expects them as columns.
          \"\"\"
          def pg_columns() do
            [
            #{Enum.map(attributes, &":#{&1.name}") |> Enum.join(", ")}
            ]
          end


          def to_pg_row(%{} = map) do
            [#{Enum.map(attributes, &"{:#{&1.name}, :#{&1.type.name}}") |> Enum.join(", ")}]
            |> Enum.map(fn
              {field, :uuid} -> case Map.get(map, field) do
                nil -> nil
                id -> Ecto.UUID.dump!(id)
              end
              {field, _} -> Map.get(map, field)
            end)
            |> List.to_tuple()
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

          query = from(q in query, where: ^build_and(input, source))

          build_assoc_and(query, input, source)
        end

        defp build_assoc_and(query, input, source) do
          Enum.reduce(input, query, fn {k, v}, query ->
            if source && k in source.__schema__(:associations) do
              assoc = source.__schema__(:association, k)

              if assoc.relationship == :child do
                raise "Child associations are not currently supported"
              end

              join_query =
                join(query, :inner, [c], a in ^assoc.related,
                  on: [id: field(c, ^assoc.owner_key)],
                  as: :filter_assoc
                )

              conditions =
                Enum.reduce(v, nil, fn {k, v}, conditions ->
                  condition = build_assoc_condition(k, v)

                  if conditions == nil do
                    condition
                  else
                    if condition == nil do
                      conditions
                    else
                      dynamic([c], ^condition and ^conditions)
                    end
                  end
                end)

              if conditions == nil do
                join_query
              else
                join_query |> where(^conditions)
              end
            else
              query
            end
          end)
        end

        defp build_and(input, source \\\\ nil) do
          Enum.reduce(input, nil, fn {k, v}, conditions ->
            condition =
              unless source && k in source.__schema__(:associations) do
                build_condition(k, v)
              end

            if conditions == nil do
              condition
            else
              if condition == nil do
                conditions
              else
                dynamic([c], ^condition and ^conditions)
              end
            end
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

        defp build_assoc_condition(field, input) when is_binary(field),
          do: build_assoc_condition(String.to_existing_atom(field), input)

        defp build_assoc_condition(field, %{greater_than: value}),
          do: dynamic([c, filter_assoc: a], field(a, ^field) > ^value)

        defp build_assoc_condition(field, %{greater_than_or_equal_to: value}),
          do: dynamic([c, filter_assoc: a], field(a, ^field) >= ^value)

        defp build_assoc_condition(field, %{less_than: value}),
          do: dynamic([c, filter_assoc: a], field(a, ^field) < ^value)

        defp build_assoc_condition(field, %{less_than_or_equal_to: value}),
          do: dynamic([c, filter_assoc: a], field(a, ^field) <= ^value)

        defp build_assoc_condition(field, %{equal_to: value}),
          do: dynamic([c, filter_assoc: a], field(a, ^field) == ^value)

        defp build_assoc_condition(field, %{not_equal_to: value}),
          do: dynamic([c, filter_assoc: a], field(a, ^field) != ^value)

        defp build_assoc_condition(field, %{is_null: true}),
          do: dynamic([c, filter_assoc: a], is_nil(field(a, ^field)))

        defp build_assoc_condition(field, %{is_null: false}),
          do: dynamic([c, filter_assoc: a], not is_nil(field(a, ^field)))

        defp build_assoc_condition(field, value) when is_binary(value) or is_number(value),
          do: dynamic([c, filter_assoc: a], field(a, ^field) == ^value)

        defp build_assoc_condition(field, %{"$in" => value}) when is_list(value),
          do: dynamic([c, filter_assoc: a], field(a, ^field) in ^value)

        defp build_assoc_condition(field, value),
          do: raise(~s{U, ansupported filter "\#{field}": "\#{inspect(value)}"})

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
end
