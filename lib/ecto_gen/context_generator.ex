defmodule EctoGen.ContextGenerator do
  alias PgGen.Utils
  require Logger

  @scalar_types [
    "text",
    "citext",
    "timestamptz",
    "uuid",
    "jsonb",
    "bool",
    "int2",
    "int4",
    "int8",
    "enum",
    "void"
  ]

  @optional_field_missing ":__MISSING__"

  def generate({:enum_types, _}, _) do
    nil
  end

  def generate(
        %{
          name: name
        } = table,
        functions,
        app_name,
        schema
      ) do
    app_module_name = PgGen.Utils.singularize(app_name) |> Macro.camelize()
    table_name = PgGen.Utils.singularize(name) |> Macro.camelize()

    module_name = "#{app_module_name}.Contexts.#{table_name}"
    extension_module_name = "#{module_name}.Extend"
    overrides = get_overrides(extension_module_name)
    extensions = get_extensions(extension_module_name)
    preloads = get_preloads(extension_module_name)

    function_strings_for_table =
      (functions.queries ++ functions.mutations)
      |> Enum.filter(fn
        %{return_type: %{type: %{name: ^name}}} -> true
        _ -> false
      end)
      |> Enum.filter(fn
        %{name: name} -> name not in overrides
        _ -> false
      end)
      |> Enum.map(&custom_function_to_string(&1, schema, preloads, table))
      |> Enum.join("\n")

    computed_columns =
      functions.computed_columns_by_table[name]
      |> Enum.map(&custom_column_to_string(&1, table, schema))

    has_custom_functions = String.trim(function_strings_for_table) != ""

    unless table.selectable || table.insertable || table.updatable || table.deletable ||
             has_custom_functions do
      # Logger.warn("This table is no good: #{table.name}")
      {name, nil}
    else
      module = """
      defmodule #{module_name} do

       import Ecto.Query, warn: false
       alias #{app_module_name}.Repo

       alias #{app_module_name}.Repo.#{table_name}
       #{if table.selectable, do: "alias #{app_module_name}Web.Resolvers.Utils"}
       #{if table.selectable, do: "alias #{app_module_name}Web.Resolvers.Connections"}

         #{generate_selectable(table, functions.computed_columns_by_table[name], overrides, schema, app_module_name)}
         #{generate_insertable(table, overrides, preloads)}
         #{generate_updatable(table, overrides, preloads)}
         #{generate_deletable(table, overrides)}
         #{function_strings_for_table}
         #{computed_columns}
         #{Enum.join(extensions, "\n\n")}

      end
      """

      {name, Utils.format_code!(module)}
    end
  end

  def generate_selectable(
        table,
        computed_columns,
        overrides,
        schema,
        app_module_name \\ ""
      )

  def generate_selectable(
        %{selectable: true, name: name},
        computed_columns,
        overrides,
        schema,
        app_module_name
      ) do
    %{table_name: table_name, lower_case_table_name: lower_case_table_name} =
      get_table_names(name)

    get_name = "get_#{PgGen.Utils.singularize(lower_case_table_name)}!"
    list_name = "list_#{PgGen.Utils.pluralize(lower_case_table_name)}"

    singular_table_name = lower_case_table_name |> Inflex.singularize()

    is_cacheable =
      AbsintheGen.ResolverGenerator.root_query_is_cacheable(
        app_module_name,
        singular_table_name
      )

    """
    #{if get_name not in overrides do
      """
      #{if is_cacheable do
        cache_ttl = AbsintheGen.ResolverGenerator.get_cache_ttl(app_module_name)
        """
        def #{get_name}(id, computed_selections \\\\ [], context \\\\ %{})
      
        def #{get_name}(id, computed_selections, %{current_user: nil}) do
          cache_key = {:#{singular_table_name}, id}
      
          if value = #{app_module_name}.Contexts.Cache.get(cache_key) do
            value
          else
            result = #{get_name}(id, computed_selections, nil)
            #{app_module_name}.Contexts.Cache.put(cache_key, result, ttl: #{cache_ttl})
            result
          end
        end
        """
      else
        ""
      end}
      def #{get_name}(id, computed_selections#{if is_cacheable, do: ",_", else: "\\\\ []"}) do
        case from(#{table_name})
        |> with_computed_columns(computed_selections)
        |> Repo.get(id) do
          nil -> :error
        result -> result |> Utils.cast_computed_selections(
            #{table_name}.computed_fields_with_types(computed_selections)
          )
        end
      end
      """
    end}

    #{if list_name not in overrides do
      """
      def list_#{PgGen.Utils.pluralize(lower_case_table_name)}(args, computed_selections \\\\ []) do
        from(#{table_name})
        |> Connections.query(__MODULE__).(
          Map.merge(args, %{
            __selections: %{
              computed_selections: computed_selections
            }
          })
        )
        |> Repo.all()
        |> Enum.map(
          &Utils.cast_computed_selections(
            &1,
            #{table_name}.computed_fields_with_types(computed_selections)
          )
        )
      end
      """
    end}

    def with_computed_columns(query, []), do: query
    #{if length(computed_columns) > 0, do: """
      def with_computed_columns(query, selections) do
        #{Enum.map(computed_columns, fn %{name: name, simplified_name: simplified_name} -> """
        query =
          if :#{simplified_name} in selections do
            query
            |> select_merge([t], %{
              #{simplified_name}: fragment("select #{schema}.#{name}(?)", t)
            })
          else
            query
          end
        """ end) |> Enum.join("\n\n")}
        query
      end
      """}
    """
  end

  def generate_selectable(_, _, _, _, _), do: ""

  def generate_insertable(%{selectable: true, name: name}, overrides, preloads) do
    %{table_name: table_name, lower_case_table_name: lower_case_table_name} =
      get_table_names(name)

    singular_lowercase = PgGen.Utils.singularize(lower_case_table_name)
    create_name = "create_#{singular_lowercase}"

    preload = Map.get(preloads, create_name, false)

    if create_name in overrides do
      ""
    else
      """
      def create_#{singular_lowercase}(attrs) do
        #{if preload, do: "result = ", else: ""}
        %#{table_name}{}
        |> #{table_name}.changeset(attrs)
        |> Repo.insert(returning: true)
        #{if preload do
        """
        case result do
          {:ok, record} -> {:ok, Repo.preload(record, #{Macro.to_string(preload)})}
          error -> error
        end
        """
      else
        ""
      end}
      end
      """
    end
  end

  def generate_insertable(_, _, _), do: ""

  def generate_updatable(%{selectable: true, name: name}, overrides, preloads) do
    %{table_name: table_name, lower_case_table_name: lower_case_table_name} =
      get_table_names(name)

    singular_lowercase = PgGen.Utils.singularize(lower_case_table_name)
    update_name = "update_#{singular_lowercase}"

    preload = Map.get(preloads, update_name, false)

    if update_name in overrides do
      ""
    else
      """
      def update_#{singular_lowercase}(%#{table_name}{} = #{singular_lowercase}, attrs) do
        #{if preload, do: "result = ", else: ""}
        #{singular_lowercase}
        |> #{table_name}.changeset(attrs)
        |> Repo.update(returning: true)
        #{if preload do
        """
        case result do
          {:ok, record} -> {:ok, Repo.preload(record, #{Macro.to_string(preload)})}
          error -> error
        end
        """
      else
        ""
      end}
      end
      """
    end
  end

  def generate_updatable(_, _, _), do: ""

  def generate_deletable(%{selectable: true, name: name}, overrides) do
    %{table_name: table_name, lower_case_table_name: lower_case_table_name} =
      get_table_names(name)

    singular_lowercase = PgGen.Utils.singularize(lower_case_table_name)
    delete_name = "delete_#{singular_lowercase}"

    if delete_name in overrides do
      ""
    else
      """
      def delete_#{singular_lowercase}(%#{table_name}{} = #{singular_lowercase}) do
        #{singular_lowercase}
        |> Repo.delete(stale_error_field: :__meta__, stale_error_message: "You don't have permission to delete this #{singular_lowercase}")
      end
      """
    end
  end

  def generate_deletable(_, _), do: ""

  def get_table_names(name) do
    %{
      table_name: name |> PgGen.Utils.singularize() |> Macro.camelize(),
      lower_case_table_name: String.downcase(name)
    }
  end

  def generate_custom_functions_returning_scalars_and_custom_records(
        functions,
        schema,
        module_name
      ) do
    function_strs =
      functions
      |> Enum.filter(fn
        %{return_type: %{type: %{name: type_name}}} when type_name in @scalar_types -> true
        %{return_type: %{composite_type: true}} -> true
        %{return_type: %{type: %{category: "E"}}} -> true
        _ -> false
      end)
      |> Enum.map(fn
        %{
          name: name,
          arg_names: arg_names,
          args: arg_types,
          args_with_default_count: args_with_default_count,
          return_type: %{type: %{name: return_type_name}} = return_type,
          returns_set: returns_set
        } ->
          # if a function has default arguments, we need to generate pattern
          # matches for empty arguments for all versions past the required
          # fields. If there are no default args, we'll only generate one
          # function/match
          0..args_with_default_count
          |> Enum.map(fn n ->
            # this is the range that we want to slice from the args list. E.g.,
            # if this is the first pass with a default arg, we want to build
            # the function  using all the args except for the last one. We pad
            # the function call with the :empty atom
            range_for_args = 0..(length(arg_names) - 1 - n)

            simple_args_str =
              arg_names
              |> Enum.slice(range_for_args)
              |> Enum.join(", ")

            simple_args_str =
              if n > 0 do
                empties = "#{0..n |> Enum.map(fn _ -> ', :empty' end) |> tl |> Enum.join(" ")}"
                simple_args_str <> empties
              else
                simple_args_str
              end

            args_str = generate_args_str(Enum.slice(arg_types, range_for_args))

            numbered_args =
              arg_names
              |> Enum.slice(range_for_args)
              |> Enum.with_index(1)
              |> Enum.map(fn {_, index} -> "$#{index}" end)
              |> Enum.join(", ")

            is_void_type = return_type_name == "void"

            return_match =
              cond do
                returns_set -> "result"
                is_void_type -> "[[_result]]"
                true -> "[[result]]"
              end

            result_str =
              get_result_str(return_type, returns_set, Enum.slice(arg_names, range_for_args))

            """

            def #{name}(#{simple_args_str}) do
              case Repo.query("select #{schema}.#{name}(#{numbered_args})", [#{args_str}]) do
                {:ok, %Postgrex.Result{ rows: #{return_match}}} ->
                  #{result_str}
                {:error, %Postgrex.Error{} = error} -> {:error, error.postgres}
                _ -> {:error, "Query failed"}
              end
            end
            """
          end)
          |> Enum.reverse()
          |> Enum.join("\n\n")
      end)

    """
    defmodule #{module_name}.Contexts.PgFunctions do
      import Ecto.Query, warn: false
      alias #{module_name}.Repo

      #{function_strs}

       def result_to_maps(%{columns: _, rows: nil}), do: []

       def result_to_maps(%{columns: col_nms, rows: rows, column_types: col_types}) do
         Enum.map(rows, fn [row] -> row_to_map(col_nms, Tuple.to_list(row), col_types) end)
       end

       def row_to_map(col_nms, vals, col_types) do
         Stream.zip(col_nms, vals)
         |> Enum.with_index(fn {k, v}, index ->
           v =
             if Enum.at(col_types, index) == "uuid" do
               Ecto.UUID.load!(v)
             else
               v
             end

           {String.to_existing_atom(k), v}
         end)
         |> Enum.into(%{})
       end

    end
    """
  end

  def custom_function_to_string(%{returns_set: false} = function, schema, preloads, _table),
    do: custom_function_returning_record_to_string(function, schema, preloads)

  def custom_function_to_string(%{returns_set: true} = function, schema, _preloads, table),
    do: custom_function_returning_set_to_string(function, schema, table)

  def custom_function_returning_set_to_string(
        %{
          name: name,
          return_type: %{type: %{name: type_name}},
          arg_names: arg_names,
          returns_set: true,
          args: arg_types
        } = _fun,
        schema,
        table
      ) do
    has_args = length(arg_names) > 0
    args = Enum.join(arg_names, ", ")

    pinned_args_string =
      generate_args_str(arg_types)
      |> String.split(", ")
      |> Enum.map(fn arg -> "^#{arg}" end)
      |> Enum.join(", ")

    repo_name = type_name |> PgGen.Utils.singularize() |> Macro.camelize()

    question_marks =
      arg_names
      |> Enum.map(fn _ -> "?" end)
      |> Enum.join(", ")

    if table.selectable do
      """
      def #{name}(#{if has_args, do: "#{args},"} args) do
        from(t in Repo.#{repo_name},
        join: s in fragment("select * from #{schema}.#{name}(#{question_marks})"#{if has_args, do: ", #{pinned_args_string}"}),
        on: s.id == t.id)
          |> Repo.Filter.apply(args)
          |> Repo.all()
      end
      """
    else
      simple_args_str = Enum.join(arg_names, ", ")
      args_str = generate_args_str(arg_types)

      repo_name = type_name |> PgGen.Utils.singularize() |> Macro.camelize()

      arg_positions =
        arg_names |> Enum.with_index(fn _, index -> "$#{index + 1}" end) |> Enum.join(", ")

      """
      def #{name}(#{simple_args_str}) do
        case Repo.query("select * from #{schema}.#{name}(#{arg_positions})", [#{args_str}]) do
          {:ok, result} ->
            Enum.map(result.rows, &Repo.load(#{repo_name}, {result.columns, &1}))

          {:error, reason} ->
            {:error, reason.postgres}
        end
      end
      """
    end
  end

  def custom_function_returning_record_to_string(
        %{
          name: name,
          return_type: %{type: %{name: type_name}},
          arg_names: arg_names,
          returns_set: false,
          args: arg_types,
          args_count: args_count,
          args_with_default_count: args_with_default_count
        },
        schema,
        preloads
      ) do
    strict_args_count = args_count - args_with_default_count
    optional_arg_names = Enum.slice(arg_names, strict_args_count..args_count)

    simple_args_str = Enum.join(arg_names, ", ")
    args_str = generate_args_str(arg_types, optional_arg_names)

    repo_name = type_name |> PgGen.Utils.singularize() |> Macro.camelize()

    preload = Map.get(preloads, name, false)
    preload_string = if preload, do: "|> Repo.preload(#{Macro.to_string(preload)})", else: ""

    """
    def #{name}(#{simple_args_str}) do
        #{if args_with_default_count == 0 do
      arg_positions = arg_names |> Enum.with_index(fn _, index -> "$#{index + 1}" end) |> Enum.join(", ")
      """
      case Repo.query("select * from #{schema}.#{name}(#{arg_positions})", [#{args_str}]) do
      """
    else
      arg_positions = arg_names |> Enum.with_index(fn _, index -> "\"$#{index + 1}\"" end) |> Enum.join(", ")
    
      """
        missing_field_count = [#{simple_args_str}]
          |> Enum.filter(fn val -> val == #{@optional_field_missing} end)
          |> length()
    
        case Repo.query("select * from #{schema}.#{name}(#\{Enum.slice([#{arg_positions}], 0..(#{args_count} - missing_field_count - 1)) |> Enum.join(", ")})", [#{args_str}]
        |> Enum.filter(fn val -> val != #{@optional_field_missing} end)) do
      """
    end}
        {:ok, result} ->
          Enum.map(result.rows, &Repo.load(#{repo_name}, {result.columns, &1})) |> List.first() #{preload_string}

        {:error, reason} ->
          {:error, reason.postgres}
      end
    end
    """
  end

  def custom_column_to_string(
        %{
          name: name,
          simplified_name: simplified_name,
          arg_names: arg_names,
          return_type: return_type,
          returns_set: returns_set
        },
        table,
        schema
      ) do
    arg_strs = Enum.join(arg_names, ", ")

    names = PgGen.Utils.get_table_names(table.name)

    cast_values = "#{names.singular_camelized_table_name}.to_pg_row(#{List.first(arg_names)})"

    result_str = get_result_str(return_type, returns_set, arg_names)

    return_match =
      cond do
        returns_set -> "result"
        true -> "[[result]]"
      end

    """
    def #{simplified_name}(#{arg_strs}) do
        case Repo.query(
        \"\"\"
        select #{schema}.#{name}($1)
        \"\"\",
        [
          #{cast_values}
        ]
      ) do
        {:ok, %Postgrex.Result{ rows: #{return_match}}} -> #{result_str}
        {:error, %Postgrex.Error{} = error} -> {:error, error.postgres}
        _ -> {:error, "Query failed"}
      end
    end
    """
  end

  defp generate_args_str(arg_types, optional_arg_names \\ []) do
    Enum.map(arg_types, fn
      %{type: %{name: "uuid"}, name: name} ->
        if name in optional_arg_names do
          "(if #{name} == #{@optional_field_missing}, do: #{name}, else: Ecto.UUID.dump!(#{name}))"
        else
          "Ecto.UUID.dump!(#{name})"
        end

      # if it's an array, will need to handle its contents
      # if it's a record, conevert it to a tuple
      %{type: %{array_type: %{category: "C", name: table_name}}, name: name} ->
        names = Utils.get_table_names(table_name)

        repo_name =
          PgGen.LocalConfig.get_app_name() <> ".Repo." <> names.singular_camelized_table_name

        if name in optional_arg_names do
          "(if #{name} == #{@optional_field_missing}, do: #{name}, else: Enum.map(#{name}, &#{repo_name}.to_pg_row/1))"
        else
          "Enum.map(#{name}, &#{repo_name}.to_pg_row/1)"
        end

      # if it's an array of UUIDs, run UUID.dump!
      %{type: %{array_type: %{name: "uuid"}}, name: name} ->
        if name in optional_arg_names do
          "(if #{name} == #{@optional_field_missing}, do: #{name}, else: Enum.map(#{name}, &Ecto.UUID.dump!/1))"
        else
          "Enum.map(#{name}, &Ecto.UUID.dump!/1)"
        end

      # if it's an enum, it comes in as an atom; postgrex will need a string
      %{type: %{category: "E"}, name: name} ->
        if name in optional_arg_names do
          "(if #{name} == #{@optional_field_missing}, do: #{name}, else: to_string(#{name}))"
        else
          "to_string(#{name})"
        end

      %{name: name} ->
        name
    end)
    |> Enum.join(", ")
  end

  defp get_result_str(return_type, returns_set, arg_names) do
    is_void_type = return_type.type.name == "void"
    is_enum_type = return_type.type.category == "E"

    cond do
      Map.get(return_type, :composite_type, false) ->
        keys =
          return_type.attrs
          |> Enum.map(fn %{name: name} -> "\"#{name}\"" end)
          |> Enum.join(", ")

        col_types =
          return_type.attrs
          |> Enum.map(fn %{type: %{name: name}} -> "\"#{name}\"" end)
          |> Enum.join(", ")

        """
        #{if returns_set, do: "%{ nodes: ", else: ""}
        result_to_maps(%{
          rows: result,
          columns: [#{keys}],
          column_types: [#{col_types}]
        })
        #{unless returns_set, do: "|> List.first()", else: ""}
        #{if returns_set, do: "}", else: ""}
        """

      returns_set && return_type.type.name == "uuid" ->
        "Enum.map(result, fn [binary] -> Ecto.UUID.load!(binary) end)"

      return_type.type.name == "uuid" ->
        "Ecto.UUID.load!(result)"

      is_enum_type ->
        "String.to_existing_atom(result)"

      is_void_type ->
        if length(arg_names) == 0 do
          "%{ success: true }"
        else
          arg_result = arg_names |> Enum.map(fn name -> "#{name}: #{name}" end) |> Enum.join(", ")
          "%{ success: true, #{arg_result} }"
        end

      true ->
        "result"
    end
  end

  def get_overrides(module_name) do
    extensions_module = Module.concat(Elixir, module_name)
    Utils.maybe_apply(extensions_module, :overrides, [], [])
  end

  def get_extensions(module_name) do
    extensions_module = Module.concat(Elixir, module_name)
    Utils.maybe_apply(extensions_module, :extensions, [], [])
  end

  def get_preloads(module_name) do
    extensions_module = Module.concat(Elixir, module_name)
    Utils.maybe_apply(extensions_module, :preloads, [], %{})
  end
end
