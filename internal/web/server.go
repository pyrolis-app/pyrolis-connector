package web

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/pyrolis-app/pyrolis-connector/internal/config"
	"github.com/pyrolis-app/pyrolis-connector/internal/db"
	"github.com/pyrolis-app/pyrolis-connector/internal/relay"
	"github.com/pyrolis-app/pyrolis-connector/internal/updater"
)

// Server is the local web UI HTTP server.
type Server struct {
	port    int
	relay   *relay.Relay
	dbMgr   *db.Manager
	updater *updater.Updater
	version string
	mux     *http.ServeMux
}

// NewServer creates a new web server.
func NewServer(port int, r *relay.Relay, dbMgr *db.Manager, upd *updater.Updater, version string) *Server {
	s := &Server{
		port:    port,
		relay:   r,
		dbMgr:   dbMgr,
		updater: upd,
		version: version,
		mux:     http.NewServeMux(),
	}
	s.registerRoutes()
	return s
}

// Start starts the HTTP server. Blocks until context is cancelled.
func (s *Server) Start(ctx context.Context) error {
	addr := fmt.Sprintf(":%d", s.port)
	srv := &http.Server{
		Addr:    addr,
		Handler: s.mux,
	}

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		srv.Shutdown(shutdownCtx)
	}()

	slog.Info("Web UI listening", "port", s.port)
	if err := srv.ListenAndServe(); err != http.ErrServerClosed {
		return err
	}
	return nil
}

// templateData returns common template data.
func (s *Server) templateData(r *http.Request) map[string]interface{} {
	cfg := config.Get()
	configured := cfg != nil && cfg.Configured()

	return map[string]interface{}{
		"Version":    s.version,
		"Configured": configured,
		"Config":     cfg,
		"Port":       s.port,
	}
}
