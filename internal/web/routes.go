package web

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"runtime"
	"strings"
	"time"

	"github.com/pyrolis-app/pyrolis-connector/internal/config"
	"github.com/pyrolis-app/pyrolis-connector/internal/i18n"
)

func (s *Server) registerRoutes() {
	s.mux.HandleFunc("/", s.handleDashboard)
	s.mux.HandleFunc("/setup", s.handleSetup)
	s.mux.HandleFunc("/pair", s.handlePair)
	s.mux.HandleFunc("/sources/new", s.handleSourceForm)
	s.mux.HandleFunc("/sources/edit/", s.handleSourceEdit)
	s.mux.HandleFunc("/sources", s.handleSourceSave)
	s.mux.HandleFunc("/sources/delete", s.handleSourceDelete)
	s.mux.HandleFunc("/test-source", s.handleTestSource)
	s.mux.HandleFunc("/test-connection", s.handleTestConnection)
	s.mux.HandleFunc("/debug", s.handleDebug)
	s.mux.HandleFunc("/api/status", s.handleAPIStatus)
	s.mux.HandleFunc("/api/update-status", s.handleAPIUpdateStatus)
	s.mux.HandleFunc("/update/check", s.handleUpdateCheck)
	s.mux.HandleFunc("/update/toggle-remote", s.handleToggleRemote)
	s.mux.HandleFunc("/update/toggle-logs", s.handleToggleLogs)
	s.mux.HandleFunc("/update/set-mode", s.handleSetMode)
}

// --- Dashboard ---

func (s *Server) handleDashboard(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		s.handle404(w, r)
		return
	}
	s.setLocale(r)

	cfg := config.Get()
	status := s.relay.GetStatus()

	var lastHB string
	if status.LastHeartbeatAt != nil {
		lastHB = status.LastHeartbeatAt.Format("15:04:05")
	} else {
		lastHB = i18n.T("never")
	}

	uptime := formatDuration(time.Since(status.StartedAt))

	updateState := s.updater.GetState()

	data := map[string]interface{}{
		"Version":       s.version,
		"ActiveNav":     "dashboard",
		"Configured":    cfg != nil && cfg.Configured(),
		"Config":        cfg,
		"Status":        status,
		"LastHeartbeat":  lastHB,
		"Uptime":        uptime,
		"DataSources":   cfg.DataSources,
		"DBManager":     s.dbMgr,
		"UpdateState":   updateState,
	}

	renderTemplate(w, "dashboard", dashboardTmpl, data)
}

