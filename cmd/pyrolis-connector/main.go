package main

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"syscall"
	"time"

	"github.com/kardianos/service"

	"github.com/pyrolis-app/pyrolis-connector/internal/config"
	"github.com/pyrolis-app/pyrolis-connector/internal/db"
	"github.com/pyrolis-app/pyrolis-connector/internal/logfwd"
	"github.com/pyrolis-app/pyrolis-connector/internal/relay"
	syncer "github.com/pyrolis-app/pyrolis-connector/internal/sync"
	"github.com/pyrolis-app/pyrolis-connector/internal/tray"
	"github.com/pyrolis-app/pyrolis-connector/internal/updater"
	"github.com/pyrolis-app/pyrolis-connector/internal/web"
)

var version = "0.0.0-dev"

// querySem limits concurrent query goroutines to prevent memory explosion.
var querySem = make(chan struct{}, 3)

// program implements the kardianos/service.Interface.
type program struct {
	ctx    context.Context
	cancel context.CancelFunc
	relay  *relay.Relay
	dbMgr  *db.Manager
	upd    *updater.Updater
	logFwd *logfwd.Forwarder
	webSrv *web.Server
	tray   *tray.Tray
	port   int
}

func main() {
	args := os.Args[1:]

	// Handle non-service commands first
	if len(args) > 0 {
		switch args[0] {
		case "help", "--help", "-h":
			printHelp()
			return
		case "version", "--version", "-v":
			fmt.Printf("pyrolis-connector v%s\n", version)
			return
		case "sync":
			runSync(args[1:])
			return
		}
	}

	// Set up structured logging
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	})))

	// Configure the system service
	svcConfig := &service.Config{
		Name:        "pyrolis-connector",
		DisplayName: "Pyrolis Connector",
		Description: "Syncs on-premise databases to the Pyrolis cloud platform.",
	}

	prg := &program{}
	svc, err := service.New(prg, svcConfig)
	if err != nil {
		slog.Error("Failed to create service", "error", err)
		os.Exit(1)
	}

	// Handle service control commands: install, uninstall, start, stop
	if len(args) > 0 {
		switch args[0] {
		case "install":
			if err := svc.Install(); err != nil {
				fmt.Fprintf(os.Stderr, "Failed to install service: %v\n", err)
				os.Exit(1)
			}
			fmt.Println("Service installed successfully.")
			fmt.Println("Start it with: pyrolis-connector start")
			return

		case "uninstall":
			if err := svc.Uninstall(); err != nil {
				fmt.Fprintf(os.Stderr, "Failed to uninstall service: %v\n", err)
				os.Exit(1)
			}
			fmt.Println("Service uninstalled successfully.")
			return

		case "start":
			if err := svc.Start(); err != nil {
				fmt.Fprintf(os.Stderr, "Failed to start service: %v\n", err)
				os.Exit(1)
			}
			fmt.Println("Service started.")
			return

		case "stop":
			if err := svc.Stop(); err != nil {
				fmt.Fprintf(os.Stderr, "Failed to stop service: %v\n", err)
				os.Exit(1)
			}
			fmt.Println("Service stopped.")
			return

		case "restart":
			svc.Stop()
			time.Sleep(time.Second)
			if err := svc.Start(); err != nil {
				fmt.Fprintf(os.Stderr, "Failed to start service: %v\n", err)
				os.Exit(1)
			}
			fmt.Println("Service restarted.")
			return

		case "run", "setup":
			// Fall through to Run() below
		}
	}

	// Run the service (either as a system service or interactively)
	if err := svc.Run(); err != nil {
		slog.Error("Service run failed", "error", err)
		os.Exit(1)
	}
}

