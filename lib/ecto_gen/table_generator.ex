defmodule EctoGen.TableGenerator do
  alias EctoGen.FieldGenerator

  def generate(%{name: name, attributes: attributes} = table, schema) do
    IO.puts("====================#{name}===============")

    attributes =
      attributes
      |> Enum.map(&FieldGenerator.generate/1)
      |> deduplicate_associations
      |> Enum.map(&FieldGenerator.to_string/1)
      |> Enum.sort()
      |> Enum.reverse()
      |> Enum.join("\n")

    references =
      case Map.get(table, :external_references) do
        nil ->
          ""

        references ->
          references
          |> Enum.map(&FieldGenerator.generate/1)
          |> deduplicate_associations
          |> dedupe_first_pass
          |> dedupe_second_pass
          |> Enum.map(&FieldGenerator.to_string/1)
          |> Enum.sort()
          |> Enum.join("\n")
      end

    {name,
     Code.format_string!(
       """
       defmodule #{Inflex.singularize(name) |> Macro.camelize()} do
         #{if !is_nil(table.description) do
         """
         @moduledoc \"\"\"
         #{table.description}
         \"\"\"
         """
       end}
         use Ecto.Schema



         @schema_prefix "#{schema}"
         # TODO all our primary keys are UUIDs; would be better
         # to make this optional
         @primary_key {:id, Ecto.UUID, autogenerate: false}
         @foreign_key_type :binary_id


         schema "#{name}" do
           #{attributes}

           #{if String.trim(references) != "" do
         """
         # Relations
         #{references}
         """
       end}
         end
       end
       """,
       locals_without_parens: [
         field: :*,
         belongs_to: :*,
         has_many: :*,
         has_one: :*,
         many_to_many: :*
       ]
     )}
  end

  @doc """
  If two field associations have the same name, prioritize the name with the default
  foreign key; use the non-default foreign key to name the other field

  iex> EctoGen.TableGenerator.deduplicate_associations([
  ...>   {:has_many, "comments", "Comment", []},
  ...>   {:has_many, "foos", "Foo", []},
  ...>   {:has_many, "comments", "Comment", fk: "alt_comment_id"}
  ...> ])
  [{:has_many, "alt_comments", "Comment", fk: "alt_comment_id"}, {:has_many, "comments", "Comment", []}, {:has_many, "foos", "Foo", []}]

  iex> EctoGen.TableGenerator.deduplicate_associations([
  ...>   {:many_to_many, "users", "User", [join_through: "objects", fk: "created_by"]},
  ...>   {:many_to_many, "users", "User", [join_through: "objects", fk: "archived_by"]}
  ...> ])
  [{:many_to_many, "archived_by_users", "User", join_through: "objects", fk: "archived_by"}, {:many_to_many, "created_by_users", "User", join_through: "objects", fk: "created_by"}]
  """
  def deduplicate_associations(attributes) do
    attributes =
      Enum.sort(attributes, fn l, r -> get_assoc_from_tuple(l) < get_assoc_from_tuple(r) end)

    associations = Enum.map(attributes, fn tuple -> get_assoc_from_tuple(tuple) end)

    duplicated_names = Enum.uniq(associations -- Enum.uniq(associations))

    Enum.map(attributes, fn tuple ->
      assoc = get_assoc_from_tuple(tuple)

      case Enum.member?(duplicated_names, assoc) do
        true ->
          case get_foreign_key_from_tuple(tuple) do
            nil ->
              tuple

            fk ->
              {relationship, table_name, queryable, opts} = tuple

              {relationship, FieldGenerator.format_assoc(fk, table_name) |> Inflex.pluralize(),
               queryable, opts}
          end

        false ->
          tuple
      end
    end)
  end

  @doc """
  iex> EctoGen.TableGenerator.deduplicate_join_associations([
  ...> {:many_to_many, "objects", "Object", join_through: "attachments"},
  ...> {:many_to_many, "objects", "Object", join_through: "object_activity_events"}
  ...> ], 1)
  [{:many_to_many, "attachment_objects", "Object", join_through: "attachments"},
  {:many_to_many, "object_activity_event_objects", "Object", join_through: "object_activity_events"}]

  """
  def deduplicate_join_associations(attributes, attempt) do
    associations = Enum.map(attributes, fn tuple -> get_assoc_from_tuple(tuple) end)

    duplicated_names = Enum.uniq(associations -- Enum.uniq(associations))

    Enum.map(attributes, fn tuple ->
      assoc = get_assoc_from_tuple(tuple)

      case Enum.member?(duplicated_names, assoc) do
        true ->
          case get_join_through_from_tuple(tuple) do
            nil ->
              tuple

            join_through ->
              {relationship, table_name, queryable, opts} = tuple

              case attempt do
                1 ->
                  {relationship,
                   FieldGenerator.format_assoc(Inflex.singularize(join_through), table_name)
                   |> Inflex.pluralize(), queryable, opts}

                2 ->
                  case Tuple.to_list(tuple) |> hd do
                    :has_many ->
                      tuple

                    _ ->
                      case opts[:join_keys] do
                        nil ->
                          tuple

                        [{prefix, _}, _] ->
                          {relationship, prefix <> "_" <> assoc, queryable, opts}
                      end
                  end
              end
          end

        false ->
          tuple
      end
    end)
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

  def dedupe_first_pass(associations), do: deduplicate_join_associations(associations, 1)
  def dedupe_second_pass(associations), do: deduplicate_join_associations(associations, 2)

  defp get_foreign_key_from_tuple({_, _, _, opts}), do: opts[:fk]
  defp get_join_through_from_tuple({_, _, _, opts}), do: opts[:join_through]

  defp get_assoc_from_tuple({_, assoc, _}), do: assoc
  defp get_assoc_from_tuple({_, assoc, _, _}), do: assoc
end
