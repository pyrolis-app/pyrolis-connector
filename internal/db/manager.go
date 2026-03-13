package db

import (
	"fmt"
	"log/slog"
	"regexp"
	"strings"
	"sync"

	"golang.org/x/text/encoding/charmap"
	"golang.org/x/text/transform"

	"github.com/pyrolis-app/pyrolis-connector/internal/config"
)

var selectPattern = regexp.MustCompile(`(?i)^\s*SELECT\b`)

// RowCallback is called for each row during streaming query execution.
// Returning a non-nil error aborts the query.
type RowCallback func(row []interface{}) error

// Driver is the interface each database backend must implement.
type Driver interface {
	Connect(cfg map[string]string) error
	Query(sql string, params []interface{}) (columns []string, rows [][]interface{}, err error)
	Connected() bool
	Close() error
}

// StreamingDriver is an optional interface for drivers that support row-by-row streaming.
// This avoids loading entire result sets into memory.
type StreamingDriver interface {
	Driver
	QueryStream(sql string, params []interface{}, cb RowCallback) (columns []string, err error)
}

// Manager manages database connections for multiple data sources.
type Manager struct {
	mu      sync.RWMutex
	drivers map[string]Driver
}

// NewManager creates a new database connection manager.
func NewManager() *Manager {
	return &Manager{
		drivers: make(map[string]Driver),
	}
}

// Query executes a SQL query on the named data source.
// Only SELECT queries are allowed.
func (m *Manager) Query(dataSourceName, sql string, params []interface{}) ([]string, [][]interface{}, error) {
	if !selectPattern.MatchString(sql) {
		return nil, nil, fmt.Errorf("only SELECT queries are allowed")
	}

	driver, err := m.ensureConnection(dataSourceName)
	if err != nil {
		return nil, nil, err
	}

	// Look up data source config for encoding
	cfg := config.Get()
	var ds *config.DataSource
	if cfg != nil {
		ds = cfg.FindDataSource(dataSourceName)
	}

	columns, rows, err := driver.Query(sql, params)
	if err != nil {
		// Remove stale connection so it reconnects next time
		m.mu.Lock()
		delete(m.drivers, dataSourceName)
		m.mu.Unlock()
		return nil, nil, err
	}

	// Convert encoding if configured
	if ds != nil && ds.Config["encoding"] != "" {
		rows, err = convertEncoding(ds.Config["encoding"], rows)
		if err != nil {
			slog.Warn("Encoding conversion failed, returning raw data", "encoding", ds.Config["encoding"], "error", err)
		}
	}

	return columns, rows, nil
}

// QueryStream executes a SQL query and streams rows via callback, avoiding loading everything into memory.
// Falls back to Query + iteration if the driver doesn't support streaming.
func (m *Manager) QueryStream(dataSourceName, sql string, params []interface{}, cb RowCallback) ([]string, error) {
	if !selectPattern.MatchString(sql) {
		return nil, fmt.Errorf("only SELECT queries are allowed")
	}

	driver, err := m.ensureConnection(dataSourceName)
	if err != nil {
		return nil, err
	}

	// Look up data source config for encoding
	cfg := config.Get()
	var ds *config.DataSource
	if cfg != nil {
		ds = cfg.FindDataSource(dataSourceName)
	}

	// Wrap callback with encoding conversion if needed
	wrappedCB := cb
	if ds != nil && ds.Config["encoding"] != "" {
		cm := lookupEncoding(ds.Config["encoding"])
		if cm != nil {
			decoder := cm.NewDecoder()
			wrappedCB = func(row []interface{}) error {
				for j, val := range row {
					if s, ok := val.(string); ok {
						decoded, _, err := transform.String(decoder, s)
						if err == nil {
							row[j] = decoded
						}
					}
				}
				return cb(row)
			}
		}
	}

	// Use streaming driver if available
	if sd, ok := driver.(StreamingDriver); ok {
		columns, err := sd.QueryStream(sql, params, wrappedCB)
		if err != nil {
			// Remove stale connection so it reconnects next time
			m.mu.Lock()
			delete(m.drivers, dataSourceName)
			m.mu.Unlock()
			return nil, err
		}
		return columns, nil
	}

	// Fallback: use Query and iterate
	columns, rows, err := driver.Query(sql, params)
	if err != nil {
		m.mu.Lock()
		delete(m.drivers, dataSourceName)
		m.mu.Unlock()
		return nil, err
	}

	// Convert encoding if configured (for non-streaming path)
	if ds != nil && ds.Config["encoding"] != "" {
		rows, _ = convertEncoding(ds.Config["encoding"], rows)
	}

	for _, row := range rows {
		if err := cb(row); err != nil {
			return columns, err
		}
	}
	return columns, nil
}

