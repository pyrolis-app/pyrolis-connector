package db

import (
	"fmt"
	"log/slog"
	"regexp"
	"sync"

	"github.com/pyrolis-app/pyrolis-connector/internal/config"
)

var selectPattern = regexp.MustCompile(`(?i)^\s*SELECT\b`)

// Driver is the interface each database backend must implement.
type Driver interface {
	Connect(cfg map[string]string) error
	Query(sql string, params []interface{}) (columns []string, rows [][]interface{}, err error)
	Connected() bool
	Close() error
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

	columns, rows, err := driver.Query(sql, params)
	if err != nil {
		// Remove stale connection so it reconnects next time
		m.mu.Lock()
		delete(m.drivers, dataSourceName)
		m.mu.Unlock()
		return nil, nil, err
	}

	return columns, rows, nil
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
	// case "odbc":
	//	driver = NewODBCDriver() // build-tagged
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
