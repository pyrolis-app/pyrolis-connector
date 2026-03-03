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

  # Client API

  def start_link(opts) do
    Slipstream.start_link(__MODULE__, opts, name: __MODULE__)
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

        {:ok, connect!(socket, uri: ws_url)}

      {:error, :not_configured} ->
        # Don't log a scary warning — the Application module prints the setup URL
        {:ok, new_socket() |> assign(:config, nil)}
    end
  end

  @impl Slipstream
  def handle_connect(socket) do
    config = socket.assigns.config
    topic = "connector:#{config.connector_id}"
    Logger.info("WebSocket connected, joining #{topic}")
    {:ok, join(socket, topic)}
  end

  @impl Slipstream
  def handle_join(topic, _response, socket) do
    Logger.info("Joined #{topic}")

    # Start heartbeat timer
    Process.send_after(self(), :heartbeat, @heartbeat_interval_ms)

    # Report data source status
    send(self(), :report_status)

    {:ok, socket}
  end

  @impl Slipstream
  def handle_message(_topic, "query", payload, socket) do
    # Execute query in a Task to avoid blocking the WebSocket
    Task.start(fn -> handle_query(payload, socket) end)
    {:ok, socket}
  end

  @impl Slipstream
  def handle_message(_topic, "update_available", payload, socket) do
    Logger.info("Update available: v#{payload["version"]}")
    # TODO: Implement self-update via PyrolisConnector.Updater
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
      {:ok, reconnect(socket)}
    else
      {:ok, socket}
    end
  end

  @impl Slipstream
  def handle_topic_close(topic, reason, socket) do
    Logger.warning("Channel #{topic} closed: #{inspect(reason)}, rejoining...")
    {:ok, rejoin(socket, topic)}
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

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # Query execution (runs in a Task)

  defp handle_query(payload, socket) do
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
