defmodule Mom.MixProject do
  use Mix.Project

  def project do
    [
      app: :mom,
      version: "0.1.0",
      elixir: "~> 1.19.4",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: "Autonomous BEAM error monitor and fixer",
      source_url: "https://github.com/your-org/mom",
      package: package(),
      deps: deps(),
      releases: releases()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {Mom.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.2"},
      {:nimble_options, "~> 1.1"},
      {:bandit, "~> 1.6"},
      {:plug, "~> 1.16"},
      {:stream_data, "~> 0.6", only: :test}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # `MIX_ENV=prod mix release mom` builds the multi-target service
  # (docs/multi-target.md); config/runtime.exs reads its env vars.
  defp releases do
    [
      mom: [
        applications: [mom: :permanent],
        include_executables_for: [:unix]
      ]
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/your-org/mom"}
    ]
  end
end
