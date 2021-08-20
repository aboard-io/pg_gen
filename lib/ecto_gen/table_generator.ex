defmodule EctoGen.TableGenerator do
  alias PgGen.{Utils, Builder}
  alias EctoGen.FieldGenerator

  def generate(%{name: name, attributes: attributes} = table, schema) do
    IO.puts("====================#{name}===============")

    attributes =
      attributes
      |> Enum.map(&Builder.build/1)
      |> Utils.deduplicate_associations
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
          |> Enum.map(&Builder.build/1)
          |> Utils.deduplicate_associations
          |> Utils.deduplicate_joins
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
end
