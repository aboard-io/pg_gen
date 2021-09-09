defmodule PgGen.MixProject do
  use Mix.Project

  def project do
    [
      app: :pg_gen,
      version: "0.1.0",
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      xref: [exclude: [Phoenix.CodeReloader]]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:neuron, "~> 5.0.0"},
      {:jason, "~> 1.2"},
      {:mix_test_watch, "~> 1.0", only: :dev, runtime: false},
      {:ex_unit_notifier, "~> 1.2", only: :test},
      {:inflex, "~> 2.0.0"},
      {:postgrex, "~> 0.15.10"},
      {:flow, "~> 1.0"},
      {:file_system, "~> 0.2.10"},
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
      # deps used by the generated code
      {:dataloader, "~> 1.0.0"},
      {:base62_uuid, "~> 2.0.0"},
      {:absinthe_error_payload, "~> 1.1"}
    ]
  end
end
