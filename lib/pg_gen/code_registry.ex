defmodule PgGen.CodeRegistry do
  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    {:ok, %{}}
  end

  def is_stale(path, code_str) do
    GenServer.call(__MODULE__, {:is_stale, path, code_str})
  end

  @impl true
  def handle_call({:is_stale, path, code_str}, _, registry) do
    hash = hash_string(code_str)
    prev_hash = Map.get(registry, path, "")

    registry = Map.put(registry, path, hash)
    {:reply, prev_hash != hash, registry}
  end

  defp hash_string(str), do: :crypto.hash(:sha256, str) |> Base.encode16(case: :lower)
end
