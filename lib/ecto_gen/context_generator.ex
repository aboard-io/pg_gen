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
    "int4",
    "enum",
    "void"
  ]

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
    app_module_name = Inflex.singularize(app_name) |> Macro.camelize()
    table_name = Inflex.singularize(name) |> Macro.camelize()

    function_strings_for_table =
      (functions.queries ++ functions.mutations)
      |> Enum.filter(fn
        %{return_type: %{type: %{name: ^name}}} -> true
        _ -> false
      end)
      |> Enum.map(&custom_function_to_string(&1, schema))
      |> Enum.join("\n")

    computed_columns =
      functions.computed_columns_by_table[name]
      |> Enum.map(&custom_column_to_string(&1, schema))

    has_custom_functions = String.trim(function_strings_for_table) != ""

    unless table.selectable || table.insertable || table.updatable || table.deletable ||
             has_custom_functions do
      # Logger.warn("This table is no good: #{table.name}")
      {name, nil}
    else
      module = """
      defmodule #{app_module_name}.Contexts.#{table_name} do

       import Ecto.Query, warn: false
       alias #{app_module_name}.Repo

       alias #{app_module_name}.Repo.#{table_name}

         #{generate_selectable(table)}
         #{generate_insertable(table)}
         #{generate_updatable(table)}
         #{generate_deletable(table)}
         #{function_strings_for_table}
         #{computed_columns}

        # dataloader
        def data() do
          Dataloader.Ecto.new(#{app_name}.Repo, query: &query/2)
        end

        def query(queryable, args) do
          queryable
          |> Repo.Filter.apply(args)
        end
      end
      """

      {name, Utils.format_code!(module)}
    end
  end

  def generate_selectable(%{selectable: true, name: name}) do
    %{table_name: table_name, lower_case_table_name: lower_case_table_name} =
      get_table_names(name)

    """
    def get_#{Inflex.singularize(lower_case_table_name)}!(id) do
      Repo.get!(#{table_name}, id)
    end

    def list_#{Inflex.pluralize(lower_case_table_name)}(args) do
      from(#{table_name})
      |> Repo.Filter.apply(args)
      |> Repo.all()
    end
    """
  end

  def generate_selectable(_), do: ""

  def generate_insertable(%{selectable: true, name: name}) do
    %{table_name: table_name, lower_case_table_name: lower_case_table_name} =
      get_table_names(name)

    singular_lowercase = Inflex.singularize(lower_case_table_name)

    """
    def create_#{singular_lowercase}(attrs) do
      %#{table_name}{}
      |> #{table_name}.changeset(attrs)
      |> Repo.insert(returning: true)
    end
    """
  end

  def generate_insertable(_), do: ""

  def generate_updatable(%{selectable: true, name: name}) do
    %{table_name: table_name, lower_case_table_name: lower_case_table_name} =
      get_table_names(name)

    singular_lowercase = Inflex.singularize(lower_case_table_name)

    """
    def update_#{singular_lowercase}(%#{table_name}{} = #{singular_lowercase}, attrs) do
      #{singular_lowercase}
      |> #{table_name}.changeset(attrs)
      |> Repo.update(returning: true)
    end

    """
  end

  def generate_updatable(_), do: ""

  def generate_deletable(%{selectable: true, name: name}) do
    %{table_name: table_name, lower_case_table_name: lower_case_table_name} =
      get_table_names(name)

    singular_lowercase = Inflex.singularize(lower_case_table_name)

    """
    def delete_#{singular_lowercase}(%#{table_name}{} = #{singular_lowercase}) do
      #{singular_lowercase}
      |> Repo.delete()
    end
    """
  end

  def generate_deletable(_), do: ""

  def get_table_names(name) do
    %{
      table_name: name |> Inflex.singularize() |> Macro.camelize(),
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
          return_type: %{type: %{name: return_type_name}} = return_type,
          returns_set: returns_set
        } ->
          simple_args_str =
            arg_names
            |> Enum.join(", ")

          args_str = generate_args_str(arg_types)

          numbered_args =
            arg_names
            |> Enum.with_index(1)
            |> Enum.map(fn {_, index} -> "$#{index}" end)
            |> Enum.join(", ")

          is_void_type = return_type_name == "void"
          is_enum_type = return_type.type.category == "E"

          return_match =
            cond do
              returns_set -> "result"
              is_void_type -> "[[_result]]"
              true -> "[[result]]"
            end

          result_str =
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
                #{unless returns_set, do: "|> hd", else: ""}
                #{if returns_set, do: "}", else: ""}
                """

              returns_set && return_type_name == "uuid" ->
                "Enum.map(result, fn [binary] -> Ecto.UUID.load!(binary) end)"

              return_type_name == "uuid" ->
                "Ecto.UUID.load!(result)"

              is_enum_type ->
                "String.to_existing_atom(result)"
              is_void_type ->
                "\"success\""

              true ->
                "result"
            end

          """

          def #{name}(#{simple_args_str}) do
            {:ok, %Postgrex.Result{ rows: #{return_match}}} =
              Repo.query("select #{schema}.#{name}(#{numbered_args})", [#{args_str}])
            #{result_str}
          end
          """
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

  def custom_function_to_string(%{returns_set: false} = function, schema),
    do: custom_function_returning_record_to_string(function, schema)

  def custom_function_to_string(%{returns_set: true} = function, schema),
    do: custom_function_returning_set_to_string(function, schema)

  def custom_function_returning_set_to_string(
        %{
          name: name,
          return_type: %{type: %{name: type_name}},
          arg_names: arg_names,
          returns_set: true
        },
        schema
      ) do
    has_args = length(arg_names) > 0
    args = Enum.join(arg_names, ", ")

    pinned_args =
      Enum.map(arg_names, fn name -> "^#{name}" end)
      |> Enum.join(", ")

    repo_name = type_name |> Inflex.singularize() |> Macro.camelize()

    question_marks =
      arg_names
      |> Enum.map(fn _ -> "?" end)
      |> Enum.join(", ")

    """
    def #{name}(#{if has_args, do: "#{args},"} args) do
      from(t in Repo.#{repo_name},
      join: s in fragment("select * from #{schema}.#{name}(#{question_marks})"#{if has_args, do: ", #{pinned_args}"}),
      on: s.id == t.id)
        |> Repo.Filter.apply(args)
        |> Repo.all()

    end
    """
  end

  def custom_function_returning_record_to_string(
        %{
          name: name,
          return_type: %{type: %{name: type_name}},
          arg_names: arg_names,
          returns_set: false,
          args: arg_types
        },
        schema
      ) do
    simple_args_str = Enum.join(arg_names, ", ")
    args_str = generate_args_str(arg_types)

    repo_name = type_name |> Inflex.singularize() |> Macro.camelize()

    arg_positions =
      arg_names
      |> Enum.with_index(fn _, index -> "$#{index + 1}" end)
      |> Enum.join(", ")

    """
    def #{name}(#{simple_args_str}) do
      result = Repo.query!("select * from #{schema}.#{name}(#{arg_positions})", [#{args_str}])
      Enum.map(result.rows, &Repo.load(#{repo_name}, {result.columns, &1})) |> hd
    end
    """
  end

  def custom_column_to_string(
        %{
          name: name,
          arg_names: arg_names,
          # returns_set: false,
          args: [%{name: type} | _]
        },
        schema
      ) do
    # arg_strs = Enum.join(arg_names, ", ")
    #
    # pinned_args =
    #   Enum.map(arg_names, fn name -> "^#{name}" end)
    #   |> Enum.join(", ")
    #
    # repo_name = type |> Inflex.singularize() |> Macro.camelize()
    #
    # question_marks =
    #   arg_names
    #   |> Enum.map(fn _ -> "?" end)
    #   |> Enum.join(", ")

    Logger.warn("Computed custom columns do not currently work")
    ""

    # """
    # def #{name}(#{arg_strs}) do
    #   from(t in Repo.#{repo_name},
    #   join: s in fragment("select * from #{schema}.#{name}(#{question_marks})", #{pinned_args}),
    #   on: s.id == t.id)
    # end
    # """
  end

  defp generate_args_str(arg_types) do
    Enum.map(arg_types, fn
      %{type: %{name: "uuid"}, name: name} -> "Ecto.UUID.dump!(#{name})"
      # if it's an enum, it comes in as an atom; postgrex will need a string
      %{type: %{category: "E"}, name: name} -> "to_string(#{name})"
      %{name: name} -> name
    end)
    |> Enum.join(", ")
  end
end
