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

  require Logger

  plug(Plug.Static,
    at: "/static",
    from: {:pyrolis_connector, "priv/static"}
  )

  plug(:set_locale)

  plug(Plug.Parsers,
    parsers: [:urlencoded],
    pass: ["text/html"]
  )

  plug(:match)
  plug(:dispatch)

  @default_base_url "https://pyrolis.com"

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
    update_status = PyrolisConnector.Updater.status()

    html =
      render_page(
        gettext("Dashboard"),
        "/",
        dashboard_html(config, sources, history, relay_status, update_status)
      )

    send_resp(conn, 200, html)
  end

  get "/setup" do
    config = load_config()
    error = conn.params["error"]
    error_context = %{detail: conn.params["detail"], url: conn.params["url"]}
    html = render_page(gettext("Setup"), "/setup", setup_html(config, error, error_context))
    send_resp(conn, 200, html)
  end

  post "/pair" do
    input = String.trim(conn.params["pairing_code"] || "")

    case String.split(input, ".", parts: 2) do
      [subdomain, code] when subdomain != "" and code != "" ->
        pair_url = build_tenant_url(subdomain, "/connector/pair")
        Logger.info("Pairing: POST #{pair_url} (base_url: #{resolve_base_url()})")

        case Req.post(pair_url, json: %{code: code}, receive_timeout: 15_000) do
          {:ok, %{status: 200, body: body}} ->
            # If a custom base_url is set, rebuild the tenant URL from subdomain
            tenant_url =
              case {body["subdomain"], resolve_base_url()} do
                {sub, base} when is_binary(sub) and base != @default_base_url ->
                  build_tenant_url(sub, "")
                  |> String.trim_trailing("/")

                _ ->
                  body["url"]
              end

            Logger.info("Pairing succeeded for connector #{body["connector_id"]} (url: #{tenant_url})")

            PyrolisConnector.Config.save(%PyrolisConnector.Config{
              url: tenant_url,
              api_key: body["api_key"],
              connector_id: body["connector_id"]
            })

            # Restart relay to connect with new config
            PyrolisConnector.Relay.reconnect_relay()

            conn
            |> put_resp_header("location", "/?paired=true")
            |> send_resp(302, "")

          {:ok, %{status: status}} when status in [404, 410] ->
            Logger.warning("Pairing failed: server returned #{status} for #{pair_url}")

            conn
            |> put_resp_header("location", "/setup?error=invalid_code")
            |> send_resp(302, "")

          {:error, %Req.TransportError{reason: reason}} ->
            Logger.warning("Pairing connection failed: #{inspect(reason)} (url: #{pair_url})")

            conn
            |> put_resp_header(
              "location",
              "/setup?error=connection_failed&detail=#{URI.encode(inspect(reason))}&url=#{URI.encode(pair_url)}"
            )
            |> send_resp(302, "")

          other ->
            Logger.warning("Pairing failed: #{inspect(other)} (url: #{pair_url})")

            conn
            |> put_resp_header("location", "/setup?error=connection_failed")
            |> send_resp(302, "")
        end

      _ ->
        conn
        |> put_resp_header("location", "/setup?error=invalid_format")
        |> send_resp(302, "")
    end
  end

  post "/setup" do
    config = %PyrolisConnector.Config{
      url: String.trim(conn.params["url"]),
      api_key: String.trim(conn.params["api_key"]),
      connector_id: String.trim(conn.params["connector_id"])
    }

    # Save base_url override if provided
    base_url = String.trim(conn.params["base_url"] || "")

    if base_url != "" do
      PyrolisConnector.State.save_setting("base_url", base_url)
    end

    PyrolisConnector.Config.save(config)

    conn
    |> put_resp_header("location", "/?saved=cloud")
    |> send_resp(302, "")
  end

  get "/sources/new" do
    html = render_page(gettext("Add Data Source"), "/sources/new", source_form_html(nil))
    send_resp(conn, 200, html)
  end

  get "/sources/:name/edit" do
    case PyrolisConnector.State.get_data_source(name) do
      {:ok, source} ->
        html = render_page(gettext("Edit Data Source"), "/sources/edit", source_form_html(source))
        send_resp(conn, 200, html)

      {:error, :not_found} ->
        conn
        |> put_resp_header("location", "/?error=not_found")
        |> send_resp(302, "")
    end
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

        "mock" ->
          %{"row_count" => conn.params["row_count"] || "25"}

        _ ->
          %{}
      end

    PyrolisConnector.State.save_data_source(name, db_type, config)
    PyrolisConnector.Relay.report_status()

    conn
    |> put_resp_header("location", "/?saved=source")
    |> send_resp(302, "")
  end

  post "/sources/delete" do
    name = conn.params["name"]
    PyrolisConnector.State.delete_data_source(name)
    PyrolisConnector.Relay.report_status()

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

  get "/api/status" do
    relay_status = PyrolisConnector.Relay.status()

    result = %{
      connection_status: to_string(relay_status.connection_status),
      channel_joined: relay_status.channel_joined,
      commands_received: relay_status.commands_received,
      last_heartbeat_at:
        if(relay_status.last_heartbeat_at,
          do: Calendar.strftime(relay_status.last_heartbeat_at, "%H:%M:%S")
        ),
      uptime:
        if(relay_status.started_at,
          do: format_duration(System.monotonic_time(:second) - relay_status.started_at)
        )
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(result))
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

  # ── Update routes ──

  get "/api/update-status" do
    update = PyrolisConnector.Updater.status()

    result = %{
      status: to_string(update.status),
      available_version: update.available_version,
      error: update.error,
      current_version: PyrolisConnector.version(),
      checked_at: if(update.checked_at, do: DateTime.to_iso8601(update.checked_at))
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(result))
  end

  post "/update/check" do
    PyrolisConnector.Updater.check_now()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{ok: true}))
  end

  post "/update/download" do
    PyrolisConnector.Updater.download()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{ok: true}))
  end

  post "/update/apply" do
    PyrolisConnector.Updater.apply_update()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{ok: true, message: gettext("Applying update, restarting...")}))
  end

  post "/update/dismiss" do
    PyrolisConnector.Updater.dismiss()

    conn
    |> put_resp_header("location", "/")
    |> send_resp(302, "")
  end

  post "/update/toggle-remote" do
    allowed = PyrolisConnector.Updater.remote_updates_allowed?()
    PyrolisConnector.Updater.set_remote_updates(!allowed)

    conn
    |> put_resp_header("location", "/")
    |> send_resp(302, "")
  end

  post "/update/set-mode" do
    mode = conn.params["mode"]

    if mode in ~w(auto download manual) do
      PyrolisConnector.Updater.set_auto_apply_mode(mode)
    end

    conn
    |> put_resp_header("location", "/")
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

    nav_item = fn path, label, icon ->
      active = if current_path == path, do: " active", else: ""

      """
      <a href="#{path}" class="nav-item#{active}">
        #{icon}
        <span>#{label}</span>
      </a>
      """
    end

    """
    <!DOCTYPE html>
    <html lang="#{locale}">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>#{title} - Pyrolis Connector</title>
      <style>
        :root {
          --bg: #f0f2f5;
          --surface: #ffffff;
          --surface-hover: #f8f9fa;
          --border: #e1e5eb;
          --border-light: #f0f1f3;
          --text: #1a1d23;
          --text-secondary: #5f6775;
          --text-muted: #8b919d;
          --primary: #e94560;
          --primary-hover: #d63d56;
          --primary-light: #fef2f4;
          --header-bg: #111827;
          --header-nav: #1f2937;
          --success: #059669;
          --success-bg: #ecfdf5;
          --success-border: #a7f3d0;
          --warning: #d97706;
          --warning-bg: #fffbeb;
          --warning-border: #fde68a;
          --danger: #dc2626;
          --danger-bg: #fef2f2;
          --danger-border: #fecaca;
          --info: #0284c7;
          --info-bg: #f0f9ff;
          --info-border: #bae6fd;
          --radius: 10px;
          --radius-sm: 6px;
          --shadow: 0 1px 3px rgba(0,0,0,0.06), 0 1px 2px rgba(0,0,0,0.04);
          --shadow-md: 0 4px 6px -1px rgba(0,0,0,0.07), 0 2px 4px -2px rgba(0,0,0,0.05);
          --transition: 150ms cubic-bezier(0.4, 0, 0.2, 1);
        }

        * { box-sizing: border-box; margin: 0; padding: 0; }

        body {
          font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Inter, Roboto, sans-serif;
          background: var(--bg);
          color: var(--text);
          line-height: 1.5;
          -webkit-font-smoothing: antialiased;
        }

        .header {
          background: var(--header-bg);
          color: white;
          padding: 0 24px;
          display: flex;
          align-items: center;
          height: 56px;
          gap: 12px;
        }
        .header-logo {
          display: flex;
          align-items: center;
          gap: 10px;
        }
        .header-logo svg { width: 28px; height: 28px; }
        .header h1 { font-size: 16px; font-weight: 600; letter-spacing: -0.01em; }
        .header .version {
          font-size: 11px;
          opacity: 0.5;
          background: rgba(255,255,255,0.1);
          padding: 2px 8px;
          border-radius: 10px;
          font-weight: 500;
        }

        nav {
          background: var(--header-nav);
          padding: 0 24px;
          display: flex;
          gap: 2px;
          border-bottom: 1px solid rgba(255,255,255,0.06);
        }
        .nav-item {
          color: rgba(255,255,255,0.55);
          text-decoration: none;
          padding: 10px 14px;
          font-size: 13px;
          font-weight: 500;
          border-bottom: 2px solid transparent;
          display: flex;
          align-items: center;
          gap: 6px;
          transition: color var(--transition), border-color var(--transition);
        }
        .nav-item:hover { color: rgba(255,255,255,0.85); }
        .nav-item.active {
          color: white;
          border-bottom-color: var(--primary);
        }
        .nav-item svg { width: 16px; height: 16px; opacity: 0.7; }
        .nav-item.active svg { opacity: 1; }

        .container { max-width: 860px; margin: 24px auto; padding: 0 24px; }

        .card {
          background: var(--surface);
          border-radius: var(--radius);
          padding: 24px;
          margin-bottom: 16px;
          box-shadow: var(--shadow);
          border: 1px solid var(--border-light);
        }
        .card h2 {
          font-size: 15px;
          font-weight: 600;
          margin-bottom: 16px;
          color: var(--text);
          display: flex;
          align-items: center;
          gap: 8px;
        }
        .card h2 svg { width: 18px; height: 18px; color: var(--text-muted); }

        .form-group { margin-bottom: 18px; }
        .form-group label {
          display: block;
          font-size: 13px;
          font-weight: 600;
          margin-bottom: 6px;
          color: var(--text-secondary);
        }
        .form-group input, .form-group select {
          width: 100%;
          padding: 9px 12px;
          border: 1px solid var(--border);
          border-radius: var(--radius-sm);
          font-size: 14px;
          color: var(--text);
          background: var(--surface);
          transition: border-color var(--transition), box-shadow var(--transition);
        }
        .form-group input:focus, .form-group select:focus {
          outline: none;
          border-color: var(--primary);
          box-shadow: 0 0 0 3px var(--primary-light);
        }
        .form-group .help { font-size: 12px; color: var(--text-muted); margin-top: 5px; }

        .btn {
          display: inline-flex;
          align-items: center;
          gap: 6px;
          padding: 9px 18px;
          border: none;
          border-radius: var(--radius-sm);
          cursor: pointer;
          font-size: 13px;
          font-weight: 600;
          transition: all var(--transition);
          text-decoration: none;
          line-height: 1;
        }
        .btn-primary {
          background: var(--primary);
          color: white;
          box-shadow: 0 1px 2px rgba(233,69,96,0.3);
        }
        .btn-primary:hover { background: var(--primary-hover); box-shadow: 0 2px 4px rgba(233,69,96,0.3); }
        .btn-secondary {
          background: var(--surface);
          color: var(--text-secondary);
          border: 1px solid var(--border);
        }
        .btn-secondary:hover { background: var(--surface-hover); border-color: #cdd2da; }
        .btn-danger { background: var(--danger-bg); color: var(--danger); border: 1px solid var(--danger-border); }
        .btn-danger:hover { background: #fee2e2; }
        .btn-sm { font-size: 12px; padding: 6px 12px; }

        .alert {
          padding: 12px 16px;
          border-radius: var(--radius-sm);
          margin-bottom: 16px;
          font-size: 13px;
          display: flex;
          align-items: center;
          gap: 8px;
        }
        .alert-success { background: var(--success-bg); color: var(--success); border: 1px solid var(--success-border); }
        .alert-danger { background: var(--danger-bg); color: var(--danger); border: 1px solid var(--danger-border); }
        .alert-warning { background: var(--warning-bg); color: var(--warning); border: 1px solid var(--warning-border); }
        .alert-info { background: var(--info-bg); color: var(--info); border: 1px solid var(--info-border); }

        .badge {
          display: inline-flex;
          align-items: center;
          gap: 5px;
          font-size: 12px;
          font-weight: 600;
          padding: 3px 10px;
          border-radius: 20px;
        }
        .badge-success { background: var(--success-bg); color: var(--success); }
        .badge-warning { background: var(--warning-bg); color: var(--warning); }
        .badge-danger { background: var(--danger-bg); color: var(--danger); }

        .status-dot {
          display: inline-block;
          width: 8px;
          height: 8px;
          border-radius: 50%;
          margin-right: 6px;
          flex-shrink: 0;
        }
        .status-dot-connected, .status-dot-running { background: var(--success); box-shadow: 0 0 0 3px var(--success-bg); }
        .status-dot-reconnecting, .status-dot-connecting { background: var(--warning); box-shadow: 0 0 0 3px var(--warning-bg); animation: pulse 2s ease-in-out infinite; }
        .status-dot-stopped, .status-dot-not_configured { background: var(--danger); box-shadow: 0 0 0 3px var(--danger-bg); }

        @keyframes pulse {
          0%, 100% { opacity: 1; }
          50% { opacity: 0.4; }
        }

        table { width: 100%; border-collapse: collapse; font-size: 13px; }
        th {
          text-align: left;
          padding: 8px 12px;
          border-bottom: 1px solid var(--border);
          color: var(--text-muted);
          font-size: 11px;
          font-weight: 600;
          text-transform: uppercase;
          letter-spacing: 0.05em;
        }
        td { padding: 10px 12px; border-bottom: 1px solid var(--border-light); }
        tr:last-child td { border-bottom: none; }
        tr:hover td { background: var(--surface-hover); }

        .row { display: flex; gap: 16px; }
        .row > * { flex: 1; }
        .hidden { display: none; }

        .stat-grid {
          display: grid;
          grid-template-columns: repeat(auto-fit, minmax(160px, 1fr));
          gap: 12px;
          margin-bottom: 16px;
        }
        .stat-item {
          background: var(--bg);
          border-radius: var(--radius-sm);
          padding: 14px 16px;
          border: 1px solid var(--border-light);
        }
        .stat-item .label {
          font-size: 11px;
          color: var(--text-muted);
          text-transform: uppercase;
          letter-spacing: 0.04em;
          font-weight: 600;
        }
        .stat-item .value {
          font-size: 17px;
          font-weight: 700;
          color: var(--text);
          margin-top: 4px;
          display: flex;
          align-items: center;
        }

        .mono {
          font-family: "SF Mono", "JetBrains Mono", "Fira Code", monospace;
          font-size: 12px;
        }
        .text-muted { color: var(--text-muted); }

        .empty-state {
          text-align: center;
          padding: 32px;
          color: var(--text-muted);
          font-size: 14px;
        }

        .actions { display: flex; gap: 6px; align-items: center; }

        .divider {
          height: 1px;
          background: var(--border-light);
          margin: 20px 0;
        }

        details summary {
          cursor: pointer;
          font-size: 13px;
          color: var(--text-muted);
          padding: 10px 0;
          font-weight: 500;
          list-style: none;
          display: flex;
          align-items: center;
          gap: 6px;
        }
        details summary::-webkit-details-marker { display: none; }
        details summary::before {
          content: "";
          display: inline-block;
          width: 6px;
          height: 6px;
          border-right: 1.5px solid var(--text-muted);
          border-bottom: 1.5px solid var(--text-muted);
          transform: rotate(-45deg);
          transition: transform var(--transition);
        }
        details[open] summary::before { transform: rotate(45deg); }

        .step-indicator {
          display: flex;
          gap: 0;
          margin-bottom: 24px;
          background: var(--bg);
          border-radius: var(--radius);
          padding: 4px;
          border: 1px solid var(--border-light);
        }
        .step {
          flex: 1;
          text-align: center;
          padding: 10px 12px;
          font-size: 12px;
          font-weight: 600;
          color: var(--text-muted);
          border-radius: var(--radius-sm);
          display: flex;
          align-items: center;
          justify-content: center;
          gap: 6px;
        }
        .step.active {
          background: var(--surface);
          color: var(--primary);
          box-shadow: var(--shadow);
        }
        .step.done { color: var(--success); }
        .step-num {
          width: 20px;
          height: 20px;
          border-radius: 50%;
          display: flex;
          align-items: center;
          justify-content: center;
          font-size: 11px;
          background: var(--border);
          color: var(--text-muted);
        }
        .step.active .step-num { background: var(--primary); color: white; }
        .step.done .step-num { background: var(--success); color: white; }

        @media (max-width: 640px) {
          .container { padding: 0 16px; }
          .stat-grid { grid-template-columns: 1fr 1fr; }
          .row { flex-direction: column; gap: 0; }
          .header { padding: 0 16px; }
          nav { padding: 0 16px; overflow-x: auto; }
        }
      </style>
    </head>
    <body>
      <div class="header">
        <div class="header-logo">
          <img src="/static/images/logo.svg" alt="Pyrolis" style="width: 28px; height: 28px;">
          <h1>Pyrolis Connector</h1>
        </div>
        <span class="version">v#{PyrolisConnector.version()}</span>
      </div>
      <nav>
        #{nav_item.("/", gettext("Dashboard"), svg_icon(:dashboard))}
        #{nav_item.("/setup", gettext("Cloud Setup"), svg_icon(:cloud))}
        #{nav_item.("/sources/new", gettext("Add Source"), svg_icon(:database))}
        #{nav_item.("/debug", gettext("Debug"), svg_icon(:terminal))}
      </nav>
      <div class="container">
        #{body}
      </div>
    </body>
    </html>
    """
  end

  defp dashboard_html(config, sources, history, relay_status, update_status) do
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
          <h2>#{svg_icon(:cloud)} #{gettext("Cloud Connection")}</h2>
          <div class="stat-grid">
            <div class="stat-item">
              <div class="label">#{gettext("Connection")}</div>
              <div class="value"><span class="status-dot status-dot-#{status_class}"></span>#{status_label}</div>
            </div>
            <div class="stat-item">
              <div class="label">#{gettext("Channel")}</div>
              <div class="value">#{if relay_status.channel_joined, do: badge(:success, gettext("Joined")), else: badge(:danger, gettext("Not joined"))}</div>
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
              <div class="label">#{gettext("Commands")}</div>
              <div class="value">#{relay_status.commands_received}</div>
            </div>
          </div>

          <table>
            <tr><td style="width: 140px; color: var(--text-muted); font-weight: 500;">URL</td><td class="mono">#{escape(config.url)}</td></tr>
            <tr><td style="color: var(--text-muted); font-weight: 500;">#{gettext("Connector ID")}</td><td class="mono">#{escape(config.connector_id)}</td></tr>
          </table>

          <div class="divider"></div>

          <button class="btn btn-secondary btn-sm" onclick="testConnection()" id="test-conn-btn">
            #{svg_icon(:refresh)} #{gettext("Test Connection")}
          </button>
          <span id="test-conn-result" style="margin-left: 12px; font-size: 13px;"></span>

          <script>
            async function testConnection() {
              const btn = document.getElementById('test-conn-btn');
              const result = document.getElementById('test-conn-result');
              btn.disabled = true;
              result.textContent = '#{gettext("Testing...")}';
              result.style.color = 'var(--text-muted)';
              try {
                const res = await fetch('/test-connection', { method: 'POST' });
                const data = await res.json();
                if (data.connection_status === 'connected' && data.channel_joined) {
                  result.textContent = '#{gettext("Connected successfully")}';
                  result.style.color = 'var(--success)';
                } else {
                  result.textContent = '#{gettext("Status")}: ' + data.connection_status + (data.channel_joined ? '' : ' (#{gettext("channel not joined")})');
                  result.style.color = 'var(--danger)';
                }
              } catch(e) {
                result.textContent = '#{gettext("Connection test failed")}: ' + e.message;
                result.style.color = 'var(--danger)';
              }
              btn.disabled = false;
            }
          </script>
        </div>
        """
      else
        """
        <div class="card">
          <h2>#{svg_icon(:cloud)} #{gettext("Cloud Connection")}</h2>
          <div class="empty-state">
            <p style="margin-bottom: 12px;">#{gettext("Not configured.")}</p>
            <a href="/setup" class="btn btn-primary">#{gettext("Set up now")}</a>
          </div>
        </div>
        """
      end

    sources_section =
      if sources == [] do
        """
        <div class="card">
          <h2>#{svg_icon(:database)} #{gettext("Data Sources")}</h2>
          <div class="empty-state">
            <p style="margin-bottom: 12px;">#{gettext("No data sources configured.")}</p>
            <a href="/sources/new" class="btn btn-primary btn-sm">#{gettext("Add one")}</a>
          </div>
        </div>
        """
      else
        rows =
          Enum.map_join(sources, "\n", fn ds ->
            status_badge =
              if ds.enabled,
                do: badge(:success, gettext("enabled")),
                else: badge(:danger, gettext("disabled"))

            """
            <tr>
              <td><strong>#{escape(ds.name)}</strong></td>
              <td><span class="badge" style="background: var(--bg); color: var(--text-secondary); font-size: 11px;">#{escape(ds.db_type)}</span></td>
              <td>#{status_badge}</td>
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
          <h2>#{svg_icon(:database)} #{gettext("Data Sources")}</h2>
          <table>
            <thead><tr><th>#{gettext("Name")}</th><th>#{gettext("Type")}</th><th>#{gettext("Status")}</th><th>#{gettext("Actions")}</th></tr></thead>
            <tbody>#{rows}</tbody>
          </table>
          <div id="test-result" class="alert hidden" style="margin-top: 12px;"></div>
        </div>
        <script>
          async function testSource(name) {
            const el = document.getElementById('test-result');
            el.className = 'alert alert-info';
            el.textContent = '#{gettext("Testing...")}';
            try {
              const form = new URLSearchParams();
              form.append('name', name);
              const res = await fetch('/test-source', { method: 'POST', body: form });
              const data = await res.json();
              el.className = data.result === 'OK' ? 'alert alert-success' : 'alert alert-danger';
              el.textContent = name + ': ' + data.result;
            } catch(e) {
              el.className = 'alert alert-danger';
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
            status_badge =
              case to_string(h.status) do
                "completed" -> badge(:success, h.status)
                "failed" -> badge(:danger, h.status)
                _ -> badge(:warning, h.status)
              end

            """
            <tr>
              <td>#{escape(to_string(h.resource_type))}</td>
              <td>#{escape(h.data_source || "-")}</td>
              <td>#{h.records_synced}</td>
              <td>#{h.errors}</td>
              <td>#{status_badge}</td>
              <td class="text-muted">#{escape(h.started_at || "")}</td>
            </tr>
            """
          end)

        """
        <div class="card">
          <h2>#{svg_icon(:history)} #{gettext("Sync History")}</h2>
          <table>
            <thead><tr><th>#{gettext("Resource")}</th><th>#{gettext("Source")}</th><th>#{gettext("Synced")}</th><th>#{gettext("Errors")}</th><th>#{gettext("Status")}</th><th>#{gettext("Started")}</th></tr></thead>
            <tbody>#{rows}</tbody>
          </table>
        </div>
        """
      end

    auto_refresh = """
    <script>
      (function() {
        let prev = null;
        async function poll() {
          try {
            const res = await fetch('/api/status');
            const data = await res.json();
            const key = JSON.stringify(data);
            if (prev !== null && prev !== key) {
              location.reload();
            }
            prev = key;
          } catch(e) {}
        }
        setInterval(poll, 3000);
      })();
    </script>
    """

    update_section = update_html(update_status)

    cloud_section <> update_section <> sources_section <> history_section <> auto_refresh
  end

  defp update_html(update_status) do
    case update_status.status do
      :available ->
        """
        <div class="card" style="border-left: 3px solid var(--info);">
          <h2>#{svg_icon(:refresh)} #{gettext("Update Available")}</h2>
          <p style="margin-bottom: 12px;">
            #{gettext("Version <strong>%{version}</strong> is available (current: %{current}).", version: update_status.available_version, current: PyrolisConnector.version())}
          </p>
          <div style="display: flex; gap: 8px; align-items: center;">
            <button class="btn btn-primary btn-sm" onclick="downloadUpdate()" id="download-btn">
              #{gettext("Download & Install")}
            </button>
            <form method="post" action="/update/dismiss" style="display: inline;">
              <button type="submit" class="btn btn-secondary btn-sm">#{gettext("Dismiss")}</button>
            </form>
            <span id="update-status-msg" style="font-size: 13px; color: var(--text-muted);"></span>
          </div>
          #{update_script()}
        </div>
        """

      :downloading ->
        """
        <div class="card" style="border-left: 3px solid var(--warning);">
          <h2>#{svg_icon(:refresh)} #{gettext("Downloading Update...")}</h2>
          <p>#{gettext("Downloading version %{version}...", version: update_status.available_version)}</p>
          <div id="update-status-msg" style="font-size: 13px; color: var(--text-muted); margin-top: 8px;">
            #{gettext("Please wait...")}
          </div>
          #{update_script()}
        </div>
        """

      :ready ->
        """
        <div class="card" style="border-left: 3px solid var(--success);">
          <h2>#{svg_icon(:refresh)} #{gettext("Update Ready")}</h2>
          <p style="margin-bottom: 12px;">
            #{gettext("Version <strong>%{version}</strong> has been downloaded and verified.", version: update_status.available_version)}
          </p>
          <div style="display: flex; gap: 8px; align-items: center;">
            <button class="btn btn-primary btn-sm" onclick="applyUpdate()" id="apply-btn">
              #{gettext("Apply & Restart")}
            </button>
            <form method="post" action="/update/dismiss" style="display: inline;">
              <button type="submit" class="btn btn-secondary btn-sm">#{gettext("Dismiss")}</button>
            </form>
            <span id="update-status-msg" style="font-size: 13px; color: var(--text-muted);"></span>
          </div>
          #{update_script()}
        </div>
        """

      :applying ->
        """
        <div class="card" style="border-left: 3px solid var(--warning);">
          <h2>#{svg_icon(:refresh)} #{gettext("Applying Update...")}</h2>
          <p>#{gettext("The connector is restarting with the new version. This page will reload automatically.")}</p>
          <script>setTimeout(function() { location.reload(); }, 5000);</script>
        </div>
        """

      :error ->
        """
        <div class="card" style="border-left: 3px solid var(--danger);">
          <h2>#{svg_icon(:alert)} #{gettext("Update Error")}</h2>
          <p style="color: var(--danger);">#{escape(update_status.error || gettext("Unknown error"))}</p>
          <div style="display: flex; gap: 8px; margin-top: 12px;">
            <button class="btn btn-secondary btn-sm" onclick="checkForUpdate()">#{gettext("Retry")}</button>
            <form method="post" action="/update/dismiss" style="display: inline;">
              <button type="submit" class="btn btn-secondary btn-sm">#{gettext("Dismiss")}</button>
            </form>
          </div>
          #{update_script()}
        </div>
        """

      _ ->
        # :idle — show settings + check button
        checked_str =
          if update_status.checked_at do
            Calendar.strftime(update_status.checked_at, "%Y-%m-%d %H:%M")
          else
            gettext("never")
          end

        remote_allowed = PyrolisConnector.Updater.remote_updates_allowed?()

        remote_label =
          if remote_allowed,
            do: gettext("Remote updates: enabled"),
            else: gettext("Remote updates: disabled")

        remote_color = if remote_allowed, do: "var(--success)", else: "var(--text-muted)"

        current_mode = PyrolisConnector.Updater.auto_apply_mode()

        mode_options =
          [
            {"auto", gettext("Auto update")},
            {"download", gettext("Auto download")},
            {"manual", gettext("Manual")}
          ]
          |> Enum.map(fn {val, label} ->
            selected = if val == current_mode, do: " selected", else: ""
            "<option value=\"#{val}\"#{selected}>#{label}</option>"
          end)
          |> Enum.join()

        """
        <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px; flex-wrap: wrap; gap: 8px;">
          <div style="display: flex; align-items: center; gap: 8px;">
            <form method="post" action="/update/toggle-remote" style="display: inline;">
              <button type="submit" class="btn btn-secondary btn-sm" style="font-size: 12px;">
                #{svg_icon(:settings)} <span style="color: #{remote_color};">#{remote_label}</span>
              </button>
            </form>
            <form method="post" action="/update/set-mode" style="display: inline-flex; align-items: center; gap: 4px;">
              <label style="font-size: 12px; color: var(--text-muted);">#{gettext("Mode:")}</label>
              <select name="mode" onchange="this.form.submit()" style="font-size: 12px; padding: 3px 6px; border-radius: var(--radius-sm); border: 1px solid var(--border); background: var(--surface);">
                #{mode_options}
              </select>
            </form>
          </div>
          <div style="display: flex; align-items: center; gap: 6px;">
            <button class="btn btn-secondary btn-sm" onclick="checkForUpdate()" id="check-update-btn" style="font-size: 12px;">
              #{svg_icon(:refresh)} #{gettext("Check for updates")}
            </button>
            <span style="font-size: 11px; color: var(--text-muted);">
              #{gettext("Last checked: %{time}", time: checked_str)}
            </span>
            <span id="update-status-msg" style="font-size: 12px;"></span>
          </div>
          #{update_script()}
        </div>
        """
    end
  end

  defp update_script do
    """
    <script>
      async function checkForUpdate() {
        const msg = document.getElementById('update-status-msg');
        if (msg) { msg.textContent = '#{gettext("Checking...")}'; msg.style.color = 'var(--text-muted)'; }
        try {
          await fetch('/update/check', { method: 'POST' });
          // Poll for result
          setTimeout(async function() {
            const res = await fetch('/api/update-status');
            const data = await res.json();
            if (data.status === 'available') {
              location.reload();
            } else if (msg) {
              msg.textContent = '#{gettext("Already up to date")}';
              msg.style.color = 'var(--success)';
            }
          }, 3000);
        } catch(e) {
          if (msg) { msg.textContent = '#{gettext("Check failed")}'; msg.style.color = 'var(--danger)'; }
        }
      }

      async function downloadUpdate() {
        const btn = document.getElementById('download-btn');
        const msg = document.getElementById('update-status-msg');
        if (btn) btn.disabled = true;
        if (msg) { msg.textContent = '#{gettext("Starting download...")}'; }
        try {
          await fetch('/update/download', { method: 'POST' });
          // Poll until ready
          const poll = setInterval(async function() {
            const res = await fetch('/api/update-status');
            const data = await res.json();
            if (data.status === 'ready' || data.status === 'error') {
              clearInterval(poll);
              location.reload();
            } else if (msg) {
              msg.textContent = '#{gettext("Downloading...")}';
            }
          }, 2000);
        } catch(e) {
          if (msg) { msg.textContent = '#{gettext("Download failed")}'; msg.style.color = 'var(--danger)'; }
          if (btn) btn.disabled = false;
        }
      }

      async function applyUpdate() {
        const btn = document.getElementById('apply-btn');
        const msg = document.getElementById('update-status-msg');
        if (btn) btn.disabled = true;
        if (msg) { msg.textContent = '#{gettext("Applying update...")}'; }
        try {
          await fetch('/update/apply', { method: 'POST' });
          if (msg) { msg.textContent = '#{gettext("Restarting...")}'; }
          // Wait and reload
          setTimeout(function() { location.reload(); }, 5000);
        } catch(e) {
          if (msg) { msg.textContent = '#{gettext("Apply failed")}'; msg.style.color = 'var(--danger)'; }
          if (btn) btn.disabled = false;
        }
      }
    </script>
    """
  end

  defp setup_html(config, error, error_context) do
    has_config = not is_nil(config) and not is_nil(config.url) and config.url != ""
    base_url = load_base_url()
    {:ok, sources} = PyrolisConnector.State.list_data_sources()
    source_count = length(sources)

    error_alert =
      case error do
        "invalid_code" ->
          """
          <div class="alert alert-danger">
            #{svg_icon(:alert)} #{gettext("Invalid or expired pairing code. Please generate a new one from the admin panel.")}
          </div>
          """

        "invalid_format" ->
          """
          <div class="alert alert-danger">
            #{svg_icon(:alert)} #{gettext("Invalid format. The pairing code should look like: my-company.ABCD1234")}
          </div>
          """

        "connection_failed" ->
          detail = error_context[:detail]
          url = error_context[:url]

          detail_html =
            if detail || url do
              parts =
                [
                  if(url, do: "URL: <code class=\"mono\">#{escape(url)}</code>"),
                  if(detail, do: "#{escape(detail)}")
                ]
                |> Enum.reject(&is_nil/1)
                |> Enum.join(" — ")

              "<br><small style=\"opacity: 0.8;\">#{parts}</small>"
            else
              ""
            end

          """
          <div class="alert alert-danger">
            #{svg_icon(:alert)} #{gettext("Could not reach the Pyrolis server. Check your internet connection and try again.")}#{detail_html}
          </div>
          """

        _ ->
          ""
      end

    step_class = fn n ->
      cond do
        has_config and n == 1 -> "step done"
        has_config and n == 2 -> "step active"
        not has_config and n == 1 -> "step active"
        true -> "step"
      end
    end

    step_num = fn n ->
      if has_config and n == 1 do
        svg_icon(:check)
      else
        "<span class=\"step-num\">#{n}</span>"
      end
    end

    source_label =
      if source_count > 0,
        do: "#{gettext("Data Sources")} (#{source_count})",
        else: gettext("Data Sources")

    # Data sources summary for the setup page
    sources_summary =
      if has_config do
        source_rows =
          if sources == [] do
            """
            <div class="empty-state" style="padding: 16px;">
              <p>#{gettext("No data sources configured.")}</p>
              <a href="/sources/new" class="btn btn-primary btn-sm" style="margin-top: 8px;">#{gettext("Add one")}</a>
            </div>
            """
          else
            rows =
              Enum.map_join(sources, "\n", fn ds ->
                status_badge =
                  if ds.enabled,
                    do: badge(:success, gettext("enabled")),
                    else: badge(:danger, gettext("disabled"))

                """
                <tr>
                  <td><strong>#{escape(ds.name)}</strong></td>
                  <td><span class="badge" style="background: var(--bg); color: var(--text-secondary); font-size: 11px;">#{escape(ds.db_type)}</span></td>
                  <td>#{status_badge}</td>
                  <td class="actions">
                    <a href="/sources/#{URI.encode(ds.name)}/edit" class="btn btn-secondary btn-sm">#{gettext("Edit")}</a>
                  </td>
                </tr>
                """
              end)

            """
            <table>
              <thead><tr><th>#{gettext("Name")}</th><th>#{gettext("Type")}</th><th>#{gettext("Status")}</th><th></th></tr></thead>
              <tbody>#{rows}</tbody>
            </table>
            <div style="margin-top: 12px;">
              <a href="/sources/new" class="btn btn-secondary btn-sm">#{gettext("Add Data Source")}</a>
            </div>
            """
          end

        """
        <div class="card" style="margin-top: 16px;">
          <h2>#{svg_icon(:database)} #{source_label}</h2>
          #{source_rows}
        </div>
        """
      else
        ""
      end

    """
    #{error_alert}

    <div class="step-indicator">
      <div class="#{step_class.(1)}">
        #{step_num.(1)}
        #{gettext("Cloud Connection")}
      </div>
      <div class="#{step_class.(2)}">
        #{step_num.(2)}
        #{source_label}
      </div>
    </div>

    <div class="card">
      <h2>#{svg_icon(:link)} #{gettext("Quick Setup")}</h2>
      <p style="color: var(--text-secondary); font-size: 13px; margin-bottom: 16px;">
        #{gettext("Enter the pairing code shown in your Pyrolis admin panel.")}
      </p>
      <form method="post" action="/pair" style="display: flex; gap: 10px; align-items: flex-end;">
        <div class="form-group" style="flex: 1; margin-bottom: 0;">
          <label>#{gettext("Pairing Code")}</label>
          <input type="text" name="pairing_code" required placeholder="#{gettext("e.g. my-company.ABCD1234")}"
                 style="font-family: 'SF Mono', 'JetBrains Mono', monospace; font-size: 14px; letter-spacing: 1px;"
                 autocomplete="off">
        </div>
        <button type="submit" class="btn btn-primary" style="white-space: nowrap; height: 38px;">#{gettext("Pair")}</button>
      </form>
      <div class="help" style="margin-top: 6px;">#{gettext("Generated in Pyrolis Admin > Integrations > Connectors")}</div>
    </div>

    <details style="margin-top: 4px;">
      <summary>#{gettext("Or configure manually")}</summary>
      <div class="card" style="margin-top: 8px;">
        <h2>#{svg_icon(:settings)} #{gettext("Manual Configuration")}</h2>
        <form method="post" action="/setup">
          <div class="form-group">
            <label>#{gettext("Pyrolis URL")}</label>
            <input type="url" name="url" value="#{escape((config && config.url) || "")}" required placeholder="https://my-company.pyrolis.com">
            <div class="help">#{gettext("Your Pyrolis tenant URL")}</div>
          </div>
          <div class="form-group">
            <label>#{gettext("API Key")}</label>
            <input type="password" name="api_key" value="#{escape((config && config.api_key) || "")}" required placeholder="pyrk_...">
            <div class="help">#{gettext("API key from the admin panel")}</div>
          </div>
          <div class="form-group">
            <label>#{gettext("Connector ID")}</label>
            <input type="text" name="connector_id" value="#{escape((config && config.connector_id) || "")}" required placeholder="#{gettext("e.g. paris-office-01")}">
            <div class="help">#{gettext("Unique identifier for this connector instance")}</div>
          </div>

          <details>
            <summary>#{gettext("Advanced settings")}</summary>
            <div class="form-group" style="margin-top: 12px;">
              <label>#{gettext("Base Domain")}</label>
              <input type="url" name="base_url" value="#{escape(base_url)}" placeholder="https://pyrolis.com">
              <div class="help">#{gettext("Override the base domain used for pairing. Leave empty to use the default (pyrolis.com). Useful for self-hosted or staging environments.")}</div>
            </div>
          </details>

          <div style="margin-top: 16px;">
            <button type="submit" class="btn btn-primary btn-sm">#{gettext("Save")}</button>
          </div>
        </form>
      </div>
    </details>

    #{sources_summary}
    """
  end

  defp source_form_html(existing) do
    editing = not is_nil(existing)
    title = if editing, do: gettext("Edit Data Source"), else: gettext("Add Data Source")
    submit_label = if editing, do: gettext("Save"), else: gettext("Add Data Source")

    # Pre-fill values from existing source
    src_name = if editing, do: existing.name, else: ""
    src_type = if editing, do: existing.db_type, else: "odbc"
    src_cfg = if editing, do: existing.config, else: %{}

    hfsql_installed = PyrolisConnector.OdbcDriver.hfsql_driver_installed?()
    dsns = PyrolisConnector.OdbcDriver.available_dsns()

    dsn_datalist =
      if dsns != [] do
        options = Enum.map_join(dsns, "\n", fn dsn -> "<option value=\"#{escape(dsn)}\">" end)
        "<datalist id=\"dsn-list\">#{options}</datalist>"
      else
        ""
      end

    dsn_list_attr = if dsns != [], do: " list=\"dsn-list\"", else: ""

    driver_alert =
      if hfsql_installed do
        """
        <div class="alert alert-success" style="margin-bottom: 12px;">
          #{svg_icon(:check)} #{gettext("HFSQL ODBC driver detected")}
        </div>
        """
      else
        """
        <div class="alert alert-warning" style="margin-bottom: 12px;">
          #{svg_icon(:alert)} #{gettext("HFSQL ODBC driver not detected.")}
          #{gettext("Install it from your WinDev/WebDev installation media (Install/ODBC/) or")}
          <a href="https://download.windev.com/uk/download/saas/HFSQL/2025.awp" target="_blank" style="color: inherit; text-decoration: underline;">#{gettext("download from PCSoft")}</a>.
        </div>
        """
      end

    selected = fn type -> if src_type == type, do: " selected", else: "" end
    odbc_vis = if src_type == "odbc" or not editing, do: "", else: "hidden"
    mysql_vis = if src_type == "mysql", do: "", else: "hidden"
    mock_vis = if src_type == "mock", do: "", else: "hidden"

    name_field =
      if editing do
        """
        <input type="hidden" name="name" value="#{escape(src_name)}">
        <div class="form-group">
          <label>#{gettext("Name")}</label>
          <input type="text" value="#{escape(src_name)}" disabled style="background: var(--bg);">
        </div>
        """
      else
        """
        <div class="form-group">
          <label>#{gettext("Name")}</label>
          <input type="text" name="name" required placeholder="#{gettext("e.g. si2a, cmms, erp")}" value="#{escape(src_name)}">
          <div class="help">#{gettext("Unique name for this data source")}</div>
        </div>
        """
      end

    """
    <div class="card">
      <h2>#{svg_icon(:database)} #{title}</h2>
      <form method="post" action="/sources">
        #{name_field}
        <div class="form-group">
          <label>#{gettext("Database Type")}</label>
          <select name="db_type" id="db_type" onchange="toggleFields()" required>
            <option value="odbc"#{selected.("odbc")}>ODBC (HFSQL, SQL Server, etc.)</option>
            <option value="mysql"#{selected.("mysql")}>MySQL / MariaDB</option>
            <option value="mock"#{selected.("mock")}>Mock (#{gettext("Test Data")})</option>
          </select>
        </div>

        <div id="odbc-fields" class="#{odbc_vis}">
          #{driver_alert}
          <div class="form-group">
            <label>#{gettext("ODBC DSN")}</label>
            <input type="text" name="dsn" placeholder="#{gettext("e.g. SI2A_HFSQL")}" value="#{escape(src_cfg["dsn"] || "")}"#{dsn_list_attr}>
            #{dsn_datalist}
            <div class="help">#{gettext("Data Source Name configured in Windows ODBC Manager")}</div>
          </div>
          <div class="row">
            <div class="form-group">
              <label>#{gettext("Username")}</label>
              <input type="text" name="uid" placeholder="#{gettext("Optional")}" value="#{escape(src_cfg["uid"] || "")}">
            </div>
            <div class="form-group">
              <label>#{gettext("Password")}</label>
              <input type="password" name="pwd" placeholder="#{gettext("Optional")}" value="#{escape(src_cfg["pwd"] || "")}">
            </div>
          </div>
        </div>

        <div id="mysql-fields" class="#{mysql_vis}">
          <div class="row">
            <div class="form-group">
              <label>#{gettext("Host")}</label>
              <input type="text" name="host" value="#{escape(src_cfg["host"] || "localhost")}">
            </div>
            <div class="form-group">
              <label>#{gettext("Port")}</label>
              <input type="number" name="port" value="#{escape(src_cfg["port"] || "3306")}">
            </div>
          </div>
          <div class="form-group">
            <label>#{gettext("Database")}</label>
            <input type="text" name="database" placeholder="#{gettext("e.g. cmms_db")}" value="#{escape(src_cfg["database"] || "")}">
          </div>
          <div class="row">
            <div class="form-group">
              <label>#{gettext("Username")}</label>
              <input type="text" name="username" value="#{escape(src_cfg["username"] || "root")}">
            </div>
            <div class="form-group">
              <label>#{gettext("Password")}</label>
              <input type="password" name="password" value="#{escape(src_cfg["password"] || "")}">
            </div>
          </div>
        </div>

        <div id="mock-fields" class="#{mock_vis}">
          <div class="alert alert-info" style="margin-bottom: 12px;">
            #{svg_icon(:info)} #{gettext("Mock mode generates realistic test data (clients, articles, installations) without a real database. Useful for E2E testing.")}
          </div>
          <div class="form-group">
            <label>#{gettext("Rows per table")}</label>
            <input type="number" name="row_count" value="#{escape(src_cfg["row_count"] || "25")}" min="1" max="1000">
            <div class="help">#{gettext("Number of rows to generate for each table (default: 25)")}</div>
          </div>
        </div>

        <div style="display: flex; gap: 8px; margin-top: 8px;">
          <button type="submit" class="btn btn-primary btn-sm">#{submit_label}</button>
          <a href="/" class="btn btn-secondary btn-sm">#{gettext("Cancel")}</a>
        </div>
      </form>
    </div>

    <script>
      function toggleFields() {
        const type = document.getElementById('db_type').value;
        document.getElementById('odbc-fields').className = type === 'odbc' ? '' : 'hidden';
        document.getElementById('mysql-fields').className = type === 'mysql' ? '' : 'hidden';
        document.getElementById('mock-fields').className = type === 'mock' ? '' : 'hidden';
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

    connection_card = """
    <div class="card">
      <h2>#{svg_icon(:cloud)} #{gettext("Connection Details")}</h2>
      <table>
        <tr><td style="width: 180px; color: var(--text-muted); font-weight: 500;">#{gettext("WebSocket Status")}</td><td><span class="status-dot status-dot-#{status_class}"></span>#{status_label}</td></tr>
        <tr><td style="color: var(--text-muted); font-weight: 500;">#{gettext("Channel Joined")}</td><td>#{if relay_status.channel_joined, do: badge(:success, gettext("Yes")), else: badge(:danger, gettext("No"))}</td></tr>
        <tr><td style="color: var(--text-muted); font-weight: 500;">#{gettext("Last Heartbeat")}</td><td>#{heartbeat_str}</td></tr>
        <tr><td style="color: var(--text-muted); font-weight: 500;">#{gettext("Cloud URL")}</td><td class="mono">#{cloud_url}</td></tr>
        <tr><td style="color: var(--text-muted); font-weight: 500;">#{gettext("Connector ID")}</td><td class="mono">#{connector_id}</td></tr>
        <tr><td style="color: var(--text-muted); font-weight: 500;">#{gettext("Uptime")}</td><td>#{uptime_str}</td></tr>
        <tr><td style="color: var(--text-muted); font-weight: 500;">#{gettext("Commands Received")}</td><td>#{relay_status.commands_received}</td></tr>
      </table>
    </div>
    """

    commands_card =
      if relay_status.recent_commands == [] do
        """
        <div class="card">
          <h2>#{svg_icon(:terminal)} #{gettext("Recent Commands")}</h2>
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
              <td class="text-muted">#{ts}</td>
            </tr>
            """
          end)

        """
        <div class="card">
          <h2>#{svg_icon(:terminal)} #{gettext("Recent Commands")} <span class="badge badge-success" style="font-size: 11px; margin-left: 4px;">#{length(relay_status.recent_commands)}</span></h2>
          <table>
            <thead><tr><th>#{gettext("Request ID")}</th><th>#{gettext("Data Source")}</th><th>SQL</th><th>#{gettext("Time")}</th></tr></thead>
            <tbody>#{cmd_rows}</tbody>
          </table>
        </div>
        """
      end

    errors_card =
      if relay_status.recent_errors == [] do
        """
        <div class="card">
          <h2>#{svg_icon(:alert)} #{gettext("Recent Errors")}</h2>
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
              <td class="text-muted">#{ts}</td>
            </tr>
            """
          end)

        """
        <div class="card">
          <h2>#{svg_icon(:alert)} #{gettext("Recent Errors")} <span class="badge badge-danger" style="font-size: 11px; margin-left: 4px;">#{length(relay_status.recent_errors)}</span></h2>
          <table>
            <thead><tr><th>#{gettext("Request ID")}</th><th>#{gettext("Error")}</th><th>#{gettext("Time")}</th></tr></thead>
            <tbody>#{error_rows}</tbody>
          </table>
        </div>
        """
      end

    sources_card =
      if sources == [] do
        """
        <div class="card">
          <h2>#{svg_icon(:database)} #{gettext("Data Source Connections")}</h2>
          <div class="empty-state">#{gettext("No data sources configured.")}</div>
        </div>
        """
      else
        source_rows =
          Enum.map_join(sources, "\n", fn ds ->
            connected = PyrolisConnector.DB.connected?(ds.name)
            conn_badge = if connected, do: badge(:success, gettext("Yes")), else: badge(:danger, gettext("No"))
            enabled_badge = if ds.enabled, do: badge(:success, gettext("enabled")), else: badge(:danger, gettext("disabled"))

            """
            <tr>
              <td><strong>#{escape(ds.name)}</strong></td>
              <td>#{escape(ds.db_type)}</td>
              <td>#{conn_badge}</td>
              <td>#{enabled_badge}</td>
            </tr>
            """
          end)

        """
        <div class="card">
          <h2>#{svg_icon(:database)} #{gettext("Data Source Connections")}</h2>
          <table>
            <thead><tr><th>#{gettext("Name")}</th><th>#{gettext("Type")}</th><th>#{gettext("Connected")}</th><th>#{gettext("Status")}</th></tr></thead>
            <tbody>#{source_rows}</tbody>
          </table>
        </div>
        """
      end

    # ODBC drivers card
    drivers = PyrolisConnector.OdbcDriver.installed_drivers()
    dsns = PyrolisConnector.OdbcDriver.available_dsns()
    hfsql_installed = PyrolisConnector.OdbcDriver.hfsql_driver_installed?()

    odbc_card =
      """
      <div class="card">
        <h2>#{svg_icon(:settings)} #{gettext("ODBC Drivers")}</h2>
        <h3 style="font-size: 12px; color: var(--text-muted); margin-bottom: 8px; text-transform: uppercase; letter-spacing: 0.04em; font-weight: 600;">#{gettext("Installed Drivers")}</h3>
      """ <>
        if drivers == [] do
          """
            <div class="empty-state" style="padding: 12px;">#{gettext("No ODBC drivers found.")}</div>
          """
        else
          driver_rows =
            Enum.map_join(drivers, "\n", fn name ->
              is_hfsql = String.contains?(String.downcase(name), "hfsql")
              dot_class = if is_hfsql, do: "connected", else: "stopped"

              """
              <tr>
                <td><span class="status-dot status-dot-#{dot_class}"></span>#{escape(name)}</td>
              </tr>
              """
            end)

          hfsql_row =
            unless hfsql_installed do
              """
              <tr>
                <td style="color: var(--danger);"><span class="status-dot status-dot-stopped"></span>HFSQL — #{gettext("not found")}</td>
              </tr>
              """
            else
              ""
            end

          "<table><tbody>#{driver_rows}#{hfsql_row}</tbody></table>"
        end <>
        """
        <h3 style="font-size: 12px; color: var(--text-muted); margin: 16px 0 8px; text-transform: uppercase; letter-spacing: 0.04em; font-weight: 600;">#{gettext("Available DSNs")}</h3>
        """ <>
        if dsns == [] do
          """
            <div class="empty-state" style="padding: 12px;">#{gettext("No DSNs configured.")}</div>
          </div>
          """
        else
          dsn_rows =
            Enum.map_join(dsns, "\n", fn name ->
              "<tr><td class=\"mono\">#{escape(name)}</td></tr>"
            end)

          "<table><tbody>#{dsn_rows}</tbody></table></div>"
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
      <h2>#{svg_icon(:info)} #{gettext("System Information")}</h2>
      <table>
        <tr><td style="width: 180px; color: var(--text-muted); font-weight: 500;">#{gettext("Version")}</td><td>#{PyrolisConnector.version()}</td></tr>
        <tr><td style="color: var(--text-muted); font-weight: 500;">#{gettext("Uptime")}</td><td>#{uptime_str}</td></tr>
        <tr><td style="color: var(--text-muted); font-weight: 500;">#{gettext("Port")}</td><td>#{PyrolisConnector.port()}</td></tr>
        <tr><td style="color: var(--text-muted); font-weight: 500;">#{gettext("OS")}</td><td>#{format_os()}</td></tr>
        <tr><td style="color: var(--text-muted); font-weight: 500;">OTP</td><td>#{System.otp_release()}</td></tr>
        <tr><td style="color: var(--text-muted); font-weight: 500;">Elixir</td><td>#{System.version()}</td></tr>
        <tr><td style="color: var(--text-muted); font-weight: 500;">#{gettext("Memory")}</td><td>#{memory_mb} MB</td></tr>
        <tr><td style="color: var(--text-muted); font-weight: 500;">#{gettext("Log Level")}</td><td>#{current_log_level}</td></tr>
        <tr><td style="color: var(--text-muted); font-weight: 500;">#{gettext("Wall Clock")}</td><td>#{format_duration(div(mem_total, 1000))}</td></tr>
      </table>
      <div style="margin-top: 12px;">
        <form method="post" action="/debug/toggle-verbose" style="display: inline;">
          <button type="submit" class="btn btn-secondary btn-sm">#{toggle_label}</button>
        </form>
      </div>
    </div>
    """

    connection_card <> commands_card <> errors_card <> sources_card <> odbc_card <> system_card
  end

  # ── SVG Icons ──

  defp svg_icon(:dashboard) do
    ~s(<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><rect x="1" y="1" width="6" height="6" rx="1"/><rect x="9" y="1" width="6" height="3" rx="1"/><rect x="9" y="6" width="6" height="9" rx="1"/><rect x="1" y="9" width="6" height="6" rx="1"/></svg>)
  end

  defp svg_icon(:cloud) do
    ~s(<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M4 12a3 3 0 0 1-.5-5.96A5 5 0 0 1 13 7a3 3 0 0 1-1 5.83H4z"/></svg>)
  end

  defp svg_icon(:database) do
    ~s(<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><ellipse cx="8" cy="4" rx="5" ry="2"/><path d="M3 4v8c0 1.1 2.24 2 5 2s5-.9 5-2V4"/><path d="M3 8c0 1.1 2.24 2 5 2s5-.9 5-2"/></svg>)
  end

  defp svg_icon(:terminal) do
    ~s(<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><rect x="1" y="2" width="14" height="12" rx="2"/><path d="M4 6l2.5 2L4 10"/><path d="M8 10h4"/></svg>)
  end

  defp svg_icon(:link) do
    ~s(<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M6.5 9.5a3.5 3.5 0 0 0 5 0l2-2a3.5 3.5 0 0 0-5-5l-1 1"/><path d="M9.5 6.5a3.5 3.5 0 0 0-5 0l-2 2a3.5 3.5 0 0 0 5 5l1-1"/></svg>)
  end

  defp svg_icon(:settings) do
    ~s(<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><circle cx="8" cy="8" r="2"/><path d="M8 1v2m0 10v2M1 8h2m10 0h2m-1.5-5-1.4 1.4M4.9 11.1 3.5 12.5m9 0-1.4-1.4M4.9 4.9 3.5 3.5"/></svg>)
  end

  defp svg_icon(:history) do
    ~s(<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><circle cx="8" cy="8" r="6"/><path d="M8 4v4l2.5 1.5"/></svg>)
  end

  defp svg_icon(:refresh) do
    ~s(<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" style="width:14px;height:14px"><path d="M1 2v4h4"/><path d="M2.5 10A5.5 5.5 0 1 0 3 5l-2 1"/></svg>)
  end

  defp svg_icon(:check) do
    ~s(<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" style="width:14px;height:14px"><path d="M3 8l3.5 3.5L13 5"/></svg>)
  end

  defp svg_icon(:alert) do
    ~s(<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" style="width:16px;height:16px;flex-shrink:0"><path d="M8 1L1 14h14L8 1z"/><path d="M8 6v3"/><circle cx="8" cy="11.5" r="0.5" fill="currentColor"/></svg>)
  end

  defp svg_icon(:info) do
    ~s(<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" style="width:16px;height:16px;flex-shrink:0"><circle cx="8" cy="8" r="6"/><path d="M8 7v4"/><circle cx="8" cy="5" r="0.5" fill="currentColor"/></svg>)
  end

  # ── Badges ──

  defp badge(:success, text), do: ~s(<span class="badge badge-success">#{escape(text)}</span>)
  defp badge(:danger, text), do: ~s(<span class="badge badge-danger">#{escape(text)}</span>)
  defp badge(:warning, text), do: ~s(<span class="badge badge-warning">#{escape(text)}</span>)

  # ── Status translation ──

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

  defp load_base_url do
    case PyrolisConnector.State.get_setting("base_url") do
      {:ok, url} when is_binary(url) and url != "" -> url
      _ -> ""
    end
  end

  defp resolve_base_url do
    stored = load_base_url()

    cond do
      stored != "" -> stored
      System.get_env("PYROLIS_BASE_URL") -> System.get_env("PYROLIS_BASE_URL")
      true -> @default_base_url
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

  @doc false
  defp build_tenant_url(subdomain, path) do
    base_url = resolve_base_url()
    uri = URI.parse(base_url)
    host = "#{subdomain}.#{uri.host}"

    port_part =
      case {uri.scheme, uri.port} do
        {"https", 443} -> ""
        {"http", 80} -> ""
        {_, nil} -> ""
        {_, port} -> ":#{port}"
      end

    "#{uri.scheme}://#{host}#{port_part}#{path}"
  end
end