func (p *program) Start(s service.Service) error {
	p.ctx, p.cancel = context.WithCancel(context.Background())

	// Load config
	cfg, err := config.Load()
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}

	// Find available port
	p.port = cfg.Settings.WebPort
	if p.port == 0 {
		p.port = 4100
	}
	p.port = findAvailablePort(p.port)

	// Create DB manager
	p.dbMgr = db.NewManager()

	// Create updater
	p.upd = updater.New(version)
	p.upd.Start()

	// Create relay, then set the handler (handler needs a reference to the relay)
	p.relay = relay.New(version, nil)

	// Create log forwarder wrapping the stderr handler, then install as global slog handler
	baseHandler := slog.Default().Handler()
	p.logFwd = logfwd.New(func(entries []map[string]interface{}) {
		p.relay.PushLogs(entries)
	}, baseHandler)
	slog.SetDefault(slog.New(p.logFwd))

	handler := newMessageHandler(p.relay, p.dbMgr, p.upd, p.logFwd)
	p.relay.SetHandler(handler)
	p.relay.RestartFunc = restartSelf
	p.relay.DBHealth = p.dbMgr

	// Start relay
	go p.relay.Start(p.ctx)

	// Start HTTP polling fallback
	poller := relay.NewPoller(p.relay, handler)
	go poller.Start(p.ctx)

	// Start web server
	p.webSrv = web.NewServer(p.port, p.relay, p.dbMgr, p.upd, version)
	go func() {
		if err := p.webSrv.Start(p.ctx); err != nil {
			slog.Error("Web server error", "error", err)
		}
	}()

	// Print banner and open browser only in interactive mode
	interactive := service.Interactive()
	if interactive {
		if cfg.Configured() {
			fmt.Printf(`
=============================================
  Pyrolis Connector v%s
  Status: Connected
  Web UI: http://localhost:%d
=============================================
`, version, p.port)
		} else {
			fmt.Printf(`
=============================================
  Pyrolis Connector v%s

  Not configured yet!
  Open http://localhost:%d/setup
=============================================
`, version, p.port)
		}

		args := os.Args[1:]
		setupRequested := len(args) > 0 && args[0] == "setup"
		if setupRequested || !cfg.Configured() {
			go openBrowser(fmt.Sprintf("http://localhost:%d/setup", p.port))
		} else {
			go openBrowser(fmt.Sprintf("http://localhost:%d", p.port))
		}
		// Start system tray (blocks in its own goroutine on desktop builds, no-op on headless)
		p.tray = tray.New(p.port, version)
		go p.tray.Run()

		// Watch for tray quit
		go func() {
			<-p.tray.QuitCh()
			slog.Info("Quit requested from system tray")
			p.cancel()
		}()
	} else {
		slog.Info("Pyrolis Connector started as service",
			"version", version, "port", p.port, "configured", cfg.Configured())
	}

	return nil
}

func (p *program) Stop(s service.Service) error {
	slog.Info("Stopping Pyrolis Connector...")
	p.cancel()
	p.dbMgr.Close()
	p.upd.Stop()
	return nil
}

// newMessageHandler creates a handler that dispatches relay messages.
func newMessageHandler(r *relay.Relay, dbMgr *db.Manager, upd *updater.Updater, logFwd *logfwd.Forwarder) relay.MessageHandler {
	return func(event string, payload map[string]interface{}) {
		switch event {
		case "query":
			go handleQuery(r, dbMgr, payload)

		case "ping":
			slog.Info("Ping received from cloud")
			r.Pong()

		case "restart":
			slog.Info("Restart command received from cloud")
			go restartSelf()

		case "update_available":
			ver, _ := payload["version"].(string)
			dlURL, _ := payload["download_url"].(string)
			cs, _ := payload["checksum"].(string)

			// Pick platform-specific asset if available
			if assets, ok := payload["platform_assets"].(map[string]interface{}); ok {
				if pa, ok := assets[updater.PlatformTarget()].(map[string]interface{}); ok {
					if u, ok := pa["download_url"].(string); ok {
						dlURL = u
					}
					if c, ok := pa["checksum"].(string); ok {
						cs = c
					}
				}
			}

			upd.NotifyAvailable(ver, dlURL, cs)

		case "configure_data_source":
			handleConfigureDataSource(payload)
			r.ReportStatus()

		case "delete_data_source":
			name, _ := payload["name"].(string)
			if name != "" {
				slog.Info("Deleting data source from cloud", "name", name)
				config.DeleteDataSource(name)
				r.ReportStatus()
			}

		case "sync_to_sqlite":
			go handleSyncToSQLite(r, dbMgr, payload)

		case "enable_logs":
			slog.Info("Log streaming enabled by cloud")
			logFwd.Enable()

		case "disable_logs":
			slog.Info("Log streaming disabled by cloud")
			logFwd.Disable()

		default:
			slog.Debug("Unhandled message", "event", event)
		}
	}
}

