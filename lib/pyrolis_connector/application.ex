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

    IO.puts("""

    =============================================
      Pyrolis Connector v#{PyrolisConnector.version()}
      Web UI: http://localhost:#{port}
    =============================================
    """)

    # Auto-import config.json if present and not yet configured
    unless PyrolisConnector.Config.configured?() do
      case import_config_json() do
        :ok ->
          IO.puts("  Configuration imported from config.json\n")

        :not_found ->
          IO.puts("  Not configured — opening setup in browser...\n")
          open_browser("http://localhost:#{port}/setup")
      end
    end

    {:ok, sup}
  end

  defp import_config_json do
    # Look for config.json next to the binary, or in the current directory
    paths = [
      config_json_path(),
      Path.join(File.cwd!(), "config.json")
    ]
    |> Enum.uniq()

    case Enum.find(paths, &File.exists?/1) do
      nil ->
        :not_found

      path ->
        Logger.info("Found config.json at #{path}")

        case File.read(path) |> then(fn {:ok, data} -> Jason.decode(data); e -> e end) do
          {:ok, data} ->
            config = %PyrolisConnector.Config{
              url: data["url"],
              api_key: data["api_key"],
              connector_id: data["connector_id"]
            }

            PyrolisConnector.Config.save(config)

            # Import data sources if present
            for ds <- Map.get(data, "data_sources", []) do
              PyrolisConnector.State.save_data_source(
                ds["name"],
                ds["db_type"],
                ds["config"] || %{}
              )
            end

            :ok

          {:error, reason} ->
            Logger.warning("Failed to parse config.json: #{inspect(reason)}")
            :not_found
        end
    end
  end

  defp config_json_path do
    case Burrito.Util.Args.get_bin_path() do
      :not_in_burrito ->
        Path.join(File.cwd!(), "config.json")

      bin_path ->
        bin_path |> Path.dirname() |> Path.join("config.json")
    end
  end

  defp open_browser(url) do
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
