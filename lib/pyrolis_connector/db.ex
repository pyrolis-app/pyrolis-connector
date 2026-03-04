defmodule PyrolisConnector.DB do
  @moduledoc """
  Database connection manager for multiple data sources.

  Manages connections to local databases (ODBC for HFSQL/SI2A, MyXQL for MySQL, etc.)
  and executes queries sent by the cloud. Only SELECT queries are allowed.

  Each data source is identified by name and has its own connection.
  """

  use GenServer

  require Logger

  @select_pattern ~r/\A\s*SELECT\b/i

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Execute a SQL query on the named data source.
  Returns `{:ok, columns, rows}` or `{:error, reason}`.
  Only SELECT queries are permitted.
  """
  def query(data_source_name, sql, params \\ []) do
    GenServer.call(__MODULE__, {:query, data_source_name, sql, params}, 120_000)
  end

  @doc "Check if a data source connection is alive."
  def connected?(data_source_name) do
    GenServer.call(__MODULE__, {:connected?, data_source_name})
  end

  @doc "List connected data sources."
  def list_connections do
    GenServer.call(__MODULE__, :list_connections)
  end

  @doc "Reconnect a data source."
  def reconnect(data_source_name) do
    GenServer.call(__MODULE__, {:reconnect, data_source_name}, 30_000)
  end

  # Server

  @impl true
  def init(_opts) do
    # Connections are established lazily on first query or explicitly via reconnect
    {:ok, %{connections: %{}}}
  end

  @impl true
  def handle_call({:query, ds_name, sql, params}, _from, state) do
    unless Regex.match?(@select_pattern, sql) do
      {:reply, {:error, "Only SELECT queries are allowed"}, state}
    else
      case ensure_connection(ds_name, state) do
        {:ok, conn_info, state} ->
          {result, state} = execute_query(ds_name, conn_info, sql, params, state)
          {:reply, result, state}

        {:error, reason, state} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_call({:connected?, ds_name}, _from, state) do
    {:reply, Map.has_key?(state.connections, ds_name), state}
  end

  @impl true
  def handle_call(:list_connections, _from, state) do
    names = Map.keys(state.connections)
    {:reply, {:ok, names}, state}
  end

  @impl true
  def handle_call({:reconnect, ds_name}, _from, state) do
    # Close existing connection if any
    state = close_connection(ds_name, state)

    case ensure_connection(ds_name, state) do
      {:ok, _conn_info, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  # Connection management

  defp ensure_connection(ds_name, state) do
    case Map.get(state.connections, ds_name) do
      nil ->
        # Load data source config and connect
        case PyrolisConnector.State.get_data_source(ds_name) do
          {:ok, ds} ->
            connect_data_source(ds_name, ds, state)

          {:error, :not_found} ->
            {:error, "Data source '#{ds_name}' not configured", state}
        end

      conn_info ->
        {:ok, conn_info, state}
    end
  end

  defp connect_data_source(ds_name, %{db_type: db_type, config: config}, state) do
    Logger.info("Connecting to data source '#{ds_name}' (#{db_type})")

    case do_connect(db_type, config) do
      {:ok, conn_info} ->
        Logger.info("Connected to data source '#{ds_name}'")
        state = put_in(state, [:connections, ds_name], conn_info)
        {:ok, conn_info, state}

      {:error, reason} ->
        Logger.error("Failed to connect to '#{ds_name}': #{inspect(reason)}")
        {:error, "Connection failed: #{inspect(reason)}", state}
    end
  end

  defp do_connect("odbc", config) do
    conn_string = build_odbc_connection_string(config)

    case :odbc.connect(String.to_charlist(conn_string), []) do
      {:ok, ref} ->
        {:ok, %{type: :odbc, ref: ref}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_connect("mock", config) do
    {:ok, %{type: :mock, config: config}}
  end

  defp do_connect("mysql", config) do
    opts = [
      hostname: Map.get(config, "host", "localhost"),
      port: to_integer(Map.get(config, "port", 3306)),
      database: Map.fetch!(config, "database"),
      username: Map.fetch!(config, "username"),
      password: Map.get(config, "password", "")
    ]

    case MyXQL.start_link(opts) do
      {:ok, pid} ->
        {:ok, %{type: :mysql, pid: pid}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_connect(type, _config) do
    {:error, "Unsupported database type: #{type}"}
  end

  defp close_connection(ds_name, state) do
    case Map.get(state.connections, ds_name) do
      %{type: :odbc, ref: ref} ->
        :odbc.disconnect(ref)

      %{type: :mysql, pid: pid} ->
        GenServer.stop(pid, :normal)

      %{type: :mock} ->
        :ok

      nil ->
        :ok
    end

    %{state | connections: Map.delete(state.connections, ds_name)}
  end

  # Query execution

  defp execute_query(_ds_name, %{type: :mock, config: config}, sql, _params, state) do
    {PyrolisConnector.MockData.query(sql, config), state}
  end

  defp execute_query(ds_name, %{type: :odbc, ref: ref}, sql, params, state) do
    result =
      try do
        # ODBC uses positional params with ? placeholders
        case params do
          [] ->
            case :odbc.sql_query(ref, String.to_charlist(sql)) do
              {:selected, columns, rows} ->
                columns = Enum.map(columns, &to_string/1)

                rows =
                  Enum.map(rows, fn row ->
                    Tuple.to_list(row) |> Enum.map(&decode_odbc_value/1)
                  end)

                {:ok, columns, rows}

              {:updated, _count} ->
                {:error, "Only SELECT queries are allowed"}

              {:error, reason} ->
                {:error, "ODBC error: #{inspect(reason)}"}
            end

          _params ->
            case :odbc.param_query(ref, String.to_charlist(sql), odbc_params(params)) do
              {:selected, columns, rows} ->
                columns = Enum.map(columns, &to_string/1)

                rows =
                  Enum.map(rows, fn row ->
                    Tuple.to_list(row) |> Enum.map(&decode_odbc_value/1)
                  end)

                {:ok, columns, rows}

              {:error, reason} ->
                {:error, "ODBC error: #{inspect(reason)}"}
            end
        end
      rescue
        e ->
          Logger.error("ODBC query failed on '#{ds_name}': #{Exception.message(e)}")
          # Reconnect on next query
          {:error, "Query failed: #{Exception.message(e)}"}
      end

    case result do
      {:error, _} = err ->
        # Remove stale connection so it reconnects next time
        {err, %{state | connections: Map.delete(state.connections, ds_name)}}

      ok ->
        {ok, state}
    end
  end

  defp execute_query(ds_name, %{type: :mysql, pid: pid}, sql, params, state) do
    case MyXQL.query(pid, sql, params) do
      {:ok, %MyXQL.Result{columns: columns, rows: rows}} ->
        {{:ok, columns, rows}, state}

      {:error, %MyXQL.Error{} = error} ->
        Logger.error("MySQL query failed on '#{ds_name}': #{Exception.message(error)}")
        {{:error, "MySQL error: #{Exception.message(error)}"}, state}
    end
  end

  # ODBC helpers

  defp build_odbc_connection_string(config) do
    cond do
      Map.has_key?(config, "connection_string") ->
        config["connection_string"]

      Map.has_key?(config, "dsn") ->
        parts = ["DSN=#{config["dsn"]}"]
        parts = if config["uid"], do: parts ++ ["UID=#{config["uid"]}"], else: parts
        parts = if config["pwd"], do: parts ++ ["PWD=#{config["pwd"]}"], else: parts
        Enum.join(parts, ";")

      true ->
        # Build from individual params
        config
        |> Enum.map(fn {k, v} -> "#{String.upcase(to_string(k))}=#{v}" end)
        |> Enum.join(";")
    end
  end

  defp odbc_params(params) do
    Enum.map(params, fn
      v when is_binary(v) -> {{:sql_varchar, String.length(v)}, [String.to_charlist(v)]}
      v when is_integer(v) -> {{:sql_integer, 0}, [v]}
      v when is_float(v) -> {{:sql_double, 0}, [v]}
      nil -> {{:sql_varchar, 0}, [:null]}
    end)
  end

  defp decode_odbc_value(:null), do: nil
  defp decode_odbc_value(v) when is_list(v), do: List.to_string(v)
  defp decode_odbc_value(v), do: v

  defp to_integer(v) when is_integer(v), do: v
  defp to_integer(v) when is_binary(v), do: String.to_integer(v)
end
