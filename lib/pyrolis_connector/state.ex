defmodule PyrolisConnector.State do
  @moduledoc """
  SQLite-backed local state management.

  Stores configuration, data source definitions, and sync run history.
  """

  use GenServer

  @table_sql """
  CREATE TABLE IF NOT EXISTS config (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
  );

  CREATE TABLE IF NOT EXISTS data_sources (
    name TEXT PRIMARY KEY,
    db_type TEXT NOT NULL,
    config_json TEXT NOT NULL,
    enabled INTEGER DEFAULT 1
  );

  CREATE TABLE IF NOT EXISTS sync_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    resource_type TEXT NOT NULL,
    data_source TEXT,
    started_at TEXT NOT NULL,
    completed_at TEXT,
    records_synced INTEGER DEFAULT 0,
    errors INTEGER DEFAULT 0,
    status TEXT DEFAULT 'running'
  );
  """

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def get_config do
    GenServer.call(__MODULE__, :get_config)
  end

  def save_config(config_map) when is_map(config_map) do
    GenServer.call(__MODULE__, {:save_config, config_map})
  end

  # Data source management

  def list_data_sources do
    GenServer.call(__MODULE__, :list_data_sources)
  end

  def get_data_source(name) do
    GenServer.call(__MODULE__, {:get_data_source, name})
  end

  def save_data_source(name, db_type, config_map, enabled \\ true) do
    GenServer.call(__MODULE__, {:save_data_source, name, db_type, config_map, enabled})
  end

  def delete_data_source(name) do
    GenServer.call(__MODULE__, {:delete_data_source, name})
  end

  # Sync run tracking

  def add_sync_run(resource_type, data_source \\ nil) do
    GenServer.call(__MODULE__, {:add_sync_run, resource_type, data_source})
  end

  def complete_sync_run(run_id, records_synced, errors) do
    GenServer.call(__MODULE__, {:complete_sync_run, run_id, records_synced, errors})
  end

  def get_sync_history(limit \\ 50) do
    GenServer.call(__MODULE__, {:get_sync_history, limit})
  end

  # Server

  @impl true
  def init(_) do
    db_path = Application.get_env(:pyrolis_connector, :state_db_path, "priv/state.db")
    File.mkdir_p!(Path.dirname(db_path))
    {:ok, conn} = Exqlite.Sqlite3.open(db_path)

    # Create tables
    for sql <- String.split(@table_sql, ";", trim: true) do
      :ok = Exqlite.Sqlite3.execute(conn, String.trim(sql))
    end

    {:ok, %{conn: conn}}
  end

  @impl true
  def handle_call(:get_config, _from, %{conn: conn} = state) do
    case query_all(conn, "SELECT key, value FROM config") do
      [] ->
        {:reply, {:error, :not_configured}, state}

      rows ->
        config_map =
          rows
          |> Enum.map(fn [key, value] -> {String.to_atom(key), value} end)
          |> Map.new()

        {:reply, {:ok, config_map}, state}
    end
  end

  @impl true
  def handle_call({:save_config, config_map}, _from, %{conn: conn} = state) do
    Enum.each(config_map, fn {key, value} ->
      when_not_nil(value, fn v ->
        execute(conn, "INSERT OR REPLACE INTO config (key, value) VALUES (?1, ?2)", [
          to_string(key),
          to_string(v)
        ])
      end)
    end)

    {:reply, :ok, state}
  end

  # Data sources

  @impl true
  def handle_call(:list_data_sources, _from, %{conn: conn} = state) do
    rows = query_all(conn, "SELECT name, db_type, config_json, enabled FROM data_sources")

    sources =
      Enum.map(rows, fn [name, db_type, config_json, enabled] ->
        %{
          name: name,
          db_type: db_type,
          config: Jason.decode!(config_json),
          enabled: enabled == 1
        }
      end)

    {:reply, {:ok, sources}, state}
  end

  @impl true
  def handle_call({:get_data_source, name}, _from, %{conn: conn} = state) do
    case query_all(
           conn,
           "SELECT name, db_type, config_json, enabled FROM data_sources WHERE name = ?1",
           [name]
         ) do
      [[name, db_type, config_json, enabled]] ->
        {:reply,
         {:ok,
          %{
            name: name,
            db_type: db_type,
            config: Jason.decode!(config_json),
            enabled: enabled == 1
          }}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(
        {:save_data_source, name, db_type, config_map, enabled},
        _from,
        %{conn: conn} = state
      ) do
    config_json = Jason.encode!(config_map)

    execute(
      conn,
      "INSERT OR REPLACE INTO data_sources (name, db_type, config_json, enabled) VALUES (?1, ?2, ?3, ?4)",
      [name, to_string(db_type), config_json, if(enabled, do: 1, else: 0)]
    )

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:delete_data_source, name}, _from, %{conn: conn} = state) do
    execute(conn, "DELETE FROM data_sources WHERE name = ?1", [name])
    {:reply, :ok, state}
  end

  # Sync runs

  @impl true
  def handle_call({:add_sync_run, resource_type, data_source}, _from, %{conn: conn} = state) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    execute(
      conn,
      "INSERT INTO sync_runs (resource_type, data_source, started_at, status) VALUES (?1, ?2, ?3, 'running')",
      [to_string(resource_type), data_source, now]
    )

    {:ok, last_id} = query_one(conn, "SELECT last_insert_rowid()")
    {:reply, {:ok, last_id}, state}
  end

  @impl true
  def handle_call({:complete_sync_run, run_id, records, errors}, _from, %{conn: conn} = state) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    status = if errors > 0, do: "completed_with_errors", else: "completed"

    execute(
      conn,
      "UPDATE sync_runs SET completed_at = ?1, records_synced = ?2, errors = ?3, status = ?4 WHERE id = ?5",
      [now, records, errors, status, run_id]
    )

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get_sync_history, limit}, _from, %{conn: conn} = state) do
    rows =
      query_all(
        conn,
        "SELECT id, resource_type, data_source, started_at, completed_at, records_synced, errors, status FROM sync_runs ORDER BY id DESC LIMIT ?1",
        [limit]
      )

    history =
      Enum.map(rows, fn [id, type, ds, started, completed, records, errors, status] ->
        %{
          id: id,
          resource_type: type,
          data_source: ds,
          started_at: started,
          completed_at: completed,
          records_synced: records,
          errors: errors,
          status: status
        }
      end)

    {:reply, {:ok, history}, state}
  end

  # Helpers

  defp execute(conn, sql, params) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
    :ok = Exqlite.Sqlite3.bind(stmt, params)
    :done = Exqlite.Sqlite3.step(conn, stmt)
    :ok = Exqlite.Sqlite3.release(conn, stmt)
    :ok
  end

  defp query_all(conn, sql, params \\ []) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
    :ok = Exqlite.Sqlite3.bind(stmt, params)

    rows = collect_rows(conn, stmt, [])
    :ok = Exqlite.Sqlite3.release(conn, stmt)
    rows
  end

  defp query_one(conn, sql) do
    case query_all(conn, sql) do
      [[val] | _] -> {:ok, val}
      _ -> {:error, :not_found}
    end
  end

  defp collect_rows(conn, stmt, acc) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, row} -> collect_rows(conn, stmt, acc ++ [row])
      :done -> acc
    end
  end

  defp when_not_nil(nil, _fun), do: :ok
  defp when_not_nil(val, fun), do: fun.(val)
end
