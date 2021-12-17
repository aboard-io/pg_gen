defmodule PgGen.FileWatcher do
  alias PgGen.LocalConfig
  use GenServer
  require Logger

  def start_link(_) do
    GenServer.start_link(__MODULE__, [])
  end

  @impl true
  def init([]) do
    {:ok, watcher_pid} = FileSystem.start_link(dirs: get_paths_as_list(), name: __MODULE__)
    FileSystem.subscribe(__MODULE__)
    {:ok, %{watcher_pid: watcher_pid}}
  end

  def get_paths(app_name \\ nil) do
    module_name = app_name || LocalConfig.get_app_name() |> Macro.underscore()
    module_name_web = module_name <> "_web"

    %{
      contexts: "lib/#{module_name}/contexts",
      repo: "lib/#{module_name}/repo",
      resolvers: "lib/#{module_name_web}/schema/resolvers",
      types: "lib/#{module_name_web}/schema/types",
      schema: "lib/#{module_name_web}/schema"
    }
  end

  def get_paths_as_list do
    get_paths()
    |> Enum.map(fn {_, v} -> v end)
  end

  @impl true
  def handle_info(
        {:file_event, _watcher_pid, {_path, [:renamed]}},
        state
      ) do
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:file_event, watcher_pid, {path, _events}},
        %{watcher_pid: watcher_pid} = state
      ) do
      if String.match?(path, ~r/\.exs?$/) && File.exists?(path) do
        data = File.read!(path)
        is_script = String.match?(path, ~r/\.exs$/)
        is_extension = String.match?(path, ~r/extend\.ex$/)

        is_stale = PgGen.CodeRegistry.is_stale(path, data)

        if is_stale && !is_script && is_extension do
          Logger.debug("The file has changed: #{path}")
          Code.compile_file(path)
          PgGen.Codegen.reload_code()
        end
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:file_event, watcher_pid, :stop}, %{watcher_pid: watcher_pid} = state) do
    # what to do if the monitor stops..?
    {:noreply, state}
  end
end
