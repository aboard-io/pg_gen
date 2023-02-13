defmodule PgGen.Utils do
  @moduledoc """
  Helper utilities shared between EctoGen and AbsintheGen.
  """

  alias PgGen.Builder

  def format_code!(code_str) do
    try do
      Code.format_string!(code_str,
        locals_without_parens: [
          field: :*,
          belongs_to: :*,
          has_many: :*,
          has_one: :*,
          many_to_many: :*,
          object: :*,
          arg: :*,
          resolve: :*,
          value: :*,
          enum: :*,
          import_types: :*
        ]
      )
    rescue
      _ ->
        IO.puts(code_str)
        IO.puts("Something wrong with the above code string")
    end
  end

  @doc """
  If two field associations have the same name, prioritize the name with the default
  foreign key; use the non-default foreign key to name the other field

  iex> PgGen.Utils.deduplicate_associations([
  ...>   {:has_many, "comments", "Comment", []},
  ...>   {:has_many, "foos", "Foo", []},
  ...>   {:has_many, "comments", "Comment", fk: "alt_comment_id"}
  ...> ])
  [{:has_many, "alt_comments", "Comment", fk: "alt_comment_id"}, {:has_many, "comments", "Comment", []}, {:has_many, "foos", "Foo", []}]

  iex> PgGen.Utils.deduplicate_associations([
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

              {relationship, Builder.format_assoc(fk, table_name) |> pluralize(), queryable, opts}
          end

        false ->
          tuple
      end
    end)
  end

  @doc """
  iex> PgGen.Utils.deduplicate_join_associations([
  ...> {:many_to_many, "objects", "Object", join_through: "attachments"},
  ...> {:many_to_many, "objects", "Object", join_through: "object_activity_events"}
  ...> ], 1)
  [{:many_to_many, "objects_by_attachments", "Object", join_through: "attachments"},
  {:many_to_many, "objects_by_object_activity_events", "Object", join_through: "object_activity_events"}]

  iex> PgGen.Utils.deduplicate_join_associations([
  ...>   {:many_to_many, "attachments", "Attachment", [join_through: "pinned_items", join_keys: [{"comment_id", "id"}, {"attachment_id", "id"}]]},
  ...>   {:has_many, "attachments", "Attachment", [fk: "comment_id"]}
  ...> ], 1)
  [{:many_to_many, "attachments_by_pinned_items", "Attachment", [join_through: "pinned_items", join_keys: [{"comment_id", "id"}, {"attachment_id", "id"}]]},
    {:has_many, "attachments", "Attachment", [fk: "comment_id"]}]
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
                  case Tuple.to_list(tuple) |> List.first() do
                    :has_many ->
                      tuple

                    # {:has_many,
                    #  Builder.format_assoc(get_foreign_key_from_tuple(tuple), table_name)
                    #  |> Inflex.pluralize(), queryable, opts}

                    _ ->
                      case get_foreign_key_from_tuple(tuple) do
                        nil ->
                          {relationship, (table_name <> "_by_" <> join_through) |> pluralize(),
                           queryable, opts}

                        fk ->
                          {relationship, Builder.format_assoc(fk, table_name) |> pluralize(),
                           queryable, opts}
                      end
                  end

                2 ->
                  case Tuple.to_list(tuple) |> List.first() do
                    :has_many ->
                      tuple

                    _ ->
                      case get_foreign_key_from_tuple(tuple) do
                        nil ->
                          case opts[:join_keys] do
                            nil ->
                              tuple

                            [{prefix, _}, _] ->
                              {relationship, assoc <> "_by_" <> prefix, queryable, opts}
                          end

                        fk ->
                          {relationship,
                           (Builder.format_assoc(fk, table_name) |> pluralize()) <>
                             "_by_" <> join_through, queryable, opts}
                      end
                  end

                3 ->
                  case Tuple.to_list(tuple) |> List.first() do
                    :has_many ->
                      tuple

                    _ ->
                      case opts[:join_keys] do
                        nil ->
                          tuple

                        [{prefix, _}, _] ->
                          {relationship, assoc <> "_by_" <> prefix, queryable, opts}
                      end
                  end
              end
          end

        false ->
          tuple
      end
    end)
  end

  def pluralize(name) when name in ["movie", "movies"] do
    "movies"
  end

  def pluralize(name), do: Inflex.pluralize(name)

  def singularize(name), do: Inflex.singularize(name)

  def get_table_names(name) do
    singular = singularize(name)
    plural = pluralize(name)

    %{
      singular_camelized_table_name: Macro.camelize(singular),
      plural_camelized_table_name: Macro.camelize(plural),
      singular_underscore_table_name: Macro.underscore(singular),
      plural_underscore_table_name: Macro.underscore(plural)
    }
  end

  def deduplicate_joins(associations), do: associations |> dedupe_first_pass |> dedupe_second_pass

  def deduplicate_references(associations) do
    associations
    |> dedupe_first_pass()
    |> deduplicate_associations()
    |> dedupe_second_pass()
    |> dedupe_third_pass()
  end

  def does_module_exist(mod_str) when is_binary(mod_str) do
    module = Module.concat(Elixir, mod_str)
    does_module_exist(module)
  end

  def does_module_exist(module) when is_atom(module) do
    case Code.ensure_compiled(module) do
      {:module, ^module} -> true
      _ -> false
    end
  end

  def maybe_apply(module, fun, args \\ [], fallback \\ nil)

  def maybe_apply(module, fun, args, fallback) when is_binary(fun),
    do: maybe_apply(module, String.to_atom(fun), args, fallback)

  def maybe_apply(module, fun, args, fallback) do
    if __MODULE__.does_module_exist(module) do
      if Kernel.function_exported?(module, fun, length(args)) do
        apply(module, fun, args)
      else
        fallback
      end
    else
      fallback
    end
  end

  defp dedupe_first_pass(associations), do: deduplicate_join_associations(associations, 1)
  defp dedupe_second_pass(associations), do: deduplicate_join_associations(associations, 2)
  defp dedupe_third_pass(associations), do: deduplicate_join_associations(associations, 3)
  defp get_foreign_key_from_tuple({_, _, _, opts}), do: opts[:fk]
  defp get_join_through_from_tuple({_, _, _, opts}), do: opts[:join_through]

  defp get_assoc_from_tuple({_, assoc, _}), do: assoc
  defp get_assoc_from_tuple({_, assoc, _, _}), do: assoc
end