// Connected returns true if the named data source has an active connection.
func (m *Manager) Connected(name string) bool {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if d, ok := m.drivers[name]; ok {
		return d.Connected()
	}
	return false
}

// ListConnections returns the names of all connected data sources.
func (m *Manager) ListConnections() []string {
	m.mu.RLock()
	defer m.mu.RUnlock()
	names := make([]string, 0, len(m.drivers))
	for name, d := range m.drivers {
		if d.Connected() {
			names = append(names, name)
		}
	}
	return names
}

// Reconnect closes and re-establishes a connection.
func (m *Manager) Reconnect(name string) error {
	m.mu.Lock()
	if d, ok := m.drivers[name]; ok {
		d.Close()
		delete(m.drivers, name)
	}
	m.mu.Unlock()

	_, err := m.ensureConnection(name)
	return err
}

// Close closes all connections.
func (m *Manager) Close() {
	m.mu.Lock()
	defer m.mu.Unlock()
	for name, d := range m.drivers {
		d.Close()
		delete(m.drivers, name)
	}
}

func (m *Manager) ensureConnection(name string) (Driver, error) {
	m.mu.RLock()
	if d, ok := m.drivers[name]; ok {
		m.mu.RUnlock()
		return d, nil
	}
	m.mu.RUnlock()

	// Load data source config
	cfg := config.Get()
	if cfg == nil {
		return nil, fmt.Errorf("config not loaded")
	}

	ds := cfg.FindDataSource(name)
	if ds == nil {
		return nil, fmt.Errorf("data source '%s' not configured", name)
	}

	return m.connect(name, ds)
}

// lookupEncoding returns the charmap decoder for the given encoding name, or nil if UTF-8/unknown.
// Supported: iso-8859-1, iso-8859-15, windows-1252.
func lookupEncoding(name string) *charmap.Charmap {
	switch strings.ToLower(strings.TrimSpace(name)) {
	case "iso-8859-1", "iso8859-1", "latin1", "latin-1":
		return charmap.ISO8859_1
	case "iso-8859-15", "iso8859-15", "latin9", "latin-9":
		return charmap.ISO8859_15
	case "windows-1252", "cp1252", "win1252":
		return charmap.Windows1252
	default:
		return nil
	}
}

// convertEncoding converts all string values in rows from the given encoding to UTF-8.
func convertEncoding(enc string, rows [][]interface{}) ([][]interface{}, error) {
	cm := lookupEncoding(enc)
	if cm == nil {
		return rows, fmt.Errorf("unsupported encoding: %s", enc)
	}
	decoder := cm.NewDecoder()

	for i, row := range rows {
		for j, val := range row {
			if s, ok := val.(string); ok {
				decoded, _, err := transform.String(decoder, s)
				if err != nil {
					// Keep original on error
					continue
				}
				rows[i][j] = decoded
			}
		}
	}
	return rows, nil
}

func (m *Manager) connect(name string, ds *config.DataSource) (Driver, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	// Double-check after acquiring write lock
	if d, ok := m.drivers[name]; ok {
		return d, nil
	}

	slog.Info("Connecting to data source", "name", name, "type", ds.DBType)

	var driver Driver
	switch ds.DBType {
	case "mock":
		driver = NewMockDriver()
	case "mysql":
		driver = NewMySQLDriver()
	case "sqlite":
		driver = NewSQLiteDriver()
	case "odbc":
		driver = NewODBCDriver()
	default:
		return nil, fmt.Errorf("unsupported database type: %s", ds.DBType)
	}

	if err := driver.Connect(ds.Config); err != nil {
		return nil, fmt.Errorf("connect to '%s': %w", name, err)
	}

	slog.Info("Connected to data source", "name", name)
	m.drivers[name] = driver
	return driver, nil
}
