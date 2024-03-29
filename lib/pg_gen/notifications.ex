defmodule PgGen.Notifications do
  @moduledoc false
  require Logger

  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, [])
  end

  @impl true
  def init([]) do
    channel = "postgraphile_watch"

    db_config =
      PgGen.LocalConfig.get_db()
      |> Enum.map(& &1)

    {:ok, pid} = Postgrex.Notifications.start_link(db_config)
    {:ok, ref} = Postgrex.Notifications.listen(pid, channel)
    Logger.info("Listening for database changes")
    schedule_reconnect()
    {:ok, {pid, channel, ref}}
  end

  @impl true
  def handle_info({:notification, _pid, _ref, _channel, payload}, state) do
    case Jason.decode!(payload) do
      %{"payload" => nil} -> nil
      _payload -> 
        # IO.inspect(payload, label: "Payload")
        PgGen.Codegen.reload_code()
    end

    {:noreply, state}
  end

  def handle_info(:reconnect, {pid, channel, ref}) do
    {:ok, ref} =
      if pid do
        Postgrex.Notifications.unlisten(pid, ref)
        Postgrex.Notifications.listen(pid, channel)
      end

    schedule_reconnect()
    {:noreply, {pid, channel, ref}}
  end

  @impl true
  def handle_info(_event, state) do
    Logger.warning("!!! Notifications.handle_info something strange shows up")

    {:noreply, state}
  end

  def schedule_reconnect() do
    Process.send_after(self(), :reconnect, 5 * 60 * 1000)
  end
end
