defmodule PyrolisConnector.Relay do
  @moduledoc """
  WebSocket relay client that connects to the Pyrolis cloud.

  Maintains a persistent WebSocket connection via Slipstream (Phoenix Channels).
  Receives SQL query commands from the cloud orchestrator, executes them on
  the local database via `PyrolisConnector.DB`, and streams results back.

  ## Protocol

  ### Incoming (Cloud → Connector)

    - `"query"` — Execute SQL on a local data source
      `%{request_id, sql, params, resource_type, data_source}`

    - `"update_available"` — New binary version available
      `%{version, download_url, checksum}`

    - `"restart"` — Restart the connector process
      `%{}`

    - `"ping"` — Ping the connector, expects a `"pong"` reply
      `%{}`

    - `"enable_logs"` — Start streaming logs to cloud
      `%{}`

    - `"disable_logs"` — Stop streaming logs to cloud
      `%{}`

  ### Outgoing (Connector → Cloud)

    - `"rows"` — Streamed query results (batched)
      `%{request_id, rows, done}`

    - `"query_error"` — Query execution failed
      `%{request_id, error}`

    - `"heartbeat"` — Periodic health report
      `%{version, uptime_seconds, db_connected}`

    - `"status"` — Data source status report
      `%{data_sources: [%{name, db_type, connected}]}`
  """

  use Slipstream

  require Logger

  @version Mix.Project.config()[:version]
  @heartbeat_interval_ms 30_000
  @row_batch_size 500
  @max_recent 20

  # Client API

  def start_link(opts) do
    Slipstream.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the current relay status as a map."
  def status do
    case Process.whereis(__MODULE__) do
      nil ->
        %{
          connection_status: :stopped,
          channel_joined: false,
          last_heartbeat_at: nil,
          commands_received: 0,
          recent_commands: [],
          recent_errors: [],
          started_at: nil
        }

      pid ->
        try do
          GenServer.call(pid, :get_status, 5_000)
        catch
          :exit, _ ->
            %{
              connection_status: :stopped,
              channel_joined: false,
              last_heartbeat_at: nil,
              commands_received: 0,
              recent_commands: [],
              recent_errors: [],
              started_at: nil
            }
        end
    end
  end

  @doc "Force the relay to reconnect to the cloud."
  def reconnect_relay do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_running}
      pid -> send(pid, :force_reconnect) && :ok
    end
  end

  @doc "Push log entries to the cloud."
  def push_logs(entries) when is_list(entries) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> send(pid, {:push_logs, entries})
    end

    :ok
  end

  @doc "Push updated data source status to the cloud."
  def report_status do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_running}
      pid -> send(pid, :report_status) && :ok
    end
  end

  # Slipstream callbacks

  @impl Slipstream
  def init(_opts) do
    case PyrolisConnector.Config.load() do
      {:ok, config} ->
        Logger.info("Connecting to #{config.url} as connector #{config.connector_id}")

        ws_url = PyrolisConnector.Config.ws_url(config)

        socket =
          new_socket()
          |> assign(:config, config)
          |> assign(:started_at, System.monotonic_time(:second))
          |> assign(:connection_status, :connecting)
          |> assign(:channel_joined, false)
          |> assign(:last_heartbeat_at, nil)
          |> assign(:commands_received, 0)
          |> assign(:recent_commands, [])
          |> assign(:recent_errors, [])

        {:ok, connect!(socket, uri: ws_url)}

      {:error, :not_configured} ->
        # Don't log a scary warning — the Application module prints the setup URL
        socket =
          new_socket()
          |> assign(:config, nil)
          |> assign(:started_at, System.monotonic_time(:second))
          |> assign(:connection_status, :not_configured)
          |> assign(:channel_joined, false)
          |> assign(:last_heartbeat_at, nil)
          |> assign(:commands_received, 0)
          |> assign(:recent_commands, [])
          |> assign(:recent_errors, [])

        {:ok, socket}
    end
  end

  @impl Slipstream
  def handle_connect(socket) do
    config = socket.assigns.config
    topic = "connector:#{config.connector_id}"
    Logger.info("WebSocket connected, joining #{topic}")
    {:ok, socket |> assign(:connection_status, :connected) |> join(topic)}
  end

  @impl Slipstream
  def handle_join(topic, _response, socket) do
    Logger.info("Joined #{topic}")

    # Start heartbeat timer
    Process.send_after(self(), :heartbeat, @heartbeat_interval_ms)

    # Report data source status
    send(self(), :report_status)

    {:ok, assign(socket, :channel_joined, true)}
  end

  @impl Slipstream
  def handle_message(_topic, "query", payload, socket) do
    # Track command
    command_entry = %{
      request_id: payload["request_id"],
      data_source: payload["data_source"],
      sql: String.slice(payload["sql"] || "", 0, 120),
      timestamp: DateTime.utc_now()
    }

    recent = Enum.take([command_entry | socket.assigns.recent_commands], @max_recent)
    relay_pid = self()

    # Execute query in a Task to avoid blocking the WebSocket
    Task.start(fn -> handle_query(payload, socket, relay_pid) end)

    {:ok,
     socket
     |> assign(:commands_received, socket.assigns.commands_received + 1)
     |> assign(:recent_commands, recent)}
  end

  @impl Slipstream
  def handle_message(_topic, "update_available", payload, socket) do
    if PyrolisConnector.Updater.remote_updates_allowed?() do
      Logger.info("Update available: v#{payload["version"]}")

      # Pick platform-specific asset if available, fall back to generic URL
      {download_url, checksum} =
        case get_in(payload, ["platform_assets", PyrolisConnector.Updater.platform_target()]) do
          %{"download_url" => url, "checksum" => cs} -> {url, cs}
          _ -> {payload["download_url"], payload["checksum"]}
        end

      PyrolisConnector.Updater.notify_available(
        payload["version"],
        download_url,
        checksum
      )
    else
      Logger.info("Ignoring remote update push (remote updates disabled)")
    end

    {:ok, socket}
  end

  @impl Slipstream
  def handle_message(_topic, "enable_logs", _payload, socket) do
    Logger.info("Log streaming enabled by cloud")
    PyrolisConnector.LogForwarder.enable()
    {:ok, socket}
  end

  @impl Slipstream
  def handle_message(_topic, "disable_logs", _payload, socket) do
    Logger.info("Log streaming disabled by cloud")
    PyrolisConnector.LogForwarder.disable()
    {:ok, socket}
  end

  @impl Slipstream
  def handle_message(topic, "ping", _payload, socket) do
    Logger.debug("Ping received from cloud")
    push(socket, topic, "pong", %{version: @version, timestamp: DateTime.utc_now()})
    {:ok, socket}
  end

  @impl Slipstream
  def handle_message(_topic, "restart", _payload, socket) do
    Logger.info("Restart command received from cloud")

    Task.start(fn ->
      Process.sleep(1_000)
      System.restart()
    end)

    {:ok, socket}
  end

  @impl Slipstream
  def handle_message(topic, event, payload, socket) do
    Logger.debug("Unhandled message on #{topic}: #{event} #{inspect(payload)}")
    {:ok, socket}
  end

  @impl Slipstream
  def handle_reply(_ref, _reply, socket) do
    {:ok, socket}
  end

  @impl Slipstream
  def handle_disconnect(_reason, socket) do
    if socket.assigns[:config] do
      Logger.warning("Disconnected from cloud, reconnecting...")

      socket
      |> assign(:connection_status, :reconnecting)
      |> assign(:channel_joined, false)
      |> reconnect()
    else
      {:ok, socket}
    end
  end

  @impl Slipstream
  def handle_topic_close(topic, reason, socket) do
    Logger.warning("Channel #{topic} closed: #{inspect(reason)}, rejoining...")
    {:ok, socket |> assign(:channel_joined, false) |> rejoin(topic)}
  end

  # GenServer callbacks

  @impl Slipstream
  def handle_call(:get_status, _from, socket) do
    status_map = %{
      connection_status: socket.assigns[:connection_status] || :stopped,
      channel_joined: socket.assigns[:channel_joined] || false,
      last_heartbeat_at: socket.assigns[:last_heartbeat_at],
      commands_received: socket.assigns[:commands_received] || 0,
      recent_commands: socket.assigns[:recent_commands] || [],
      recent_errors: socket.assigns[:recent_errors] || [],
      started_at: socket.assigns[:started_at]
    }

    {:reply, status_map, socket}
  end

  # GenServer callbacks for timers

  @impl Slipstream
  def handle_info(:heartbeat, socket) do
    if socket.assigns[:config] do
      topic = "connector:#{socket.assigns.config.connector_id}"
      uptime = System.monotonic_time(:second) - socket.assigns.started_at

      {:ok, connections} = PyrolisConnector.DB.list_connections()

      push(socket, topic, "heartbeat", %{
        version: @version,
        uptime_seconds: uptime,
        db_connected: length(connections) > 0
      })

      Process.send_after(self(), :heartbeat, @heartbeat_interval_ms)

      {:noreply, assign(socket, :last_heartbeat_at, DateTime.utc_now())}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:push_logs, entries}, socket) do
    if socket.assigns[:config] && socket.assigns[:channel_joined] do
      topic = "connector:#{socket.assigns.config.connector_id}"
      push(socket, topic, "logs", %{entries: entries})
    end

    {:noreply, socket}
  end

  def handle_info(:report_status, socket) do
    if socket.assigns[:config] do
      topic = "connector:#{socket.assigns.config.connector_id}"

      {:ok, sources} = PyrolisConnector.State.list_data_sources()

      data_sources =
        Enum.map(sources, fn ds ->
          %{
            name: ds.name,
            db_type: ds.db_type,
            connected: PyrolisConnector.DB.connected?(ds.name),
            enabled: ds.enabled
          }
        end)

      push(socket, topic, "status", %{data_sources: data_sources})
    end

    {:noreply, socket}
  end

  def handle_info(:force_reconnect, socket) do
    Logger.info("Force reconnect requested, reloading config from disk")

    case PyrolisConnector.Config.load() do
      {:ok, config} ->
        ws_url = PyrolisConnector.Config.ws_url(config)

        socket =
          socket
          |> assign(:config, config)
          |> assign(:connection_status, :connecting)
          |> assign(:channel_joined, false)

        # disconnect existing connection if any, then connect with new config
        socket =
          if socket.assigns[:connection_status] not in [:not_configured, nil] do
            case disconnect(socket) do
              {:ok, s} -> s
              _ -> socket
            end
          else
            socket
          end

        {:noreply, connect!(socket, uri: ws_url)}

      {:error, :not_configured} ->
        Logger.warning("Force reconnect failed: no config saved yet")
        {:noreply, socket}
    end
  end

  def handle_info({:track_error, error_entry}, socket) do
    recent = Enum.take([error_entry | socket.assigns.recent_errors], @max_recent)
    {:noreply, assign(socket, :recent_errors, recent)}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # Query execution (runs in a Task)

  defp handle_query(payload, socket, relay_pid) do
    %{
      "request_id" => request_id,
      "sql" => sql,
      "data_source" => data_source_name
    } = payload

    params = Map.get(payload, "params", [])
    topic = "connector:#{socket.assigns.config.connector_id}"

    Logger.info("Executing query #{request_id} on data source '#{data_source_name}'")

    case PyrolisConnector.DB.query(data_source_name, sql, params) do
      {:ok, columns, rows} ->
        stream_rows(socket, topic, request_id, columns, rows)

      {:error, reason} ->
        Logger.error("Query #{request_id} failed: #{reason}")
        push(socket, topic, "query_error", %{request_id: request_id, error: reason})

        send(
          relay_pid,
          {:track_error,
           %{
             request_id: request_id,
             error: to_string(reason),
             timestamp: DateTime.utc_now()
           }}
        )
    end
  end

  defp stream_rows(socket, topic, request_id, columns, rows) do
    total = length(rows)

    if total == 0 do
      push(socket, topic, "rows", %{
        request_id: request_id,
        rows: [],
        done: true
      })
    else
      rows
      |> Enum.chunk_every(@row_batch_size)
      |> Enum.with_index()
      |> Enum.each(fn {batch, idx} ->
        # Convert rows from lists to maps using column names
        row_maps = Enum.map(batch, fn row -> Enum.zip(columns, row) |> Map.new() end)

        is_last = (idx + 1) * @row_batch_size >= total

        push(socket, topic, "rows", %{
          request_id: request_id,
          rows: row_maps,
          done: is_last
        })
      end)
    end

    Logger.info("Query #{request_id}: streamed #{total} rows")
  end
end