func handleQuery(r *relay.Relay, dbMgr *db.Manager, payload map[string]interface{}) {
	requestID, _ := payload["request_id"].(string)
	sqlStr, _ := payload["sql"].(string)
	dsName, _ := payload["data_source"].(string)

	var params []interface{}
	if p, ok := payload["params"].([]interface{}); ok {
		params = p
	}

	// Acquire semaphore to limit concurrent queries
	querySem <- struct{}{}
	defer func() { <-querySem }()

	slog.Info("Executing query", "request_id", requestID, "data_source", dsName)

	columns, rows, err := dbMgr.Query(dsName, sqlStr, params)
	if err != nil {
		slog.Error("Query failed", "request_id", requestID, "error", err)
		r.PushQueryError(requestID, err.Error())
		return
	}

	// StreamRows handles batching internally (RowBatchSize per batch)
	r.StreamRows(requestID, columns, rows)

	// Hint GC to release query memory promptly
	if len(rows) > 10000 {
		runtime.GC()
	}
}

func handleConfigureDataSource(payload map[string]interface{}) {
	name, _ := payload["name"].(string)
	dbType, _ := payload["db_type"].(string)
	enabled, _ := payload["enabled"].(bool)
	cfgMap, _ := payload["config"].(map[string]interface{})

	if name == "" {
		return
	}

	slog.Info("Configuring data source from cloud", "name", name, "db_type", dbType)

	dsConfig := make(map[string]string)
	for k, v := range cfgMap {
		dsConfig[k] = fmt.Sprint(v)
	}

	ds := config.DataSource{
		Name:    name,
		DBType:  dbType,
		Enabled: enabled,
		Config:  dsConfig,
	}

	if err := config.SaveDataSource(ds); err != nil {
		slog.Error("Failed to save data source", "error", err)
	}
}

func findAvailablePort(base int) int {
	for i := 0; i < 10; i++ {
		port := base + i
		ln, err := net.Listen("tcp", ":"+strconv.Itoa(port))
		if err == nil {
			ln.Close()
			return port
		}
		slog.Info("Port busy, trying next", "port", port)
	}
	ln, err := net.Listen("tcp", ":0")
	if err != nil {
		return base
	}
	port := ln.Addr().(*net.TCPAddr).Port
	ln.Close()
	return port
}

func openBrowser(url string) {
	time.Sleep(500 * time.Millisecond)
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "windows":
		cmd = exec.Command("cmd", "/c", "start", url)
	case "darwin":
		cmd = exec.Command("open", url)
	default:
		cmd = exec.Command("xdg-open", url)
	}
	_ = cmd.Start()
}

func restartSelf() {
	time.Sleep(1 * time.Second)

	exe, err := os.Executable()
	if err != nil {
		slog.Error("Cannot find own executable for restart", "error", err)
		os.Exit(1)
	}

	if service.Interactive() {
		// Interactive mode: replace current process
		slog.Info("Restarting process", "exe", exe)
		err = syscall.Exec(exe, os.Args, os.Environ())
		if err != nil {
			slog.Error("Failed to exec", "error", err)
			os.Exit(1)
		}
	} else {
		// Service mode: exit and let service manager restart
		os.Exit(0)
	}
}

