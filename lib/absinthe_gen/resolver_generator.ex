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
          {table_selections, computed_selections} =
            Resolvers.Utils.get_selections(
              info,
              #{app_atom}.Repo.#{singular_camelized_table_name}
            )

          {:ok, #{singular_camelized_table_name}.get_#{singular_underscore_table_name}!(id, table_selections, computed_selections)}
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
          {table_selections, computed_selections} =
            Resolvers.Utils.get_selections(
              info,
              #{app_atom}.Repo.#{singular_camelized_table_name}
            )

          {:ok, %{ nodes: #{singular_camelized_table_name}.list_#{name}(args, table_selections, computed_selections), args: args }}
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

  def custom_function_to_string(%{returns_set: true} = function),
    do: custom_function_returning_set_to_string(function)

  def custom_function_to_string(%{returns_set: false} = function),
    do: custom_function_returning_record_to_string(function)

  def custom_function_returning_set_to_string(%{
        name: name,
        return_type: %{type: %{name: type_name}},
        arg_names: arg_names,
        returns_set: true
      }) do
    context_module_str = type_name |> Inflex.singularize() |> Macro.camelize()
    args_for_context = Enum.join(arg_names, ", ")

    """
    def #{name}(_, args, _) do
      %{
        #{Enum.map(arg_names, fn name -> "#{name}: #{name}" end) |> Enum.join(", ")}
      } = args
      {:ok, %{nodes: #{context_module_str}.#{name}(#{if length(arg_names) > 0, do: "#{args_for_context},"} args), args: args}}
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

    """
    def #{name}(#{if is_stable, do: "_", else: ""}parent, args, _) do
      %{
        #{Enum.map(arg_names, fn name -> "#{name}: #{name}" end) |> Enum.join(", ")}
      } = args
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
      |> Enum.map(fn %{name: name, arg_names: arg_names} ->
        arg_names_str = Enum.join(arg_names, ", ")

        """
        def #{name}(_, args, _) do
          %{
            #{Enum.map(arg_names, fn name -> "#{name}: #{name}" end) |> Enum.join(", ")}
          } = args
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

  def resolvers_utils_template(module_name) do
    """
    defmodule #{module_name}.Resolvers.Utils do
      def get_selections(info, repo) do
        project = Absinthe.Resolution.project(info)

        fields = repo.__schema__(:fields)
        computed_fields = repo.computed_fields()

        top_level_fields =
          case Enum.filter(project, &(&1.name == "nodes")) do
            [] -> project
            [nodes] -> nodes.selections
          end

        selections =
          top_level_fields
          |> Enum.map(& &1.schema_node.identifier)
          # Always select primary key(s), since we will need it/them for nested associations
        selections = selections ++ repo.__schema__(:primary_key)
          # |> List.insert_at(0, :id)

        table_selections =
          selections
          |> Enum.filter(&(&1 in fields))
          |> IO.inspect()

        computed_selections =
          selections
          |> Enum.filter(&(&1 in computed_fields))
          |> IO.inspect()

        {table_selections, computed_selections}
      end
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