const dashboardTmpl = `
{{if .Configured}}
<div class="card">
  <h2>` + iconCloud + ` {{t "Cloud Connection"}}</h2>
  <div class="stat-grid">
    <div class="stat-item">
      <div class="label">{{t "Connection"}}</div>
      <div class="value">{{statusDot .Status.ConnectionStatus}} {{t .Status.ConnectionStatus}}</div>
    </div>
    <div class="stat-item">
      <div class="label">{{t "Channel"}}</div>
      <div class="value">{{if .Status.ChannelJoined}}<span class="badge badge-success">{{t "Joined"}}</span>{{else}}<span class="badge badge-danger">{{t "Not joined"}}</span>{{end}}</div>
    </div>
    <div class="stat-item">
      <div class="label">{{t "Last Heartbeat"}}</div>
      <div class="value">{{.LastHeartbeat}}</div>
    </div>
    <div class="stat-item">
      <div class="label">{{t "Uptime"}}</div>
      <div class="value">{{.Uptime}}</div>
    </div>
    <div class="stat-item">
      <div class="label">{{t "Commands"}}</div>
      <div class="value">{{.Status.CommandsReceived}}</div>
    </div>
  </div>

  <table>
    <tr><td style="width:140px; color:var(--text-muted); font-weight:500;">URL</td><td class="mono">{{.Config.Cloud.URL}}</td></tr>
    <tr><td style="color:var(--text-muted); font-weight:500;">{{t "Connector ID"}}</td><td class="mono">{{.Config.Cloud.ConnectorID}}</td></tr>
    <tr><td style="color:var(--text-muted); font-weight:500;">{{t "API Key"}}</td><td class="mono">{{maskKey .Config.Cloud.APIKey}}</td></tr>
  </table>

  <div class="divider"></div>

  <div class="flex">
    <button class="btn btn-secondary btn-sm" onclick="testConnection()" id="test-conn-btn">
      ` + iconRefresh + ` {{t "Test Connection"}}
    </button>
    <span id="test-conn-result" style="font-size:13px;"></span>
  </div>
</div>
{{else}}
<div class="alert alert-warning">
  ` + iconAlert + `
  <span>{{t "Cloud Connection"}} — <a href="/setup" style="color:inherit; font-weight:600;">{{t "Set up now"}}</a></span>
</div>
{{end}}

<div class="card">
  <div class="flex-between mb-2">
    <h2>` + iconDatabase + ` {{t "Data Sources"}}</h2>
    <a href="/sources/new" class="btn btn-primary btn-sm">` + iconPlus + ` {{t "Add Source"}}</a>
  </div>
  {{if .DataSources}}
  <table>
    <thead><tr>
      <th>{{t "Name"}}</th>
      <th>{{t "Type"}}</th>
      <th>{{t "Status"}}</th>
      <th style="width:1%">{{t "Actions"}}</th>
    </tr></thead>
    <tbody>
    {{range .DataSources}}
    <tr>
      <td class="mono" style="font-weight:500;">{{.Name}}</td>
      <td>{{.DBType}}</td>
      <td>{{if .Enabled}}<span class="badge badge-success">{{t "enabled"}}</span>{{else}}<span class="badge badge-warning">{{t "disabled"}}</span>{{end}}</td>
      <td>
        <div class="actions">
          <a href="/sources/edit/{{.Name}}" class="btn btn-secondary btn-sm">` + iconEdit + ` {{t "Edit"}}</a>
          <button class="btn btn-secondary btn-sm" onclick="testSource('{{.Name}}')">` + iconZap + ` {{t "Test"}}</button>
          <form method="POST" action="/sources/delete" style="display:inline" onsubmit="return confirm('Delete {{.Name}}?')">
            <input type="hidden" name="name" value="{{.Name}}">
            <button type="submit" class="btn btn-danger btn-sm">` + iconTrash + `</button>
          </form>
        </div>
      </td>
    </tr>
    {{end}}
    </tbody>
  </table>
  {{else}}
  <div class="empty-state">{{t "No data sources configured."}} <a href="/sources/new">{{t "Add one"}}</a></div>
  {{end}}
</div>

<div class="card">
  <h2>` + iconSettings + ` {{t "Settings"}}</h2>
  <div class="toggle-row">
    <form method="POST" action="/update/toggle-remote" style="display:inline">
      <label>
        <input type="checkbox" {{if .Config.Settings.AllowRemoteUpdates}}checked{{end}} onchange="this.form.submit()">
        {{t "Remote updates"}}
      </label>
    </form>
    <span class="toggle-desc">{{t "Allow cloud to push updates"}}</span>
  </div>
  <div class="toggle-row">
    <form method="POST" action="/update/toggle-logs" style="display:inline">
      <label>
        <input type="checkbox" {{if .Config.Settings.LogStreaming}}checked{{end}} onchange="this.form.submit()">
        {{t "Log streaming"}}
      </label>
    </form>
    <span class="toggle-desc">{{t "Stream logs to cloud"}}</span>
  </div>
  <div class="toggle-row">
    <form method="POST" action="/update/set-mode" style="display:inline">
      <label style="gap:12px;">
        {{t "When pushed:"}}
        <select name="mode" onchange="this.form.submit()">
          <option value="auto" {{if eq .Config.Settings.AutoApplyMode "auto"}}selected{{end}}>{{t "Auto install"}}</option>
          <option value="download" {{if eq .Config.Settings.AutoApplyMode "download"}}selected{{end}}>{{t "Auto download"}}</option>
          <option value="manual" {{if eq .Config.Settings.AutoApplyMode "manual"}}selected{{end}}>{{t "Notify only"}}</option>
        </select>
      </label>
    </form>
  </div>
  <div class="divider"></div>

  <div class="flex-between" style="align-items:center;">
    <form method="POST" action="/update/check" style="display:inline">
      <button class="btn btn-secondary btn-sm">` + iconRefresh + ` {{t "Check for updates"}}</button>
    </form>
    <div style="font-size:13px;">
      {{if eq .UpdateState.Status "available"}}
        <span class="badge badge-warning">{{t "Update available"}}: v{{.UpdateState.AvailableVersion}}</span>
      {{else if eq .UpdateState.Status "downloading"}}
        <span class="badge badge-warning">{{t "Downloading"}} v{{.UpdateState.AvailableVersion}}...</span>
      {{else if eq .UpdateState.Status "ready"}}
        <span class="badge badge-success">v{{.UpdateState.AvailableVersion}} {{t "ready to install"}}</span>
      {{else if eq .UpdateState.Status "error"}}
        <span class="badge badge-danger">{{t "Error"}}: {{.UpdateState.Error}}</span>
      {{else if not .UpdateState.CheckedAt.IsZero}}
        <span style="color:var(--text-muted);">` + iconCheck + ` {{t "Up to date"}} <small>({{.UpdateState.CheckedAt.Format "15:04"}})</small></span>
      {{end}}
    </div>
  </div>
</div>

<script>
async function testConnection() {
  var btn = document.getElementById('test-conn-btn');
  var result = document.getElementById('test-conn-result');
  btn.disabled = true;
  result.textContent = '{{t "Testing..."}}';
  result.style.color = 'var(--text-muted)';
  try {
    var res = await fetch('/test-connection', {method:'POST'});
    var data = await res.json();
    if (data.connection_status === 'connected' && data.channel_joined) {
      result.innerHTML = '` + iconCheck + ` {{t "Connected successfully"}}';
      result.style.color = 'var(--success)';
    } else {
      result.textContent = data.connection_status;
      result.style.color = 'var(--danger)';
    }
  } catch(e) {
    result.textContent = e.message;
    result.style.color = 'var(--danger)';
  }
  btn.disabled = false;
}
function testSource(name) {
  fetch('/test-source', {method:'POST', headers:{'Content-Type':'application/x-www-form-urlencoded'}, body:'name='+encodeURIComponent(name)})
    .then(function(r){return r.json()}).then(function(d){ alert(d.result); });
}
setInterval(function(){
  fetch('/api/status').then(function(r){return r.json()}).then(function(d){
    var dots = document.querySelectorAll('.status-dot');
    // Could update status dynamically here
  });
}, 10000);
</script>
`

