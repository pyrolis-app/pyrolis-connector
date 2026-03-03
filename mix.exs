defmodule PyrolisConnector.MixProject do
  use Mix.Project

  def project do
    [
      app: :pyrolis_connector,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :odbc],
      mod: {PyrolisConnector.Application, []}
    ]
  end

  defp deps do
    [
      # WebSocket client for Phoenix channels
      {:slipstream, "~> 1.1"},
      # HTTP client (for initial auth + self-update)
      {:req, "~> 0.5"},
      # JSON
      {:jason, "~> 1.4"},
      # SQLite for local state
      {:exqlite, "~> 0.27"},
      # DB drivers (optional — include what you need)
      {:myxql, "~> 0.7", optional: true},
      # Packaging
      {:burrito, "~> 1.0", only: :prod, runtime: false}
    ]
  end

  defp releases do
    [
      pyrolis_connector: [
        steps: if(Mix.env() == :prod, do: [:assemble, &Burrito.wrap/1], else: [:assemble]),
        burrito: [
          targets: [
            windows: [os: :windows, cpu: :x86_64],
            linux: [os: :linux, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end
end
