defmodule PyrolisConnector.Web.Router do
  @moduledoc """
  Local web UI for connector setup and management.

  Runs on localhost — provides forms for:
  - Cloud connection setup (URL, API key, tenant)
  - Data source management (ODBC/MySQL connections)
  - Status overview and sync history
  - Debug page with recent commands and errors
  """

  use Plug.Router
  use Gettext, backend: PyrolisConnector.Gettext

  plug(:set_locale)

  plug(Plug.Parsers,
    parsers: [:urlencoded],
    pass: ["text/html"]
  )

  plug(:match)
  plug(:dispatch)

  # ── Locale ──

  defp set_locale(conn, _opts) do
    locale =
      case Plug.Conn.get_req_header(conn, "accept-language") do
        [accept | _] -> parse_locale(accept)
        _ -> "en"
      end

    Gettext.put_locale(PyrolisConnector.Gettext, locale)
    conn
  end

  defp parse_locale(accept_language) do
    accept_language
    |> String.split(",")
    |> Enum.map(fn part ->
      part |> String.split(";") |> hd() |> String.trim() |> String.downcase()
    end)
    |> Enum.find_value("en", fn
      "fr" <> _ -> "fr"
      "en" <> _ -> "en"
      _ -> nil
    end)
  end

  # ── Pages ──

  get "/" do
    config = load_config()
    {:ok, sources} = PyrolisConnector.State.list_data_sources()
    {:ok, history} = PyrolisConnector.State.get_sync_history(10)
    relay_status = PyrolisConnector.Relay.status()

    html =
      render_page(
        gettext("Dashboard"),
        "/",
        dashboard_html(config, sources, history, relay_status)
      )

    send_resp(conn, 200, html)
  end

  get "/setup" do
    config = load_config()
    html = render_page(gettext("Setup"), "/setup", setup_html(config))
    send_resp(conn, 200, html)
  end

  post "/setup" do
    config = %PyrolisConnector.Config{
      url: String.trim(conn.params["url"]),
      api_key: String.trim(conn.params["api_key"]),
      connector_id: String.trim(conn.params["connector_id"])
    }

    PyrolisConnector.Config.save(config)

    conn
    |> put_resp_header("location", "/?saved=cloud")
    |> send_resp(302, "")
  end

  get "/sources/new" do
    html = render_page(gettext("Add Data Source"), "/sources/new", source_form_html(nil))
    send_resp(conn, 200, html)
  end

  post "/sources" do
    name = String.trim(conn.params["name"])
    db_type = String.trim(conn.params["db_type"])

    config =
      case db_type do
        "odbc" ->
          %{"dsn" => conn.params["dsn"], "uid" => conn.params["uid"], "pwd" => conn.params["pwd"]}
          |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" end)
          |> Map.new()

        "mysql" ->
          %{
            "host" => conn.params["host"] || "localhost",
            "port" => conn.params["port"] || "3306",
            "database" => conn.params["database"],
            "username" => conn.params["username"] || "root",
            "password" => conn.params["password"] || ""
          }

        _ ->
          %{}
      end

    PyrolisConnector.State.save_data_source(name, db_type, config)

    conn
    |> put_resp_header("location", "/?saved=source")
    |> send_resp(302, "")
  end

  post "/sources/delete" do
    name = conn.params["name"]
    PyrolisConnector.State.delete_data_source(name)

    conn
    |> put_resp_header("location", "/")
    |> send_resp(302, "")
  end

  post "/test-source" do
    name = conn.params["name"]

    result =
      case PyrolisConnector.DB.query(name, "SELECT 1") do
        {:ok, _cols, _rows} -> "OK"
        {:error, reason} -> "#{gettext("Error")}: #{reason}"
      end

    send_resp(conn, 200, Jason.encode!(%{result: result}))
  end

  post "/test-connection" do
    PyrolisConnector.Relay.reconnect_relay()
    Process.sleep(2_000)
    status = PyrolisConnector.Relay.status()

    result = %{
      connection_status: to_string(status.connection_status),
      channel_joined: status.channel_joined
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(result))
  end

  get "/debug" do
    relay_status = PyrolisConnector.Relay.status()
    config = load_config()
    {:ok, sources} = PyrolisConnector.State.list_data_sources()

    html = render_page(gettext("Debug"), "/debug", debug_html(relay_status, config, sources))
    send_resp(conn, 200, html)
  end

  post "/debug/toggle-verbose" do
    current = Logger.level()
    new_level = if current == :debug, do: :info, else: :debug
    Logger.configure(level: new_level)

    conn
    |> put_resp_header("location", "/debug")
    |> send_resp(302, "")
  end

  match _ do
    send_resp(
      conn,
      404,
      render_page(gettext("Not Found"), nil, "<p>#{gettext("Page not found.")}</p>")
    )
  end

  # ── HTML Templates ──

  defp render_page(title, current_path, body) do
    locale = Gettext.get_locale(PyrolisConnector.Gettext)

    """
    <!DOCTYPE html>
    <html lang="#{locale}">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>#{title} - Pyrolis Connector</title>
      <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #f5f5f5; color: #333; }
        .header { background: #1a1a2e; color: white; padding: 16px 24px; display: flex; align-items: center; gap: 16px; }
        .header h1 { font-size: 18px; font-weight: 600; }
        .header .version { opacity: 0.6; font-size: 13px; }
        nav { background: #16213e; padding: 0 24px; display: flex; gap: 0; }
        nav a { color: #aaa; text-decoration: none; padding: 12px 16px; font-size: 14px; border-bottom: 2px solid transparent; }
        nav a:hover { color: white; }
        nav a.active { color: white; border-bottom-color: #e94560; }
        .container { max-width: 800px; margin: 24px auto; padding: 0 24px; }
        .card { background: white; border-radius: 8px; padding: 24px; margin-bottom: 16px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
        .card h2 { font-size: 16px; margin-bottom: 16px; color: #1a1a2e; }
        .form-group { margin-bottom: 16px; }
        .form-group label { display: block; font-size: 13px; font-weight: 600; margin-bottom: 4px; color: #555; }
        .form-group input, .form-group select { width: 100%; padding: 8px 12px; border: 1px solid #ddd; border-radius: 4px; font-size: 14px; }
        .form-group input:focus, .form-group select:focus { outline: none; border-color: #e94560; }
        .form-group .help { font-size: 12px; color: #888; margin-top: 4px; }
        .btn { padding: 8px 20px; border: none; border-radius: 4px; cursor: pointer; font-size: 14px; font-weight: 500; }
        .btn-primary { background: #e94560; color: white; }
        .btn-primary:hover { background: #c73e54; }
        .btn-secondary { background: #eee; color: #333; }
        .btn-secondary:hover { background: #ddd; }
        .btn-danger { background: #dc3545; color: white; font-size: 12px; padding: 4px 12px; }
        .btn-danger:hover { background: #c82333; }
        .btn-sm { font-size: 12px; padding: 4px 12px; }
        .alert { padding: 12px 16px; border-radius: 4px; margin-bottom: 16px; font-size: 14px; }
        .alert-success { background: #d4edda; color: #155724; }
        .status-dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; margin-right: 8px; }
        .status-dot-connected, .status-dot-running { background: #28a745; }
        .status-dot-reconnecting, .status-dot-connecting { background: #ffc107; }
        .status-dot-stopped, .status-dot-not_configured { background: #dc3545; }
        table { width: 100%; border-collapse: collapse; font-size: 14px; }
        th { text-align: left; padding: 8px; border-bottom: 2px solid #eee; color: #555; font-size: 12px; text-transform: uppercase; }
        td { padding: 8px; border-bottom: 1px solid #f0f0f0; }
        .row { display: flex; gap: 16px; }
        .row > * { flex: 1; }
        .actions { display: flex; gap: 8px; align-items: center; }
        .hidden { display: none; }
        .stat-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 12px; margin-bottom: 16px; }
        .stat-item { background: #f8f9fa; border-radius: 6px; padding: 12px; }
        .stat-item .label { font-size: 12px; color: #666; text-transform: uppercase; }
        .stat-item .value { font-size: 18px; font-weight: 600; color: #1a1a2e; margin-top: 4px; }
        .mono { font-family: "SF Mono", "Fira Code", monospace; font-size: 13px; }
        .text-muted { color: #888; }
        .empty-state { text-align: center; padding: 24px; color: #888; font-size: 14px; }
      </style>
    </head>
    <body>
      <div class="header">
        <h1>Pyrolis Connector</h1>
        <span class="version">v#{PyrolisConnector.version()}</span>
      </div>
      <nav>
        <a href="/"#{if current_path == "/", do: " class=\"active\"", else: ""}>#{gettext("Dashboard")}</a>
        <a href="/setup"#{if current_path == "/setup", do: " class=\"active\"", else: ""}>#{gettext("Cloud Setup")}</a>
        <a href="/sources/new"#{if current_path == "/sources/new", do: " class=\"active\"", else: ""}>#{gettext("Add Source")}</a>
        <a href="/debug"#{if current_path == "/debug", do: " class=\"active\"", else: ""}>#{gettext("Debug")}</a>
      </nav>
      <div class="container">
        #{body}
      </div>
    </body>
    </html>
    """
  end

  defp dashboard_html(config, sources, history, relay_status) do
    cloud_section =
      if config do
        status_class = to_string(relay_status.connection_status)
        status_label = translate_connection_status(relay_status.connection_status)

        uptime_str =
          if relay_status.started_at do
            secs = System.monotonic_time(:second) - relay_status.started_at
            format_duration(secs)
          else
            "-"
          end

        heartbeat_str =
          if relay_status.last_heartbeat_at do
            Calendar.strftime(relay_status.last_heartbeat_at, "%H:%M:%S")
          else
            gettext("never")
          end

        """
        <div class="card">
          <h2>#{gettext("Cloud Connection")}</h2>
          <table>
            <tr><td><strong>URL</strong></td><td>#{escape(config.url)}</td></tr>
            <tr><td><strong>#{gettext("Connector ID")}</strong></td><td class="mono">#{escape(config.connector_id)}</td></tr>
          </table>

          <div class="stat-grid" style="margin-top: 16px;">
            <div class="stat-item">
              <div class="label">#{gettext("Connection")}</div>
              <div class="value"><span class="status-dot status-dot-#{status_class}"></span>#{status_label}</div>
            </div>
            <div class="stat-item">
              <div class="label">#{gettext("Channel Joined")}</div>
              <div class="value">#{if relay_status.channel_joined, do: gettext("Yes"), else: gettext("No")}</div>
            </div>
            <div class="stat-item">
              <div class="label">#{gettext("Last Heartbeat")}</div>
              <div class="value">#{heartbeat_str}</div>
            </div>
            <div class="stat-item">
              <div class="label">#{gettext("Uptime")}</div>
              <div class="value">#{uptime_str}</div>
            </div>
            <div class="stat-item">
              <div class="label">#{gettext("Commands Received")}</div>
              <div class="value">#{relay_status.commands_received}</div>
            </div>
          </div>

          <button class="btn btn-secondary btn-sm" onclick="testConnection()" id="test-conn-btn">#{gettext("Test Connection")}</button>
          <span id="test-conn-result" style="margin-left: 12px; font-size: 13px;"></span>

          <script>
            async function testConnection() {
              const btn = document.getElementById('test-conn-btn');
              const result = document.getElementById('test-conn-result');
              btn.disabled = true;
              result.textContent = '#{gettext("Testing...")}';
              result.style.color = '#666';
              try {
                const res = await fetch('/test-connection', { method: 'POST' });
                const data = await res.json();
                if (data.connection_status === 'connected' && data.channel_joined) {
                  result.textContent = '#{gettext("Connected successfully")}';
                  result.style.color = '#28a745';
                } else {
                  result.textContent = '#{gettext("Status")}: ' + data.connection_status + (data.channel_joined ? '' : ' (#{gettext("channel not joined")})');
                  result.style.color = '#dc3545';
                }
              } catch(e) {
                result.textContent = '#{gettext("Connection test failed")}: ' + e.message;
                result.style.color = '#dc3545';
              }
              btn.disabled = false;
            }
          </script>
        </div>
        """
      else
        """
        <div class="card">
          <h2>#{gettext("Cloud Connection")}</h2>
          <p>#{gettext("Not configured.")} <a href="/setup">#{gettext("Set up now")}</a></p>
        </div>
        """
      end

    sources_section =
      if sources == [] do
        """
        <div class="card">
          <h2>#{gettext("Data Sources")}</h2>
          <p>#{gettext("No data sources configured.")} <a href="/sources/new">#{gettext("Add one")}</a></p>
        </div>
        """
      else
        rows =
          Enum.map_join(sources, "\n", fn ds ->
            status = if ds.enabled, do: gettext("enabled"), else: gettext("disabled")

            """
            <tr>
              <td><strong>#{escape(ds.name)}</strong></td>
              <td>#{escape(ds.db_type)}</td>
              <td>#{status}</td>
              <td class="actions">
                <button class="btn btn-secondary btn-sm" onclick="testSource('#{escape(ds.name)}')">#{gettext("Test")}</button>
                <form method="post" action="/sources/delete" style="display:inline" onsubmit="return confirm('#{gettext("Delete %{name}?", name: escape(ds.name))}')">
                  <input type="hidden" name="name" value="#{escape(ds.name)}">
                  <button type="submit" class="btn btn-danger btn-sm">#{gettext("Delete")}</button>
                </form>
              </td>
            </tr>
            """
          end)

        """
        <div class="card">
          <h2>#{gettext("Data Sources")}</h2>
          <table>
            <thead><tr><th>#{gettext("Name")}</th><th>#{gettext("Type")}</th><th>#{gettext("Status")}</th><th>#{gettext("Actions")}</th></tr></thead>
            <tbody>#{rows}</tbody>
          </table>
          <div id="test-result" class="alert hidden" style="margin-top: 12px;"></div>
        </div>
        <script>
          async function testSource(name) {
            const el = document.getElementById('test-result');
            el.className = 'alert';
            el.textContent = '#{gettext("Testing...")}';
            try {
              const form = new URLSearchParams();
              form.append('name', name);
              const res = await fetch('/test-source', { method: 'POST', body: form });
              const data = await res.json();
              el.className = data.result === 'OK' ? 'alert alert-success' : 'alert';
              el.style.background = data.result === 'OK' ? '#d4edda' : '#f8d7da';
              el.style.color = data.result === 'OK' ? '#155724' : '#721c24';
              el.textContent = name + ': ' + data.result;
            } catch(e) {
              el.className = 'alert';
              el.style.background = '#f8d7da';
              el.style.color = '#721c24';
              el.textContent = '#{gettext("Connection test failed")}: ' + e.message;
            }
          }
        </script>
        """
      end

    history_section =
      if history == [] do
        ""
      else
        rows =
          Enum.map_join(history, "\n", fn h ->
            """
            <tr>
              <td>#{escape(to_string(h.resource_type))}</td>
              <td>#{escape(h.data_source || "-")}</td>
              <td>#{h.records_synced}</td>
              <td>#{h.errors}</td>
              <td>#{escape(h.status)}</td>
              <td>#{escape(h.started_at || "")}</td>
            </tr>
            """
          end)

        """
        <div class="card">
          <h2>#{gettext("Sync History")}</h2>
          <table>
            <thead><tr><th>#{gettext("Resource")}</th><th>#{gettext("Source")}</th><th>#{gettext("Synced")}</th><th>#{gettext("Errors")}</th><th>#{gettext("Status")}</th><th>#{gettext("Started")}</th></tr></thead>
            <tbody>#{rows}</tbody>
          </table>
        </div>
        """
      end

    cloud_section <> sources_section <> history_section
  end

  defp setup_html(config) do
    """
    <div class="card">
      <h2>#{gettext("Cloud Connection Setup")}</h2>
      <form method="post" action="/setup">
        <div class="form-group">
          <label>#{gettext("Pyrolis URL")}</label>
          <input type="url" name="url" value="#{escape((config && config.url) || "")}" required placeholder="https://my-company.pyrolis.fr">
          <div class="help">#{gettext("Your Pyrolis tenant URL")}</div>
        </div>
        <div class="form-group">
          <label>#{gettext("API Key")}</label>
          <input type="password" name="api_key" value="#{escape((config && config.api_key) || "")}" required placeholder="pyrk_...">
          <div class="help">#{gettext("Generated in Pyrolis Admin > Integrations > Connectors")}</div>
        </div>
        <div class="form-group">
          <label>#{gettext("Connector ID")}</label>
          <input type="text" name="connector_id" value="#{escape((config && config.connector_id) || "")}" required placeholder="#{gettext("e.g. paris-office-01")}">
          <div class="help">#{gettext("Unique identifier for this connector instance")}</div>
        </div>
        <button type="submit" class="btn btn-primary">#{gettext("Save Configuration")}</button>
      </form>
    </div>
    """
  end

  defp source_form_html(_existing) do
    """
    <div class="card">
      <h2>#{gettext("Add Data Source")}</h2>
      <form method="post" action="/sources">
        <div class="form-group">
          <label>#{gettext("Name")}</label>
          <input type="text" name="name" required placeholder="#{gettext("e.g. si2a, cmms, erp")}">
          <div class="help">#{gettext("Unique name for this data source")}</div>
        </div>
        <div class="form-group">
          <label>#{gettext("Database Type")}</label>
          <select name="db_type" id="db_type" onchange="toggleFields()" required>
            <option value="odbc">ODBC (HFSQL, SQL Server, etc.)</option>
            <option value="mysql">MySQL / MariaDB</option>
          </select>
        </div>

        <div id="odbc-fields">
          <div class="form-group">
            <label>#{gettext("ODBC DSN")}</label>
            <input type="text" name="dsn" placeholder="#{gettext("e.g. SI2A_HFSQL")}">
            <div class="help">#{gettext("Data Source Name configured in Windows ODBC Manager")}</div>
          </div>
          <div class="row">
            <div class="form-group">
              <label>#{gettext("Username")}</label>
              <input type="text" name="uid" placeholder="#{gettext("Optional")}">
            </div>
            <div class="form-group">
              <label>#{gettext("Password")}</label>
              <input type="password" name="pwd" placeholder="#{gettext("Optional")}">
            </div>
          </div>
        </div>

        <div id="mysql-fields" class="hidden">
          <div class="row">
            <div class="form-group">
              <label>#{gettext("Host")}</label>
              <input type="text" name="host" value="localhost">
            </div>
            <div class="form-group">
              <label>#{gettext("Port")}</label>
              <input type="number" name="port" value="3306">
            </div>
          </div>
          <div class="form-group">
            <label>#{gettext("Database")}</label>
            <input type="text" name="database" placeholder="#{gettext("e.g. cmms_db")}">
          </div>
          <div class="row">
            <div class="form-group">
              <label>#{gettext("Username")}</label>
              <input type="text" name="username" value="root">
            </div>
            <div class="form-group">
              <label>#{gettext("Password")}</label>
              <input type="password" name="password">
            </div>
          </div>
        </div>

        <button type="submit" class="btn btn-primary">#{gettext("Add Data Source")}</button>
        <a href="/" class="btn btn-secondary" style="text-decoration: none; margin-left: 8px;">#{gettext("Cancel")}</a>
      </form>
    </div>

    <script>
      function toggleFields() {
        const type = document.getElementById('db_type').value;
        document.getElementById('odbc-fields').className = type === 'odbc' ? '' : 'hidden';
        document.getElementById('mysql-fields').className = type === 'mysql' ? '' : 'hidden';
      }
    </script>
    """
  end

  defp debug_html(relay_status, config, sources) do
    status_class = to_string(relay_status.connection_status)
    status_label = translate_connection_status(relay_status.connection_status)

    uptime_str =
      if relay_status.started_at do
        secs = System.monotonic_time(:second) - relay_status.started_at
        format_duration(secs)
      else
        "-"
      end

    heartbeat_str =
      if relay_status.last_heartbeat_at do
        Calendar.strftime(relay_status.last_heartbeat_at, "%Y-%m-%d %H:%M:%S UTC")
      else
        gettext("never")
      end

    cloud_url = if config, do: escape(config.url), else: gettext("not configured")
    connector_id = if config, do: escape(config.connector_id), else: "-"

    # Connection details card
    connection_card = """
    <div class="card">
      <h2>#{gettext("Connection Details")}</h2>
      <table>
        <tr><td><strong>#{gettext("WebSocket Status")}</strong></td><td><span class="status-dot status-dot-#{status_class}"></span>#{status_label}</td></tr>
        <tr><td><strong>#{gettext("Channel Joined")}</strong></td><td>#{if relay_status.channel_joined, do: gettext("Yes"), else: gettext("No")}</td></tr>
        <tr><td><strong>#{gettext("Last Heartbeat")}</strong></td><td>#{heartbeat_str}</td></tr>
        <tr><td><strong>#{gettext("Cloud URL")}</strong></td><td>#{cloud_url}</td></tr>
        <tr><td><strong>#{gettext("Connector ID")}</strong></td><td class="mono">#{connector_id}</td></tr>
        <tr><td><strong>#{gettext("Uptime")}</strong></td><td>#{uptime_str}</td></tr>
        <tr><td><strong>#{gettext("Commands Received")}</strong></td><td>#{relay_status.commands_received}</td></tr>
      </table>
    </div>
    """

    # Recent commands card
    commands_card =
      if relay_status.recent_commands == [] do
        """
        <div class="card">
          <h2>#{gettext("Recent Commands")}</h2>
          <div class="empty-state">#{gettext("No commands received yet.")}</div>
        </div>
        """
      else
        cmd_rows =
          Enum.map_join(relay_status.recent_commands, "\n", fn cmd ->
            ts = Calendar.strftime(cmd.timestamp, "%H:%M:%S")

            """
            <tr>
              <td class="mono">#{escape(cmd.request_id || "-")}</td>
              <td>#{escape(cmd.data_source || "-")}</td>
              <td class="mono" style="max-width: 300px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">#{escape(cmd.sql || "")}</td>
              <td>#{ts}</td>
            </tr>
            """
          end)

        """
        <div class="card">
          <h2>#{gettext("Recent Commands")} (#{length(relay_status.recent_commands)})</h2>
          <table>
            <thead><tr><th>#{gettext("Request ID")}</th><th>#{gettext("Data Source")}</th><th>SQL</th><th>#{gettext("Time")}</th></tr></thead>
            <tbody>#{cmd_rows}</tbody>
          </table>
        </div>
        """
      end

    # Recent errors card
    errors_card =
      if relay_status.recent_errors == [] do
        """
        <div class="card">
          <h2>#{gettext("Recent Errors")}</h2>
          <div class="empty-state">#{gettext("No errors recorded.")}</div>
        </div>
        """
      else
        error_rows =
          Enum.map_join(relay_status.recent_errors, "\n", fn err ->
            ts = Calendar.strftime(err.timestamp, "%H:%M:%S")

            """
            <tr>
              <td class="mono">#{escape(err.request_id || "-")}</td>
              <td style="max-width: 400px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">#{escape(err.error || "")}</td>
              <td>#{ts}</td>
            </tr>
            """
          end)

        """
        <div class="card">
          <h2>#{gettext("Recent Errors")} (#{length(relay_status.recent_errors)})</h2>
          <table>
            <thead><tr><th>#{gettext("Request ID")}</th><th>#{gettext("Error")}</th><th>#{gettext("Time")}</th></tr></thead>
            <tbody>#{error_rows}</tbody>
          </table>
        </div>
        """
      end

    # Data source connections card
    sources_card =
      if sources == [] do
        """
        <div class="card">
          <h2>#{gettext("Data Source Connections")}</h2>
          <div class="empty-state">#{gettext("No data sources configured.")}</div>
        </div>
        """
      else
        source_rows =
          Enum.map_join(sources, "\n", fn ds ->
            connected = PyrolisConnector.DB.connected?(ds.name)
            conn_class = if connected, do: "connected", else: "stopped"
            conn_label = if connected, do: gettext("Yes"), else: gettext("No")
            enabled_label = if ds.enabled, do: gettext("enabled"), else: gettext("disabled")

            """
            <tr>
              <td><strong>#{escape(ds.name)}</strong></td>
              <td>#{escape(ds.db_type)}</td>
              <td><span class="status-dot status-dot-#{conn_class}"></span>#{conn_label}</td>
              <td>#{enabled_label}</td>
            </tr>
            """
          end)

        """
        <div class="card">
          <h2>#{gettext("Data Source Connections")}</h2>
          <table>
            <thead><tr><th>#{gettext("Name")}</th><th>#{gettext("Type")}</th><th>#{gettext("Connected")}</th><th>#{gettext("Status")}</th></tr></thead>
            <tbody>#{source_rows}</tbody>
          </table>
        </div>
        """
      end

    # System information card
    current_log_level = Logger.level()

    toggle_label =
      if current_log_level == :debug,
        do: gettext("Switch to Normal Logging"),
        else: gettext("Enable Verbose Logging")

    {mem_total, _} = :erlang.statistics(:wall_clock)
    memory_mb = Float.round(:erlang.memory(:total) / 1_048_576, 1)

    system_card = """
    <div class="card">
      <h2>#{gettext("System Information")}</h2>
      <table>
        <tr><td><strong>#{gettext("Version")}</strong></td><td>#{PyrolisConnector.version()}</td></tr>
        <tr><td><strong>#{gettext("Uptime")}</strong></td><td>#{uptime_str}</td></tr>
        <tr><td><strong>#{gettext("Port")}</strong></td><td>#{PyrolisConnector.port()}</td></tr>
        <tr><td><strong>#{gettext("OS")}</strong></td><td>#{format_os()}</td></tr>
        <tr><td><strong>OTP</strong></td><td>#{System.otp_release()}</td></tr>
        <tr><td><strong>Elixir</strong></td><td>#{System.version()}</td></tr>
        <tr><td><strong>#{gettext("Memory")}</strong></td><td>#{memory_mb} MB</td></tr>
        <tr><td><strong>#{gettext("Log Level")}</strong></td><td>#{current_log_level}</td></tr>
        <tr><td><strong>#{gettext("Wall Clock")}</strong></td><td>#{format_duration(div(mem_total, 1000))}</td></tr>
      </table>
      <form method="post" action="/debug/toggle-verbose" style="margin-top: 12px;">
        <button type="submit" class="btn btn-secondary btn-sm">#{toggle_label}</button>
      </form>
    </div>
    """

    connection_card <> commands_card <> errors_card <> sources_card <> system_card
  end

  defp translate_connection_status(:connected), do: gettext("connected")
  defp translate_connection_status(:connecting), do: gettext("connecting")
  defp translate_connection_status(:reconnecting), do: gettext("reconnecting")
  defp translate_connection_status(:not_configured), do: gettext("not configured")
  defp translate_connection_status(:stopped), do: gettext("stopped")
  defp translate_connection_status(other), do: to_string(other)

  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"

  defp format_duration(seconds) when seconds < 3600 do
    m = div(seconds, 60)
    s = rem(seconds, 60)
    "#{m}m #{s}s"
  end

  defp format_duration(seconds) do
    h = div(seconds, 3600)
    m = div(rem(seconds, 3600), 60)
    "#{h}h #{m}m"
  end

  defp format_os do
    {family, name} = :os.type()
    "#{family}/#{name}"
  end

  # ── Helpers ──

  defp load_config do
    case PyrolisConnector.Config.load() do
      {:ok, config} -> config
      {:error, _} -> nil
    end
  end

  defp escape(nil), do: ""

  defp escape(str) when is_binary(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp escape(other), do: escape(to_string(other))
end