// --- Setup ---

func (s *Server) handleSetup(w http.ResponseWriter, r *http.Request) {
	if r.Method == "POST" {
		s.handleSetupSave(w, r)
		return
	}
	s.setLocale(r)

	cfg := config.Get()

	data := map[string]interface{}{
		"Version":     s.version,
		"ActiveNav":   "setup",
		"Error":       r.URL.Query().Get("error"),
		"Detail":      r.URL.Query().Get("detail"),
		"PairURL":     r.URL.Query().Get("url"),
		"Config":      cfg,
		"DataSources": cfg.DataSources,
		"BaseURL":     cfg.Settings.BaseURL,
	}

	renderTemplate(w, "setup", setupTmpl, data)
}

const setupTmpl = `
{{if .Error}}
<div class="alert alert-danger">
  ` + iconAlert + `
  <span>
  {{if eq .Error "invalid_code"}}{{t "Invalid or expired pairing code. Please generate a new one from the admin panel."}}
  {{else if eq .Error "invalid_format"}}{{t "Invalid format. The pairing code should look like: my-company.ABCD1234"}}
  {{else if eq .Error "connection_failed"}}{{t "Could not reach the Pyrolis server. Check your internet connection and try again."}}{{if .Detail}}<br><small>{{.Detail}}</small>{{end}}{{if .PairURL}}<br><small>URL: <code class="mono">{{.PairURL}}</code></small>{{end}}
  {{else}}{{.Error}}{{end}}
  </span>
</div>
{{end}}

<div class="card">
  <h2>` + iconCloud + ` {{t "Cloud Connection Setup"}}</h2>

  <p style="font-size:13px; color:var(--text-muted); margin-bottom:20px;">
    {{t "Enter the pairing code generated in Pyrolis Admin to connect this connector."}}
  </p>

  <form method="POST" action="/pair">
    <div class="form-group">
      <label>{{t "Pairing Code"}}</label>
      <input type="text" name="code" placeholder="{{t "e.g. my-company.ABCD1234"}}" required autocomplete="off" style="font-family:'SF Mono','JetBrains Mono',monospace; font-size:15px; letter-spacing:0.5px;">
      <div class="help">{{t "Generated in Pyrolis Admin"}} &gt; {{t "Integrations"}} &gt; {{t "Connectors"}}</div>
    </div>
    <button type="submit" class="btn btn-primary">` + iconZap + ` {{t "Pair"}}</button>
  </form>

  <div class="divider"></div>

  <details>
    <summary>{{t "Or configure manually"}}</summary>
    <form method="POST" action="/setup" style="margin-top:12px;">
      <div class="form-group">
        <label>{{t "Pyrolis URL"}}</label>
        <input type="url" name="url" placeholder="https://my-company.pyrolis.fr" value="{{if .Config}}{{.Config.Cloud.URL}}{{end}}" required>
        <div class="help">{{t "Your Pyrolis tenant URL"}}</div>
      </div>
      <div class="form-group">
        <label>{{t "API Key"}}</label>
        <input type="password" name="api_key" value="{{if .Config}}{{.Config.Cloud.APIKey}}{{end}}" required placeholder="pyrk_...">
        <div class="help">{{t "API key from the admin panel"}}</div>
      </div>
      <div class="form-group">
        <label>{{t "Connector ID"}}</label>
        <input type="text" name="connector_id" placeholder="{{t "e.g. paris-office-01"}}" value="{{if .Config}}{{.Config.Cloud.ConnectorID}}{{end}}" required>
        <div class="help">{{t "Unique identifier for this connector instance"}}</div>
      </div>

      <details style="margin-bottom:16px;">
        <summary>{{t "Advanced settings"}}</summary>
        <div class="form-group" style="margin-top:12px;">
          <label>{{t "Base Domain"}}</label>
          <input type="url" name="base_url" value="{{.BaseURL}}" placeholder="https://pyrolis.com">
          <div class="help">{{t "Override the base domain used for pairing. Leave empty to use the default (pyrolis.com). Useful for self-hosted or staging environments."}}</div>
        </div>
      </details>

      <button type="submit" class="btn btn-primary">` + iconCheck + ` {{t "Save Configuration"}}</button>
    </form>
  </details>
</div>

{{if .DataSources}}
<div class="card">
  <h2>` + iconDatabase + ` {{t "Data Sources"}}</h2>
  <table>
    <thead><tr><th>{{t "Name"}}</th><th>{{t "Type"}}</th><th style="width:1%">{{t "Actions"}}</th></tr></thead>
    <tbody>
    {{range .DataSources}}
    <tr>
      <td class="mono">{{.Name}}</td>
      <td>{{.DBType}}</td>
      <td><a href="/sources/edit/{{.Name}}" class="btn btn-secondary btn-sm">` + iconEdit + ` {{t "Edit"}}</a></td>
    </tr>
    {{end}}
    </tbody>
  </table>
</div>
{{end}}
`