// runSync handles the "sync" CLI subcommand.
//
//	pyrolis-connector sync <data-source> [output.db]
func runSync(args []string) {
	if len(args) < 1 {
		fmt.Fprintf(os.Stderr, "Usage: pyrolis-connector sync <data-source> [output.db]\n")
		os.Exit(1)
	}

	dataSource := args[0]
	output := dataSource + ".db"
	if len(args) >= 2 {
		output = args[1]
	}

	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	})))

	cfg, err := config.Load()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to load config: %v\n", err)
		os.Exit(1)
	}

	ds := cfg.FindDataSource(dataSource)
	if ds == nil {
		fmt.Fprintf(os.Stderr, "Data source '%s' not found in config.\nAvailable:", dataSource)
		for _, d := range cfg.DataSources {
			fmt.Fprintf(os.Stderr, " %s", d.Name)
		}
		fmt.Fprintln(os.Stderr)
		os.Exit(1)
	}

	dbMgr := db.NewManager()
	defer dbMgr.Close()

	engine := syncer.NewEngine(dataSource, func(ds, sql string, params []interface{}) ([]string, [][]interface{}, error) {
		return dbMgr.Query(ds, sql, params)
	})
	engine.SetProgressFunc(func(table string, rows int) {
		fmt.Printf("  %s: %d rows\n", table, rows)
	})

	fmt.Printf("Syncing data source '%s' → %s\n", dataSource, output)
	fmt.Printf("Tables: %d\n\n", len(syncer.SI2ATables))

	ctx := context.Background()
	result, err := engine.Run(ctx, output)
	if err != nil {
		fmt.Fprintf(os.Stderr, "\nSync failed: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("\nDone in %s: %d tables (%d rows), %d failed\n",
		result.Elapsed.Round(time.Second), result.Tables, result.Rows, result.Failed)
}

// handleSyncToSQLite handles the "sync_to_sqlite" cloud command.
func handleSyncToSQLite(r *relay.Relay, dbMgr *db.Manager, payload map[string]interface{}) {
	requestID, _ := payload["request_id"].(string)
	dataSource, _ := payload["data_source"].(string)
	outputPath, _ := payload["output"].(string)

	if dataSource == "" {
		slog.Error("sync_to_sqlite: missing data_source")
		return
	}
	if outputPath == "" {
		outputPath = dataSource + ".db"
	}

	slog.Info("Starting SQLite sync", "data_source", dataSource, "output", outputPath, "request_id", requestID)

	engine := syncer.NewEngine(dataSource, func(ds, sql string, params []interface{}) ([]string, [][]interface{}, error) {
		return dbMgr.Query(ds, sql, params)
	})
	engine.SetProgressFunc(func(table string, rows int) {
		slog.Info("Sync progress", "table", table, "rows", rows)
	})

	ctx := context.Background()
	result, err := engine.Run(ctx, outputPath)
	if err != nil {
		slog.Error("SQLite sync failed", "error", err, "request_id", requestID)
		r.Push("sync_result", map[string]interface{}{
			"request_id": requestID,
			"status":     "error",
			"error":      err.Error(),
		})
		return
	}

	slog.Info("SQLite sync complete",
		"tables", result.Tables, "rows", result.Rows,
		"failed", result.Failed, "elapsed", result.Elapsed.String(),
		"request_id", requestID)

	r.Push("sync_result", map[string]interface{}{
		"request_id": requestID,
		"status":     "complete",
		"tables":     result.Tables,
		"rows":       result.Rows,
		"failed":     result.Failed,
		"elapsed_ms": result.Elapsed.Milliseconds(),
		"output":     outputPath,
	})
}

func printHelp() {
	fmt.Printf(`Pyrolis Connector v%s

Usage: pyrolis-connector [command]

Commands:
  run                          Start the connector interactively (default)
  setup                        Start and open the setup wizard in browser
  sync <data-source> [out.db]  Sync data source to a local SQLite database
  install                      Install as a system service
  uninstall                    Remove the system service
  start                        Start the installed service
  stop                         Stop the installed service
  restart                      Restart the installed service
  help                         Show this help message
  version                      Show version

The connector starts a local web UI at http://localhost:4100
for configuration and monitoring.

Configuration is stored in:
  Linux:   ~/.config/pyrolis-connector/config.toml
  macOS:   ~/Library/Application Support/pyrolis-connector/config.toml
  Windows: %%APPDATA%%\pyrolis-connector\config.toml
`, version)
}
