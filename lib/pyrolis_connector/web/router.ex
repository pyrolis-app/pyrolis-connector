defmodule PyrolisConnector.Web.Router do
  @moduledoc """
  Local web UI for connector setup and management.

  Runs on localhost:4100 — provides forms for:
  - Cloud connection setup (URL, API key, tenant)
  - Data source management (ODBC/MySQL connections)
  - Status overview and sync history
  """

  use Plug.Router

  plug Plug.Parsers,
    parsers: [:urlencoded],
    pass: ["text/html"]

  plug :match
  plug :dispatch

  # ── Pages ──

  get "/" do
    config = load_config()
    {:ok, sources} = PyrolisConnector.State.list_data_sources()
    {:ok, history} = PyrolisConnector.State.get_sync_history(10)

    relay_status =
      if config do
        case Process.whereis(PyrolisConnector.Relay) do
          nil -> "stopped"
          _pid -> "running"
        end
      else
        "not configured"
      end

    html = render_page("Dashboard", dashboard_html(config, sources, history, relay_status))
    send_resp(conn, 200, html)
  end

  get "/setup" do
    config = load_config()
    html = render_page("Setup", setup_html(config))
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
    html = render_page("Add Data Source", source_form_html(nil))
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
        {:error, reason} -> "Error: #{reason}"
      end

    send_resp(conn, 200, Jason.encode!(%{result: result}))
  end

  match _ do
    send_resp(conn, 404, render_page("Not Found", "<p>Page not found.</p>"))
  end

  # ── HTML Templates ──

  defp render_page(title, body) do
    """
    <!DOCTYPE html>
    <html lang="en">
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
        .status { display: inline-block; width: 8px; height: 8px; border-radius: 50%; margin-right: 8px; }
        .status-online, .status-running { background: #28a745; }
        .status-offline, .status-stopped { background: #dc3545; }
        .status-not-configured { background: #ffc107; }
        table { width: 100%; border-collapse: collapse; font-size: 14px; }
        th { text-align: left; padding: 8px; border-bottom: 2px solid #eee; color: #555; font-size: 12px; text-transform: uppercase; }
        td { padding: 8px; border-bottom: 1px solid #f0f0f0; }
        .row { display: flex; gap: 16px; }
        .row > * { flex: 1; }
        .actions { display: flex; gap: 8px; align-items: center; }
        .hidden { display: none; }
      </style>
    </head>
    <body>
      <div class="header">
        <h1>Pyrolis Connector</h1>
        <span class="version">v#{PyrolisConnector.version()}</span>
      </div>
      <nav>
        <a href="/">Dashboard</a>
        <a href="/setup">Cloud Setup</a>
        <a href="/sources/new">Add Source</a>
      </nav>
      <div class="container">
        #{body}
      </div>
    </body>
    </html>
    """
  end

  defp dashboard_html(config, sources, history, relay_status) do
    saved_alert =
      ""

    cloud_section =
      if config do
        """
        <div class="card">
          <h2>Cloud Connection</h2>
          <table>
            <tr><td><strong>URL</strong></td><td>#{escape(config.url)}</td></tr>
            <tr><td><strong>Connector ID</strong></td><td>#{escape(config.connector_id)}</td></tr>
            <tr><td><strong>Relay</strong></td><td><span class="status status-#{relay_status}"></span>#{relay_status}</td></tr>
          </table>
        </div>
        """
      else
        """
        <div class="card">
          <h2>Cloud Connection</h2>
          <p>Not configured. <a href="/setup">Set up now</a></p>
        </div>
        """
      end

    sources_section =
      if sources == [] do
        """
        <div class="card">
          <h2>Data Sources</h2>
          <p>No data sources configured. <a href="/sources/new">Add one</a></p>
        </div>
        """
      else
        rows =
          Enum.map_join(sources, "\n", fn ds ->
            status = if ds.enabled, do: "enabled", else: "disabled"

            """
            <tr>
              <td><strong>#{escape(ds.name)}</strong></td>
              <td>#{escape(ds.db_type)}</td>
              <td>#{status}</td>
              <td class="actions">
                <button class="btn btn-secondary btn-sm" onclick="testSource('#{escape(ds.name)}')">Test</button>
                <form method="post" action="/sources/delete" style="display:inline" onsubmit="return confirm('Delete #{escape(ds.name)}?')">
                  <input type="hidden" name="name" value="#{escape(ds.name)}">
                  <button type="submit" class="btn btn-danger btn-sm">Delete</button>
                </form>
              </td>
            </tr>
            """
          end)

        """
        <div class="card">
          <h2>Data Sources</h2>
          <table>
            <thead><tr><th>Name</th><th>Type</th><th>Status</th><th>Actions</th></tr></thead>
            <tbody>#{rows}</tbody>
          </table>
          <div id="test-result" class="alert hidden" style="margin-top: 12px;"></div>
        </div>
        <script>
          async function testSource(name) {
            const el = document.getElementById('test-result');
            el.className = 'alert';
            el.textContent = 'Testing...';
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
              el.textContent = 'Connection test failed: ' + e.message;
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
          <h2>Sync History</h2>
          <table>
            <thead><tr><th>Resource</th><th>Source</th><th>Synced</th><th>Errors</th><th>Status</th><th>Started</th></tr></thead>
            <tbody>#{rows}</tbody>
          </table>
        </div>
        """
      end

    saved_alert <> cloud_section <> sources_section <> history_section
  end

  defp setup_html(config) do
    """
    <div class="card">
      <h2>Cloud Connection Setup</h2>
      <form method="post" action="/setup">
        <div class="form-group">
          <label>Pyrolis URL</label>
          <input type="url" name="url" value="#{escape((config && config.url) || "")}" required placeholder="https://my-company.pyrolis.fr">
          <div class="help">Your Pyrolis tenant URL</div>
        </div>
        <div class="form-group">
          <label>API Key</label>
          <input type="password" name="api_key" value="#{escape((config && config.api_key) || "")}" required placeholder="pyrk_...">
          <div class="help">Generated in Pyrolis Admin > Integrations > Connectors</div>
        </div>
        <div class="form-group">
          <label>Connector ID</label>
          <input type="text" name="connector_id" value="#{escape((config && config.connector_id) || "")}" required placeholder="e.g. paris-office-01">
          <div class="help">Unique identifier for this connector instance</div>
        </div>
        <button type="submit" class="btn btn-primary">Save Configuration</button>
      </form>
    </div>
    """
  end

  defp source_form_html(_existing) do
    """
    <div class="card">
      <h2>Add Data Source</h2>
      <form method="post" action="/sources">
        <div class="form-group">
          <label>Name</label>
          <input type="text" name="name" required placeholder="e.g. si2a, cmms, erp">
          <div class="help">Unique name for this data source</div>
        </div>
        <div class="form-group">
          <label>Database Type</label>
          <select name="db_type" id="db_type" onchange="toggleFields()" required>
            <option value="odbc">ODBC (HFSQL, SQL Server, etc.)</option>
            <option value="mysql">MySQL / MariaDB</option>
          </select>
        </div>

        <div id="odbc-fields">
          <div class="form-group">
            <label>ODBC DSN</label>
            <input type="text" name="dsn" placeholder="e.g. SI2A_HFSQL">
            <div class="help">Data Source Name configured in Windows ODBC Manager</div>
          </div>
          <div class="row">
            <div class="form-group">
              <label>Username</label>
              <input type="text" name="uid" placeholder="Optional">
            </div>
            <div class="form-group">
              <label>Password</label>
              <input type="password" name="pwd" placeholder="Optional">
            </div>
          </div>
        </div>

        <div id="mysql-fields" class="hidden">
          <div class="row">
            <div class="form-group">
              <label>Host</label>
              <input type="text" name="host" value="localhost">
            </div>
            <div class="form-group">
              <label>Port</label>
              <input type="number" name="port" value="3306">
            </div>
          </div>
          <div class="form-group">
            <label>Database</label>
            <input type="text" name="database" placeholder="e.g. cmms_db">
          </div>
          <div class="row">
            <div class="form-group">
              <label>Username</label>
              <input type="text" name="username" value="root">
            </div>
            <div class="form-group">
              <label>Password</label>
              <input type="password" name="password">
            </div>
          </div>
        </div>

        <button type="submit" class="btn btn-primary">Add Data Source</button>
        <a href="/" class="btn btn-secondary" style="text-decoration: none; margin-left: 8px;">Cancel</a>
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
