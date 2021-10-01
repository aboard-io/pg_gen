defmodule EctoGen.TableGenerator do
  alias PgGen.{Utils, Builder}
  alias EctoGen.FieldGenerator

  def generate(%{name: name, attributes: attributes} = table, computed_fields, schema) do
    attributes =
      attributes
      |> Enum.map(&Builder.build/1)
      |> Utils.deduplicate_associations()

    required_fields =
      attributes
      |> Enum.filter(&is_required/1)
      |> Enum.map(fn
        {:field, name, _, _} ->
          ":#{name}"

        {:belongs_to, name, _, opts} ->
          ":" <> Keyword.get(opts, :fk, "#{name}_id")
      end)

    foreign_key_constraints =
      attributes
      |> Enum.filter(fn
        {:belongs_to, _, _, _} -> true
        {_, _, _, _} -> false
      end)
      |> Enum.map(fn
        {_, name, _, opts} ->
          ":" <> Keyword.get(opts, :fk, "#{name}_id")
      end)

    all_fields =
      attributes
      |> Enum.map(fn {field_or_assoc, name, _, options} ->
        case field_or_assoc do
          :field -> ":#{name}"
          :belongs_to -> ":#{options[:fk] || name <> "_id"}"
          type -> raise "Ooops didn't handle this attribute type# #{type}"
        end
      end)

    attribute_string =
      attributes
      |> Enum.map(&FieldGenerator.to_string/1)
      |> Enum.sort()
      |> Enum.reverse()
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

    # if a table has no default primary key
    {_, _, primary_key_type, _} =
      Enum.find(attributes, fn
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
      attributes
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

    aliases =
      (belongs_to_aliases ++ aliases)
      |> Enum.uniq()
      |> Enum.join(", ")

    app_name = PgGen.LocalConfig.get_app_name() |> Macro.camelize()
    singular_lowercase = Inflex.singularize(name)

    {name,
     Utils.format_code!("""
     defmodule #{app_name}.Repo.#{Inflex.singularize(name) |> Macro.camelize()} do
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

          # Computed fields
          def computed_fields do
            [#{computed_fields_fun_str}]
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
      # Cast strings into the list of maps to be used at runtime
      def cast(json) when is_binary(json) do
        decoded = Jason.decode!(json)

        case is_list(decoded) do
          true -> {:ok, decoded}
          false -> {:ok, [decoded]}
        end
      end

      # Everything else is a failure though
      def cast(_), do: :error

      def load(data) when is_map(data) do
        {:ok, [data]}
      end

      def load(data) when is_list(data) do
        {:ok, data}
      end

      # When dumping data to the database, we *expect* a URI struct
      # but any value could be inserted into the schema struct at runtime,
      # so we need to guard against them.
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

  def is_required({_, _, _, opts}) do
    !Keyword.get(opts, :has_default) && Keyword.get(opts, :is_not_null)
  end
end
