defmodule PgGen.Supervisor do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    schema = Keyword.get(opts, :schema, "app_public")
    output_path = Keyword.get(opts, :output_path, "./schema.graphql")

    children = [
      # Starts a worker by calling: AppWithSup.Worker.start_link(arg)
      # {AppWithSup.Worker, arg}
      PgGen.CodeRegistry,
      PgGen.Notifications,
      {PgGen.Codegen, %{schema: schema, output_path: output_path}},
      PgGen.FileWatcher,
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    Supervisor.init(children, strategy: :one_for_one)
  end
end
