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
          |> Enum.map(&FieldGenerator.to_string/1)
          |> Enum.join("\n")
      end

    {name,
     Code.format_string!(
       """
       defmodule #{Inflex.singularize(name) |> Macro.camelize()} do
         use Ecto.Schema



         @schema_prefix "#{schema}"
         # TODO all our primary keys are UUIDs; would be better
         # to make this optional
         @primary_key {:id, Ecto.UUID, autogenerate: false}
         @foreign_key_type :binary_id


         schema "#{name}" do
           #{attributes}

           # Referenced by
           #{references}
         end
       end
       """,
       locals_without_parens: [field: :*, belongs_to: :*, has_many: :*, has_one: :*]
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

  defp get_foreign_key_from_tuple({_, _, _, [fk: fk]}), do: fk
  defp get_foreign_key_from_tuple({_, _, _, _}), do: nil
  defp get_assoc_from_tuple({_, assoc, _}), do: assoc
  defp get_assoc_from_tuple({_, assoc, _, _}), do: assoc
end
