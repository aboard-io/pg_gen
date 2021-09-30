defmodule PgGen.Codegen do
  @moduledoc """
  Creates the module strings to either write to file or to hot-load
  as code.
  """
  use GenServer
  alias PgGen.{Generator, HotModule}
  alias AbsintheGen.{SchemaGenerator}
  require Logger

  def start_link(args) when is_map(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(%{schema: schema}) do
    db_config = PgGen.LocalConfig.get_db()
    authenticator_db_config = PgGen.LocalConfig.get_authenticator_db() || db_config
    app_name = PgGen.LocalConfig.get_app_name()

    app = %{underscore: Macro.underscore(app_name), camelized: Macro.camelize(app_name)}

    Process.send_after(__MODULE__, :load_code, 100)
    Process.send_after(__MODULE__, :watch, 1)

    {:ok,
     build(%{
       schema: schema,
       db_config: db_config,
       authenticator_db_config: authenticator_db_config,
       app: app,
       debounce_ref: nil
     })}
  end

  def build(%{authenticator_db_config: authenticator_db_config, schema: schema, app: app} = state) do
    %{tables: tables, enum_types: enum_types, functions: functions} =
      Introspection.run(authenticator_db_config, String.split(schema, ","))
      |> Introspection.Model.from_introspection(schema)

    ecto = Generator.generate_ecto(tables, functions, schema, app)
    absinthe = Generator.generate_absinthe(tables, enum_types, functions, schema, app)

    state
    |> Map.merge(%{tables: tables, ecto: ecto, absinthe: absinthe, enum_types: enum_types})
  end

  def get_introspection do
    GenServer.call(__MODULE__, :get_introspection)
  end

  def generate_ecto do
    GenServer.call(__MODULE__, :generate_ecto)
  end

  def generate_absinthe do
  end

  def reload_code do
    GenServer.cast(__MODULE__, :reload_code_with_debounce)
  end

  @impl true
  def handle_call(:get_introspection, _from, %{tables: tables} = state) do
    {:reply, tables, state}
  end

  @impl true
  def handle_call(:generate_ecto, _from, %{tables: tables, schema: schema, functions: functions, app: app} = state) do
    ecto = Generator.generate_ecto(tables, functions, schema, app)

    {:reply, ecto, Map.put(state, :ecto, ecto)}
  end

  @impl true
  def handle_cast(
        :reload_code_with_debounce,
        %{debounce_ref: debounce_ref} = state
      ) do
    unless is_nil(debounce_ref) do
      Process.cancel_timer(debounce_ref)
    end

    # wait a bit to debounce db events
    debounce_ref = Process.send_after(__MODULE__, :reload_code, 25)

    {:noreply,
     state
     |> Map.put(:debounce_ref, debounce_ref)}
  end

  @impl true
  def handle_info(:watch, %{db_config: db_config} = state) do
    Introspection.install_watcher(db_config)

    # {:noreply, Map.put(state, :db_listen_ref, listen_ref)}
    {:noreply, state}
  end

  @impl true
  def handle_info(:load_code, state) do
    load_all_code(state)
    {:noreply, Map.put(state, :debounce_ref, nil)}
  end

  @impl true
  def handle_info(:reload_code, state) do
    new_state =
      state
      |> build
      |> load_all_code

    {:noreply, Map.put(new_state, :debounce_ref, nil)}
  end

  def handle_info(message, state) do
    IO.inspect(message)
    {:noreply, state}
  end

  defp load_all_code(
         %{
           ecto: %{repos: repos, contexts: contexts},
           app: app,
           absinthe: %{
             resolvers: resolvers,
             graphql_schema: graphql_schema,
             type_defs: type_defs,
             pg_function_resolver: pg_function_resolver
           }
         } = state
       ) do
    Logger.debug("Reloading code")
    repo_file_path = PgGen.LocalConfig.get_repo_path()
    contexts_file_path = PgGen.LocalConfig.get_contexts_path()

    HotModule.load(EctoGen.TableGenerator.dynamic_query_template(app.camelized),
      file_path: "#{contexts_file_path}/filter.ex"
    )

    HotModule.load(EctoGen.TableGenerator.ecto_json_type(),
      file_path: "#{repo_file_path}/ecto_json.ex"
    )

    repos
    |> Flow.from_enumerable()
    |> Flow.map(fn {name, code_str} ->
      HotModule.load(code_str, file_path: "#{repo_file_path}/#{name}.ex")
    end)
    |> Enum.to_list()

    contexts
    |> Flow.from_enumerable()
    |> Flow.map(fn {name, code_str} ->
      HotModule.load(code_str, file_path: "#{contexts_file_path}/#{name}.ex")
    end)
    |> Enum.to_list()

    graphql_schema_path = PgGen.LocalConfig.get_graphql_schema_path()
    types_path = graphql_schema_path <> "/types"

    web_module = "#{app.camelized}Web"

    HotModule.load(SchemaGenerator.changeset_errors_template(web_module),
      file_path: "#{graphql_schema_path}/changeset_errors.ex"
    )

    HotModule.load(SchemaGenerator.json_type(web_module <> ".Schema"),
      file_path: "#{types_path}/json.ex"
    )

    HotModule.load(SchemaGenerator.uuid_type(web_module <> ".Schema"),
      file_path: "#{types_path}/uuid4.ex"
    )

    HotModule.load(SchemaGenerator.cursor_type(web_module <> ".Schema"),
      file_path: "#{types_path}/cursor.ex"
    )

    HotModule.load(SchemaGenerator.uuid62_type(web_module <> ".Schema"),
      file_path: "#{types_path}/uuid62.ex"
    )

    type_defs
    |> Flow.from_enumerable()
    |> Flow.map(fn {name, code_str} ->
      HotModule.load(code_str, file_path: "#{types_path}/#{name}.ex")
    end)
    |> Enum.to_list()

    resolver_path = PgGen.LocalConfig.get_graphql_resolver_path()

    HotModule.load(AbsintheGen.SchemaGenerator.connections_resolver_template(web_module),
      file_path: "#{resolver_path}/connections.ex"
    )

    resolvers
    |> Flow.from_enumerable()
    |> Flow.map(fn {name, code_str} ->
      HotModule.load(code_str, file_path: "#{resolver_path}/#{name}.ex")
    end)
    |> Enum.to_list()

    HotModule.load(pg_function_resolver, file_path: "#{resolver_path}/pg_functions.ex")

    HotModule.load(graphql_schema, file_path: "#{graphql_schema_path}/schema.ex")
    HotModule.recompile()
    Logger.debug("Done reloading code")

    state
  end
end
