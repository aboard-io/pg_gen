defmodule AbsintheGen.ResolverGenerator do
  alias PgGen.{Utils}

  @scalar_types [
    "text",
    "citext",
    "timestamptz",
    "uuid",
    "jsonb",
    "bool",
    "int4",
    "enum",
    "void"
  ]

  def generate(name, table, functions) do
    {name, resolver_template(PgGen.LocalConfig.get_app_name(), name, table, functions)}
  end

  def resolver_template(app_name, name, table, functions) do
    %{
      selectable: selectable,
      insertable: insertable,
      updatable: updatable,
      deletable: deletable
    } = table

    %{
      singular_camelized_table_name: singular_camelized_table_name,
      singular_underscore_table_name: singular_underscore_table_name
    } = Utils.get_table_names(name)

    module_name =
      "#{app_name}Web.Resolvers.#{singular_camelized_table_name}"
      |> Macro.camelize()

    extensions_module = Module.concat(Elixir, "#{module_name}.Extend")
    extensions_module_exists = Utils.does_module_exist(extensions_module)

    function_strings_for_table =
      functions
      |> Enum.filter(fn
        %{return_type: %{type: %{name: ^name}}} -> true
        _ -> false
      end)
      |> Enum.filter(fn %{name: name} ->
        !(extensions_module_exists && name in extensions_module.overrides())
      end)
      |> Enum.map(&custom_function_to_string/1)
      |> Enum.join("\n")

    app_atom = Macro.camelize(app_name)

    if !insertable && !selectable && !updatable && !deletable && !extensions_module_exists &&
         function_strings_for_table == "" do
      nil
    else
      """
      defmodule #{module_name} do
        alias #{app_atom}.Contexts.#{singular_camelized_table_name}
        #{if selectable, do: "alias #{Macro.camelize(app_name)}Web.Resolvers", else: ""}
        #{if insertable || updatable || deletable do
        "alias #{app_name}Web.Schema.ChangesetErrors"
      end}

        #{if selectable do
        select_name = "#{singular_underscore_table_name}"
        unless extensions_module_exists && select_name in extensions_module.overrides() do
          """
          def #{singular_underscore_table_name}(_, %{id: id}, info) do
            computed_selections =
              Resolvers.Utils.get_computed_selections(
                info,
                #{app_atom}.Repo.#{singular_camelized_table_name}
              )
      
            {:ok, #{singular_camelized_table_name}.get_#{singular_underscore_table_name}!(id, computed_selections)}
          end
          """
        else
          ""
        end
      end}

        #{if selectable do
        select_all_name = "#{name}"
        unless extensions_module_exists && select_all_name in extensions_module.overrides() do
          """
          def #{name}(_, args, info) do
            computed_selections =
              Resolvers.Utils.get_computed_selections(
                info,
                #{app_atom}.Repo.#{singular_camelized_table_name}
              )
      
            {:ok, %{ nodes: #{singular_camelized_table_name}.list_#{name}(args, computed_selections), args: args }}
          end
          """
        else
          ""
        end
      else
        ""
      end}

        #{if insertable do
        insert_name = "create_#{singular_underscore_table_name}"
        unless extensions_module_exists && insert_name in extensions_module.overrides() do
          """
          def create_#{singular_underscore_table_name}(parent, %{input: input}, _) do
            case #{app_name}.Contexts.#{singular_camelized_table_name}.create_#{singular_underscore_table_name}(input) do
              {:ok, #{singular_underscore_table_name}} ->
                {:ok, %{#{singular_underscore_table_name}: #{singular_underscore_table_name}, query: parent}}
              {:error, changeset} ->
                {:error,
                  message: "Could not create #{singular_camelized_table_name}",
                  details: ChangesetErrors.error_details(changeset)
                }
            end
          end
          """
        else
          ""
        end
      else
        ""
      end}

        #{if updatable do
        update_name = "update_#{singular_underscore_table_name}"
        unless extensions_module_exists && update_name in extensions_module.overrides() do
          """
          def update_#{singular_underscore_table_name}(parent, %{input: input}, _) do
            #{singular_underscore_table_name} = #{app_name}.Contexts.#{singular_camelized_table_name}.get_#{singular_underscore_table_name}!(input.id)
            case #{app_name}.Contexts.#{singular_camelized_table_name}.update_#{singular_underscore_table_name}(#{singular_underscore_table_name}, input.patch) do
              {:ok, #{singular_underscore_table_name}} ->
                {:ok, %{#{singular_underscore_table_name}: #{singular_underscore_table_name}, query: parent}}
              {:error, changeset} ->
                {:error,
                  message: "Could not update #{singular_camelized_table_name}",
                  details: ChangesetErrors.error_details(changeset)
                }
            end
          end
          """
        else
          ""
        end
      else
        ""
      end}
        #{if deletable do
        delete_name = "delete_#{singular_underscore_table_name}"
        unless extensions_module_exists && delete_name in extensions_module.overrides() do
          """
          def #{delete_name}(parent, %{id: id}, _) do
            #{singular_underscore_table_name} = #{app_name}.Contexts.#{singular_camelized_table_name}.get_#{singular_underscore_table_name}!(id)
            case #{app_name}.Contexts.#{singular_camelized_table_name}.delete_#{singular_underscore_table_name}(#{singular_underscore_table_name}) do
              {:ok, #{singular_underscore_table_name}} -> 
                {:ok, %{#{singular_underscore_table_name}: #{singular_underscore_table_name}, query: parent}}
              {:error, changeset} ->
                {:error,
                  message: "Could not update #{singular_camelized_table_name}",
                  details: ChangesetErrors.error_details(changeset)
                }
            end
          end
          """
        else
          ""
        end
      else
        ""
      end}

        #{if extensions_module_exists do
        """
          #{extensions_module.extensions() |> Enum.join("\n\n")}
        """
      else
        ""
      end}

        #{function_strings_for_table}
      end
      """
    end
  end

  def custom_function_to_string(%{returns_set: true} = function),
    do: custom_function_returning_set_to_string(function)

  def custom_function_to_string(%{returns_set: false} = function),
    do: custom_function_returning_record_to_string(function)

  def custom_function_returning_set_to_string(%{
        name: name,
        return_type: %{type: %{name: type_name}},
        arg_names: arg_names,
        is_stable: is_stable,
        returns_set: true
      }) do
    context_module_str = type_name |> Inflex.singularize() |> Macro.camelize()
    args_for_context = Enum.join(arg_names, ", ")

    has_args = length(arg_names) > 0

    """
    def #{name}(_, args, _) do
      #{if has_args do
      """
      %{
        #{Enum.map(arg_names, fn name -> "#{name}: #{name}" end) |> Enum.join(", ")}
        } = #{if is_stable, do: "args", else: "args.input"}
      """
    end}
      {:ok, %{nodes: #{context_module_str}.#{name}(#{if has_args, do: "#{args_for_context},"} args), args: args}}
    end
    """
  end

  def custom_function_returning_record_to_string(%{
        name: name,
        return_type: %{type: %{name: type_name}},
        arg_names: arg_names,
        is_stable: is_stable,
        returns_set: false
      }) do
    context_module_str = type_name |> Inflex.singularize() |> Macro.camelize()

    return_value =
      get_custom_return_value(context_module_str, name, arg_names, type_name, is_stable)

    has_args = length(arg_names) > 0

    """
    def #{name}(#{if is_stable, do: "_", else: ""}parent, #{if has_args, do: "args", else: "_"}, _) do
      #{if has_args do
      """
      %{
        #{Enum.map(arg_names, fn name -> "#{name}: #{name}" end) |> Enum.join(", ")}
        } = #{if is_stable, do: "args", else: "args.input"}
      """
    end}
      {:ok, #{return_value}}
    end
    """
  end

  def generate_custom_functions_returning_scalars_and_records_to_string(functions, module_name) do
    function_strs =
      functions
      |> Enum.filter(fn
        %{return_type: %{type: %{name: type_name}}} when type_name in @scalar_types -> true
        %{return_type: %{type: %{category: "E"}}} -> true
        %{return_type: %{composite_type: true}} -> true
        _ -> false
      end)
      |> Enum.map(fn %{name: name, arg_names: arg_names, is_stable: is_stable} ->
        arg_names_str = Enum.join(arg_names, ", ")

        has_args = length(arg_names) > 0

        """
        def #{name}(_, #{if has_args, do: "args", else: "_"}, _) do
          #{if has_args do
          """
          %{
            #{Enum.map(arg_names, fn name -> "#{name}: #{name}" end) |> Enum.join(", ")}
            } = #{if is_stable, do: "args", else: "args.input"}
          """
        end}
          {:ok, #{module_name}.Contexts.PgFunctions.#{name}(#{arg_names_str})}
        end
        """
      end)
      |> Enum.join("\n\n")

    """
    defmodule #{module_name}Web.Resolvers.PgFunctions do
      #{function_strs}
    end
    """
  end

  def resolvers_utils_template(app_name) do
    """
    defmodule #{app_name}Web.Resolvers.Utils do

      alias #{app_name}.Repo

      def get_computed_selections(info, repo) do
        project = Absinthe.Resolution.project(info)

        computed_fields = repo.computed_fields()

        case Enum.filter(project, &(&1.name == "nodes")) do
          [] -> project
          [nodes] -> nodes.selections
        end
        |> Enum.map(& &1.schema_node.identifier)
        |> Enum.filter(&(&1 in computed_fields))
      end

      def cast_computed_selections(struct, computed_selections_with_type) do
        Enum.reduce(computed_selections_with_type, struct, fn
          {selection, type}, acc ->
            raw_result = Map.get(struct, selection)
            cast_result = cast_computed_selection(raw_result, type)
            Map.put(acc, selection, cast_result)
        end)
      end

      # If it's a list, we need to map over the list to cast the contents
      def cast_computed_selection(raw_result, type) when is_list(raw_result) do
        Enum.map(raw_result, &cast_computed_selection(&1, type))
      end

      # If it's a tuple, it needs to be cast
      def cast_computed_selection(raw_result, type) when is_tuple(raw_result) do
        if Kernel.function_exported?(type, :pg_columns, 0) do
          Repo.load(
            type,
            {type.pg_columns(), Tuple.to_list(raw_result)}
          )
        else
          raw_result
        end
      end

      # If it's not a tuple, we can leave it as is
      def cast_computed_selection(result, _), do: result

    end
    """
  end

  defp get_custom_return_value(context_module_str, name, arg_names, return_type_name, is_stable) do
    args_for_context = Enum.join(arg_names, ", ")
    return_type_str = Inflex.singularize(return_type_name)

    if is_stable do
      """
        #{context_module_str}.#{name}(#{if length(arg_names) > 0, do: "#{args_for_context}"})
      """
    else
      """
      %{
        #{return_type_str}: #{context_module_str}.#{name}(#{if length(arg_names) > 0, do: "#{args_for_context}"}),
        query: parent
      }
      """
    end
  end
end
