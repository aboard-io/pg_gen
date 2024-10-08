defmodule PgGen.MixProject do
  use Mix.Project

  def project do
    [
      app: :pg_gen,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
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
      # for code reloading
      {:phoenix, "~> 1.7.0"},
      {:neuron, "~> 5.1.0"},
      {:jason, "~> 1.2"},
      {:mix_test_watch, "~> 1.0", only: :dev, runtime: false},
      {:ex_unit_notifier, "~> 1.2", only: :test},
      {:inflex, github: "adampash/inflex", ref: "d44151a3f0c2decedcdf16d01a11d32d799819e1"},
      {:postgrex, ">= 0.0.0"},
      {:flow, "~> 1.0"},
      {:file_system, "~> 1.0"},
      {:absinthe, "~> 1.7.1"},
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
      # deps used by the generated code
      {:base62_uuid, "~> 2.0.0", github: "aboard-io/base62_uuid"},
      {:absinthe_error_payload, "~> 1.1"},
      {:decorator, "~> 1.4"}
    ]
  end
end
