defmodule EctoGen.TableGenerator do
  alias PgGen.{Utils, Builder}
  alias EctoGen.FieldGenerator

  def generate(%{name: name, attributes: attributes} = table, schema) do
    attributes =
      attributes
      |> Enum.map(&Builder.build/1)
      |> Utils.deduplicate_associations()

    required_fields =
      attributes
      |> Enum.filter(&is_required/1)
      |> Enum.map(fn {_, name, _, _} -> ":#{name}" end)

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
            |> Utils.deduplicate_associations()
            |> Utils.deduplicate_joins()

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
     Code.format_string!(
       """
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
         # TODO all our primary keys are UUIDs; would be better
         # to make this optional
         @primary_key {:id, Ecto.UUID, autogenerate: false}
         @foreign_key_type :binary_id


         schema "#{name}" do
           #{attribute_string}

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
                # TODO should we support unique constraints in ecto
                # or just let Postgres do it?
                # |> unique_constraint(:email)
              end

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

  def is_required({_, _, _, opts}) do
    Keyword.get(opts, :is_not_null, false) && !Keyword.get(opts, :has_default)
  end
end
