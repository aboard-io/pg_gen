defmodule AbsintheGen.ResolverGenerator do
  alias PgGen.{Utils, Builder}

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

    function_strings_for_table =
      functions
      |> Enum.filter(fn
        %{return_type: %{type: %{name: ^name}}} -> true
        _ -> false
      end)
      |> Enum.map(&custom_function_to_string/1)
      |> Enum.join("\n")

    """
    defmodule #{module_name} do
      alias #{Macro.camelize(app_name)}.Contexts.#{singular_camelized_table_name}
      #{if insertable || updatable || deletable do
      "alias #{app_name}Web.Schema.ChangesetErrors"
    end}

      #{if selectable do
      """
      def #{singular_underscore_table_name}(_, %{id: id}, _) do
        {:ok, #{singular_camelized_table_name}.get_#{singular_underscore_table_name}!(id)}
      end
    
      def #{name}(_, args, _) do
        {:ok, %{ nodes: #{singular_camelized_table_name}.list_#{name}(args), args: args }}
      end
      """
    else
      ""
    end}

      #{if insertable do
      """
      def create_#{singular_underscore_table_name}(_, %{input: input}, _) do
        case #{app_name}.Contexts.#{singular_camelized_table_name}.create_#{singular_underscore_table_name}(input) do
          {:ok, #{singular_underscore_table_name}} -> {:ok, #{singular_underscore_table_name}}
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
    end}

      #{if updatable do
      """
      def update_#{singular_underscore_table_name}(_, %{input: input}, _) do
        #{singular_underscore_table_name} = #{app_name}.Contexts.#{singular_camelized_table_name}.get_#{singular_underscore_table_name}!(input.id)
        case #{app_name}.Contexts.#{singular_camelized_table_name}.update_#{singular_underscore_table_name}(#{singular_underscore_table_name}, input.patch) do
          {:ok, #{singular_underscore_table_name}} -> {:ok, #{singular_underscore_table_name}}
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
    end}
      #{if deletable do
      """
      def delete_#{singular_underscore_table_name}(_, %{id: id}, _) do
        #{singular_underscore_table_name} = #{app_name}.Contexts.#{singular_camelized_table_name}.get_#{singular_underscore_table_name}!(id)
        case #{app_name}.Contexts.#{singular_camelized_table_name}.delete_#{singular_underscore_table_name}(#{singular_underscore_table_name}) do
          {:ok, #{singular_underscore_table_name}} -> {:ok, #{singular_underscore_table_name}}
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
    end}

      #{if Utils.does_module_exist(extensions_module) do
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
        returns_set: false
      }) do
    context_module_str = type_name |> Inflex.singularize() |> Macro.camelize()
    args_for_context = Enum.join(arg_names, ", ")

    """
    def #{name}(_, args, _) do
      %{
        #{Enum.map(arg_names, fn name -> "#{name}: #{name}" end) |> Enum.join(", ")}
      } = args
      {:ok, #{context_module_str}.#{name}(#{if length(arg_names) > 0, do: "#{args_for_context}"})}
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
end