func (s *Server) handleSetupSave(w http.ResponseWriter, r *http.Request) {
	r.ParseForm()

	cfg := config.Get()
	if cfg == nil {
		cfg = config.DefaultConfig()
	}

	cfg.Cloud.URL = strings.TrimRight(r.FormValue("url"), "/")
	cfg.Cloud.APIKey = r.FormValue("api_key")
	cfg.Cloud.ConnectorID = r.FormValue("connector_id")

	// Save base_url override if provided
	baseURL := strings.TrimSpace(r.FormValue("base_url"))
	cfg.Settings.BaseURL = strings.TrimRight(baseURL, "/")

	if err := config.Save(cfg); err != nil {
		slog.Error("Failed to save config", "error", err)
		http.Redirect(w, r, "/setup?error=save_failed", http.StatusSeeOther)
		return
	}

	// Trigger relay reconnect with new config
	s.relay.Reconnect()

	http.Redirect(w, r, "/", http.StatusSeeOther)
}

func (s *Server) handlePair(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		http.Redirect(w, r, "/setup", http.StatusSeeOther)
		return
	}

	r.ParseForm()
	code := strings.TrimSpace(r.FormValue("code"))

	parts := strings.SplitN(code, ".", 2)
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		http.Redirect(w, r, "/setup?error=invalid_format", http.StatusSeeOther)
		return
	}

	subdomain := parts[0]
	pairingCode := parts[1]

	// Resolve base URL for pairing
	cfg := config.Get()
	if cfg == nil {
		cfg = config.DefaultConfig()
	}
	baseURL := cfg.ResolveBaseURL()

	// Build the pairing URL: https://{subdomain}.{base_host}/connector/pair
	pairURL := buildTenantURL(baseURL, subdomain, "/connector/pair")
	slog.Info("Pairing", "url", pairURL, "base_url", baseURL)

	resp, err := http.Post(pairURL, "application/json",
		strings.NewReader(fmt.Sprintf(`{"code":"%s"}`, pairingCode)))

	if err != nil {
		http.Redirect(w, r, fmt.Sprintf("/setup?error=connection_failed&detail=%s&url=%s",
			url.QueryEscape(err.Error()), url.QueryEscape(pairURL)), http.StatusSeeOther)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode == 404 || resp.StatusCode == 410 {
		http.Redirect(w, r, "/setup?error=invalid_code", http.StatusSeeOther)
		return
	}

	if resp.StatusCode != 200 {
		http.Redirect(w, r, fmt.Sprintf("/setup?error=connection_failed&detail=HTTP+%d&url=%s",
			resp.StatusCode, url.QueryEscape(pairURL)), http.StatusSeeOther)
		return
	}

	var result struct {
		URL         string `json:"url"`
		Subdomain   string `json:"subdomain"`
		APIKey      string `json:"api_key"`
		ConnectorID string `json:"connector_id"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		http.Redirect(w, r, fmt.Sprintf("/setup?error=connection_failed&detail=%s",
			url.QueryEscape(err.Error())), http.StatusSeeOther)
		return
	}

	// If a custom base_url is set, rebuild the tenant URL from subdomain
	tenantURL := result.URL
	if result.Subdomain != "" && baseURL != "https://pyrolis.com" {
		tenantURL = strings.TrimRight(buildTenantURL(baseURL, result.Subdomain, ""), "/")
	}

	cfg.Cloud.URL = tenantURL
	cfg.Cloud.APIKey = result.APIKey
	cfg.Cloud.ConnectorID = result.ConnectorID

	if err := config.Save(cfg); err != nil {
		slog.Error("Failed to save config", "error", err)
	}

	s.relay.Reconnect()
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

// buildTenantURL constructs a URL like https://{subdomain}.{base_host}{path}
func buildTenantURL(baseURL, subdomain, path string) string {
	u, err := url.Parse(baseURL)
	if err != nil {
		return fmt.Sprintf("https://%s.pyrolis.com%s", subdomain, path)
	}
	scheme := u.Scheme
	if scheme == "" {
		scheme = "https"
	}
	host := fmt.Sprintf("%s.%s", subdomain, u.Host)
	return fmt.Sprintf("%s://%s%s", scheme, host, path)
}

// --- Data Sources ---

func (s *Server) handleSourceForm(w http.ResponseWriter, r *http.Request) {
	s.setLocale(r)
	data := map[string]interface{}{
		"Version":   s.version,
		"ActiveNav": "sources",
		"IsEdit":    false,
		"Source":    config.DataSource{Enabled: true, Config: map[string]string{}},
	}
	renderTemplate(w, "source_form", sourceFormTmpl, data)
}

func (s *Server) handleSourceEdit(w http.ResponseWriter, r *http.Request) {
	s.setLocale(r)
	name := strings.TrimPrefix(r.URL.Path, "/sources/edit/")
	cfg := config.Get()
	ds := cfg.FindDataSource(name)
	if ds == nil {
		http.Redirect(w, r, "/sources/new", http.StatusSeeOther)
		return
	}

	data := map[string]interface{}{
		"Version":   s.version,
		"ActiveNav": "sources",
		"IsEdit":    true,
		"Source":    *ds,
	}
	renderTemplate(w, "source_form", sourceFormTmpl, data)
}

const sourceFormTmpl = `
<div class="card">
  <h2>` + iconDatabase + ` {{if .IsEdit}}{{t "Edit"}} "{{.Source.Name}}"{{else}}{{t "Add Data Source"}}{{end}}</h2>
  <form method="POST" action="/sources">
    <div class="form-group">
      <label>{{t "Name"}}</label>
      {{if .IsEdit}}
        <input type="text" value="{{.Source.Name}}" disabled style="background:var(--bg);">
        <input type="hidden" name="name" value="{{.Source.Name}}">
      {{else}}
        <input type="text" name="name" placeholder="{{t "e.g. SI2A_HFSQL"}}" required>
        <div class="help">{{t "A unique name to identify this data source"}}</div>
      {{end}}
    </div>
    <div class="form-group">
      <label>{{t "Database Type"}}</label>
      <select name="db_type" id="db_type" onchange="toggleFields()">
        <option value="odbc" {{if eq .Source.DBType "odbc"}}selected{{end}}>ODBC (DSN)</option>
        <option value="mysql" {{if eq .Source.DBType "mysql"}}selected{{end}}>MySQL / MariaDB</option>
        <option value="mock" {{if eq .Source.DBType "mock"}}selected{{end}}>Mock (test data)</option>
      </select>
    </div>

    <div id="odbc-fields">
      <div class="form-group">
        <label>DSN</label>
        <input type="text" name="dsn" placeholder="{{t "e.g. SI2A_HFSQL"}}" value="{{cfgval .Source.Config "dsn"}}">
        <div class="help">{{t "ODBC Data Source Name configured on this machine"}}</div>
      </div>
      <div class="form-group">
        <label>{{t "Username"}}</label>
        <input type="text" name="uid" value="{{cfgval .Source.Config "uid"}}" autocomplete="off">
      </div>
      <div class="form-group">
        <label>{{t "Password"}}</label>
        <input type="password" name="pwd" value="{{cfgval .Source.Config "pwd"}}">
      </div>
    </div>

    <div id="mysql-fields" class="hidden">
      <div class="form-group">
        <label>{{t "Host"}}</label>
        <input type="text" name="host" value="{{cfgval .Source.Config "host"}}" placeholder="localhost">
      </div>
      <div class="form-group">
        <label>{{t "Port"}}</label>
        <input type="text" name="port" value="{{cfgval .Source.Config "port"}}" placeholder="3306">
      </div>
      <div class="form-group">
        <label>{{t "Database"}}</label>
        <input type="text" name="database" value="{{cfgval .Source.Config "database"}}" placeholder="{{t "e.g. cmms_db"}}">
      </div>
      <div class="form-group">
        <label>{{t "Username"}}</label>
        <input type="text" name="username" value="{{cfgval .Source.Config "username"}}" placeholder="root">
      </div>
      <div class="form-group">
        <label>{{t "Password"}}</label>
        <input type="password" name="mysql_password" value="{{cfgval .Source.Config "password"}}">
      </div>
    </div>

    <div id="mock-fields" class="hidden">
      <div class="alert alert-info">` + iconAlert + ` {{t "Mock mode generates realistic test data for fire safety equipment."}}</div>
      <div class="form-group">
        <label>{{t "Rows per table"}}</label>
        <input type="number" name="row_count" value="{{cfgval .Source.Config "row_count"}}" placeholder="25" min="1" max="1000">
      </div>
    </div>

    <div class="divider"></div>

    <div class="flex" style="gap:12px;">
      <button type="submit" class="btn btn-primary">` + iconCheck + ` {{t "Save"}}</button>
      <a href="/" class="btn btn-secondary">{{t "Cancel"}}</a>
    </div>
  </form>
</div>

<script>
function toggleFields() {
  var t = document.getElementById('db_type').value;
  document.getElementById('odbc-fields').className = t === 'odbc' ? '' : 'hidden';
  document.getElementById('mysql-fields').className = t === 'mysql' ? '' : 'hidden';
  document.getElementById('mock-fields').className = t === 'mock' ? '' : 'hidden';
}
toggleFields();
</script>
`

func (s *Server) handleSourceSave(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		http.Redirect(w, r, "/sources/new", http.StatusSeeOther)
		return
	}
	r.ParseForm()

	name := r.FormValue("name")
	dbType := r.FormValue("db_type")

	dsConfig := make(map[string]string)
	switch dbType {
	case "odbc":
		setIfPresent(dsConfig, "dsn", r.FormValue("dsn"))
		setIfPresent(dsConfig, "uid", r.FormValue("uid"))
		setIfPresent(dsConfig, "pwd", r.FormValue("pwd"))
	case "mysql":
		setIfPresent(dsConfig, "host", r.FormValue("host"))
		setIfPresent(dsConfig, "port", r.FormValue("port"))
		setIfPresent(dsConfig, "database", r.FormValue("database"))
		setIfPresent(dsConfig, "username", r.FormValue("username"))
		setIfPresent(dsConfig, "password", r.FormValue("mysql_password"))
	case "mock":
		setIfPresent(dsConfig, "row_count", r.FormValue("row_count"))
	}

	ds := config.DataSource{
		Name:    name,
		DBType:  dbType,
		Enabled: true,
		Config:  dsConfig,
	}

	if err := config.SaveDataSource(ds); err != nil {
		slog.Error("Failed to save data source", "error", err)
	}

	s.relay.ReportStatus()
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

func (s *Server) handleSourceDelete(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	r.ParseForm()
	name := r.FormValue("name")
	if name != "" {
		config.DeleteDataSource(name)
		s.relay.ReportStatus()
	}
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

func (s *Server) handleTestSource(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		http.Error(w, "method not allowed", 405)
		return
	}
	r.ParseForm()
	name := r.FormValue("name")

	err := s.dbMgr.Reconnect(name)
	result := "OK"
	if err != nil {
		result = fmt.Sprintf("Error: %s", err.Error())
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"result": result})
}

func (s *Server) handleTestConnection(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		http.Error(w, "method not allowed", 405)
		return
	}
	s.relay.Reconnect()
	time.Sleep(2 * time.Second)

	status := s.relay.GetStatus()
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(status)
}

// --- Debug ---

func (s *Server) handleDebug(w http.ResponseWriter, r *http.Request) {
	s.setLocale(r)

	cfg := config.Get()
	status := s.relay.GetStatus()

	var mem runtime.MemStats
	runtime.ReadMemStats(&mem)

	data := map[string]interface{}{
		"Version":      s.version,
		"ActiveNav":    "debug",
		"Config":       cfg,
		"Status":       status,
		"OS":           fmt.Sprintf("%s/%s", runtime.GOOS, runtime.GOARCH),
		"GoVersion":    runtime.Version(),
		"Memory":       fmt.Sprintf("%.1f MB", float64(mem.Alloc)/1024/1024),
		"NumGoroutine": runtime.NumGoroutine(),
		"Port":         s.port,
	}

	renderTemplate(w, "debug", debugTmpl, data)
}

const debugTmpl = `
<div class="card">
  <h2>` + iconCloud + ` {{t "Connection Details"}}</h2>
  <table>
    <tr><td style="width:180px; color:var(--text-muted); font-weight:500;">{{t "WebSocket Status"}}</td><td>{{statusDot .Status.ConnectionStatus}} {{t .Status.ConnectionStatus}}</td></tr>
    <tr><td style="color:var(--text-muted); font-weight:500;">{{t "Channel"}}</td><td>{{if .Status.ChannelJoined}}<span class="badge badge-success">{{t "Joined"}}</span>{{else}}<span class="badge badge-danger">{{t "Not joined"}}</span>{{end}}</td></tr>
    {{if .Config}}<tr><td style="color:var(--text-muted); font-weight:500;">URL</td><td class="mono">{{.Config.Cloud.URL}}</td></tr>
    <tr><td style="color:var(--text-muted); font-weight:500;">{{t "Connector ID"}}</td><td class="mono">{{.Config.Cloud.ConnectorID}}</td></tr>{{end}}
    <tr><td style="color:var(--text-muted); font-weight:500;">{{t "Commands Received"}}</td><td>{{.Status.CommandsReceived}}</td></tr>
  </table>
</div>

<div class="card">
  <h2>` + iconTerminal + ` {{t "Recent Commands"}} <span class="badge badge-success" style="margin-left:auto;">{{len .Status.RecentCommands}}</span></h2>
  {{if .Status.RecentCommands}}
  <table>
    <thead><tr><th>{{t "Request ID"}}</th><th>{{t "Data Source"}}</th><th>SQL</th><th>{{t "Time"}}</th></tr></thead>
    <tbody>
    {{range .Status.RecentCommands}}
    <tr>
      <td class="mono" style="font-size:11px; max-width:120px; overflow:hidden; text-overflow:ellipsis;">{{.RequestID}}</td>
      <td>{{.DataSource}}</td>
      <td class="mono" style="font-size:11px; max-width:300px; overflow:hidden; text-overflow:ellipsis;">{{.SQL}}</td>
      <td style="white-space:nowrap;">{{.Timestamp.Format "15:04:05"}}</td>
    </tr>
    {{end}}
    </tbody>
  </table>
  {{else}}
  <div class="empty-state">{{t "No commands received yet."}}</div>
  {{end}}
</div>

<div class="card">
  <h2>` + iconAlert + ` {{t "Recent Errors"}} <span class="badge badge-danger" style="margin-left:auto;">{{len .Status.RecentErrors}}</span></h2>
  {{if .Status.RecentErrors}}
  <table>
    <thead><tr><th>{{t "Request ID"}}</th><th>{{t "Error"}}</th><th>{{t "Time"}}</th></tr></thead>
    <tbody>
    {{range .Status.RecentErrors}}
    <tr>
      <td class="mono" style="font-size:11px;">{{.RequestID}}</td>
      <td style="color:var(--danger);">{{.Error}}</td>
      <td style="white-space:nowrap;">{{.Timestamp.Format "15:04:05"}}</td>
    </tr>
    {{end}}
    </tbody>
  </table>
  {{else}}
  <div class="empty-state">{{t "No errors recorded."}}</div>
  {{end}}
</div>

<div class="card">
  <h2>` + iconSettings + ` {{t "System Information"}}</h2>
  <table>
    <tr><td style="width:180px; color:var(--text-muted); font-weight:500;">{{t "Version"}}</td><td class="mono">{{.Version}}</td></tr>
    <tr><td style="color:var(--text-muted); font-weight:500;">{{t "Platform"}}</td><td class="mono">{{.OS}}</td></tr>
    <tr><td style="color:var(--text-muted); font-weight:500;">Go</td><td class="mono">{{.GoVersion}}</td></tr>
    <tr><td style="color:var(--text-muted); font-weight:500;">{{t "Memory"}}</td><td>{{.Memory}}</td></tr>
    <tr><td style="color:var(--text-muted); font-weight:500;">Goroutines</td><td>{{.NumGoroutine}}</td></tr>
    <tr><td style="color:var(--text-muted); font-weight:500;">{{t "Web Port"}}</td><td>{{.Port}}</td></tr>
  </table>
</div>
`

// --- API Endpoints ---

func (s *Server) handleAPIStatus(w http.ResponseWriter, r *http.Request) {
	status := s.relay.GetStatus()

	var lastHB string
	if status.LastHeartbeatAt != nil {
		lastHB = status.LastHeartbeatAt.Format("15:04:05")
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"connection_status":  status.ConnectionStatus,
		"channel_joined":     status.ChannelJoined,
		"commands_received":  status.CommandsReceived,
		"last_heartbeat_at":  lastHB,
		"uptime":             formatDuration(time.Since(status.StartedAt)),
	})
}

func (s *Server) handleAPIUpdateStatus(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(s.updater.GetState())
}

func (s *Server) handleUpdateCheck(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	// Trigger a check synchronously so the result shows on redirect
	s.updater.CheckGitHub()
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

func (s *Server) handleToggleRemote(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	cfg := config.Get()
	cfg.Settings.AllowRemoteUpdates = !cfg.Settings.AllowRemoteUpdates
	config.Save(cfg)
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

func (s *Server) handleToggleLogs(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	cfg := config.Get()
	cfg.Settings.LogStreaming = !cfg.Settings.LogStreaming
	config.Save(cfg)
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

func (s *Server) handleSetMode(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	r.ParseForm()
	mode := r.FormValue("mode")
	if mode == "auto" || mode == "download" || mode == "manual" {
		cfg := config.Get()
		cfg.Settings.AutoApplyMode = mode
		config.Save(cfg)
	}
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

// --- 404 ---

func (s *Server) handle404(w http.ResponseWriter, r *http.Request) {
	s.setLocale(r)
	w.WriteHeader(404)
	data := map[string]interface{}{
		"Version":   s.version,
		"ActiveNav": "",
	}
	renderTemplate(w, "404", `
<div class="card" style="text-align:center; padding:48px;">
  <h2 style="justify-content:center; font-size:18px; margin-bottom:8px;">404 — {{t "Page not found"}}</h2>
  <p style="color:var(--text-muted); margin-bottom:16px;">{{t "The page you are looking for does not exist."}}</p>
  <a href="/" class="btn btn-primary">` + iconDashboard + ` {{t "Dashboard"}}</a>
</div>`, data)
}

// --- Helpers ---

func (s *Server) setLocale(r *http.Request) {
	lang := i18n.DetectLocale(r.Header.Get("Accept-Language"))
	i18n.SetLocale(lang)
}

func setIfPresent(m map[string]string, key, value string) {
	if value != "" {
		m[key] = value
	}
}

func formatDuration(d time.Duration) string {
	h := int(d.Hours())
	m := int(d.Minutes()) % 60
	if h > 0 {
		return fmt.Sprintf("%dh %dm", h, m)
	}
	return fmt.Sprintf("%dm", m)
}
