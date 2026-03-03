defmodule PyrolisConnector.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:pyrolis_connector, :web_port, 4100)

    children = [
      # Local state store (SQLite)
      PyrolisConnector.State,
      # Database connection manager (ODBC, MySQL, etc.)
      PyrolisConnector.DB,
      # Local web UI for setup and management
      {Bandit, plug: PyrolisConnector.Web.Router, port: port},
      # WebSocket relay to Pyrolis cloud
      PyrolisConnector.Relay
    ]

    opts = [strategy: :one_for_one, name: PyrolisConnector.Supervisor]
    {:ok, sup} = Supervisor.start_link(children, opts)

    Logger.info("Pyrolis Connector web UI available at http://localhost:#{port}")

    # Auto-open browser if not configured
    unless PyrolisConnector.Config.configured?() do
      Logger.info("Not configured — opening setup page in browser...")
      open_browser("http://localhost:#{port}/setup")
    end

    {:ok, sup}
  end

  defp open_browser(url) do
    # Best-effort, don't crash if it fails
    Task.start(fn ->
      Process.sleep(500)

      case :os.type() do
        {:win32, _} -> System.cmd("cmd", ["/c", "start", url], stderr_to_stdout: true)
        {:unix, :darwin} -> System.cmd("open", [url], stderr_to_stdout: true)
        {:unix, _} -> System.cmd("xdg-open", [url], stderr_to_stdout: true)
      end
    end)
  end
end
