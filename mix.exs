defmodule PyrolisConnector.MixProject do
  use Mix.Project

  @version (
             # In CI, GITHUB_REF_NAME is the tag (e.g. pyrolis-connector-v0.3.0)
             ci_tag = System.get_env("GITHUB_REF_NAME", "")

             cond do
               String.starts_with?(ci_tag, "pyrolis-connector-v") ->
                 String.replace(ci_tag, "pyrolis-connector-v", "")

               true ->
                 case System.cmd("git", ["describe", "--tags", "--match",
                        "pyrolis-connector-v*", "--always"],
                        stderr_to_stdout: true) do
                   {desc, 0} ->
                     desc
                     |> String.trim()
                     |> String.replace(~r/^pyrolis-connector-v/, "")

                   _ ->
                     "0.0.0-dev"
                 end
             end
           )

  def project do
    [
      app: :pyrolis_connector,
      version: @version,
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
      # CA certificates (needed for TLS on Windows/Burrito)
      {:castore, "~> 1.0"},
      # JSON
      {:jason, "~> 1.4"},
      # i18n
      {:gettext, "~> 0.26"},
      # SQLite for local state
      {:exqlite, "~> 0.27"},
      # Local web UI for setup/management
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.6"},
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
