package web

import (
	"html/template"
	"io"
	"strings"

	"github.com/pyrolis-app/pyrolis-connector/internal/i18n"
)

var funcMap = template.FuncMap{
	"t":      i18n.T,
	"upper":  strings.ToUpper,
	"join":   strings.Join,
	"dict":   dict,
	"cfgval": cfgval,
	"statusClass": statusClass,
	"statusDot":   statusDot,
	"maskKey":     maskKey,
}

func dict(values ...interface{}) map[string]interface{} {
	m := make(map[string]interface{})
	for i := 0; i < len(values)-1; i += 2 {
		if key, ok := values[i].(string); ok {
			m[key] = values[i+1]
		}
	}
	return m
}

// cfgval safely gets a value from a map[string]string, returning "" if missing.
func cfgval(m map[string]string, key string) string {
	if m == nil {
		return ""
	}
	return m[key]
}

func statusClass(status string) string {
	switch status {
	case "connected":
		return "success"
	case "connecting", "reconnecting":
		return "warning"
	default:
		return "danger"
	}
}

func statusDot(status string) template.HTML {
	cls := statusClass(status)
	if status == "connecting" || status == "reconnecting" {
		return template.HTML(`<span class="status-dot status-dot-` + cls + ` pulse"></span>`)
	}
	return template.HTML(`<span class="status-dot status-dot-` + cls + `"></span>`)
}

// maskKey shows first 8 chars + dots for API keys.
func maskKey(key string) string {
	if len(key) <= 12 {
		return key
	}
	return key[:8] + "..."
}

// renderTemplate renders an inline template string with the given data.
func renderTemplate(w io.Writer, name, tmplStr string, data interface{}) error {
	t, err := template.New(name).Funcs(funcMap).Parse(layoutStart + tmplStr + layoutEnd)
	if err != nil {
		return err
	}
	return t.Execute(w, data)
}

// renderFragment renders a template without layout wrapper.
func renderFragment(w io.Writer, name, tmplStr string, data interface{}) error {
	t, err := template.New(name).Funcs(funcMap).Parse(tmplStr)
	if err != nil {
		return err
	}
	return t.Execute(w, data)
}

// SVG icon constants
const (
	iconDashboard = `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="7" height="7"/><rect x="14" y="3" width="7" height="7"/><rect x="3" y="14" width="7" height="7"/><rect x="14" y="14" width="7" height="7"/></svg>`
	iconCloud     = `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M18 10h-1.26A8 8 0 1 0 9 20h9a5 5 0 0 0 0-10z"/></svg>`
	iconDatabase  = `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><ellipse cx="12" cy="5" rx="9" ry="3"/><path d="M21 12c0 1.66-4 3-9 3s-9-1.34-9-3"/><path d="M3 5v14c0 1.66 4 3 9 3s9-1.34 9-3V5"/></svg>`
	iconTerminal  = `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>`
	iconRefresh   = `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="23 4 23 10 17 10"/><path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10"/></svg>`
	iconPlus      = `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>`
	iconEdit      = `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"/><path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z"/></svg>`
	iconTrash     = `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/></svg>`
	iconCheck     = `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"/></svg>`
	iconAlert     = `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/></svg>`
	iconSettings  = `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>`
	iconZap       = `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"/></svg>`
)

const layoutStart = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Pyrolis Connector</title>
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
.nav-item.active { color: white; border-bottom-color: var(--primary); }
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
.form-group input, .form-group select, .form-group textarea {
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
.alert svg { flex-shrink: 0; }
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
.status-dot-success { background: var(--success); box-shadow: 0 0 0 3px var(--success-bg); }
.status-dot-warning { background: var(--warning); box-shadow: 0 0 0 3px var(--warning-bg); animation: pulse 2s ease-in-out infinite; }
.status-dot-danger { background: var(--danger); box-shadow: 0 0 0 3px var(--danger-bg); }

@keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.4; } }

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

.mono {
  font-family: "SF Mono", "JetBrains Mono", "Fira Code", monospace;
  font-size: 12px;
}

.stat-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
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

.divider { height: 1px; background: var(--border-light); margin: 20px 0; }

.flex { display: flex; align-items: center; gap: 8px; }
.flex-between { display: flex; justify-content: space-between; align-items: center; }
.flex-wrap { flex-wrap: wrap; }
.gap-16 { gap: 16px; }
.mt-2 { margin-top: 8px; }
.mt-4 { margin-top: 16px; }
.mb-2 { margin-bottom: 8px; }
.text-muted { color: var(--text-muted); font-size: 13px; }

.empty-state {
  text-align: center;
  padding: 32px;
  color: var(--text-muted);
  font-size: 14px;
}
.empty-state a { color: var(--primary); text-decoration: none; font-weight: 500; }

.actions { display: flex; gap: 6px; align-items: center; }

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

.toggle-row {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 12px 0;
  border-bottom: 1px solid var(--border-light);
}
.toggle-row:last-child { border-bottom: none; }
.toggle-row label {
  display: flex;
  align-items: center;
  gap: 8px;
  cursor: pointer;
  font-size: 13px;
  font-weight: 500;
  color: var(--text);
}
.toggle-row .toggle-desc {
  font-size: 12px;
  color: var(--text-muted);
  margin-left: auto;
}

/* Custom checkbox */
input[type="checkbox"] {
  width: 16px;
  height: 16px;
  accent-color: var(--primary);
  cursor: pointer;
}

select {
  padding: 6px 10px;
  border: 1px solid var(--border);
  border-radius: var(--radius-sm);
  font-size: 13px;
  background: var(--surface);
  color: var(--text);
  cursor: pointer;
}
select:focus { outline: none; border-color: var(--primary); }

.hidden { display: none; }

@media (max-width: 640px) {
  .container { padding: 0 16px; }
  .stat-grid { grid-template-columns: 1fr 1fr; }
  .header { padding: 0 16px; }
  nav { padding: 0 16px; overflow-x: auto; }
}
</style>
</head>
<body>
<div class="header">
  <div class="header-logo">
    <svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 2L2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5"/></svg>
    <h1>Pyrolis Connector</h1>
  </div>
  <span class="version">v{{.Version}}</span>
</div>
<nav>
  <a href="/" class="nav-item {{if eq .ActiveNav "dashboard"}}active{{end}}">` + iconDashboard + ` {{t "Dashboard"}}</a>
  <a href="/setup" class="nav-item {{if eq .ActiveNav "setup"}}active{{end}}">` + iconCloud + ` {{t "Cloud Setup"}}</a>
  <a href="/sources/new" class="nav-item {{if eq .ActiveNav "sources"}}active{{end}}">` + iconDatabase + ` {{t "Data Sources"}}</a>
  <a href="/debug" class="nav-item {{if eq .ActiveNav "debug"}}active{{end}}">` + iconTerminal + ` {{t "Debug"}}</a>
</nav>
<div class="container">
`

const layoutEnd = `
</div>
</body>
</html>`
