package db

import (
	"database/sql"
	"fmt"
	"os"
	"time"

	_ "modernc.org/sqlite"
)

// SQLiteDriver connects to SQLite database files.
type SQLiteDriver struct {
	db   *sql.DB
	path string
}

// NewSQLiteDriver creates a new SQLite driver.
func NewSQLiteDriver() *SQLiteDriver {
	return &SQLiteDriver{}
}

func (d *SQLiteDriver) Connect(cfg map[string]string) error {
	path := cfg["path"]
	if path == "" {
		return fmt.Errorf("SQLite database path is required")
	}

	// Verify the file exists
	if _, err := os.Stat(path); os.IsNotExist(err) {
		return fmt.Errorf("database file not found: %s", path)
	}

	// Open read-only with WAL mode for better concurrency
	dsn := fmt.Sprintf("file:%s?mode=ro&_journal_mode=WAL", path)
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return fmt.Errorf("open sqlite: %w", err)
	}

	if err := db.Ping(); err != nil {
		db.Close()
		return fmt.Errorf("ping sqlite: %w", err)
	}

	// Connection pool limits
	db.SetMaxOpenConns(2)
	db.SetMaxIdleConns(1)
	db.SetConnMaxLifetime(30 * time.Minute)

	d.db = db
	d.path = path
	return nil
}

func (d *SQLiteDriver) Query(sqlStr string, params []interface{}) ([]string, [][]interface{}, error) {
	if d.db == nil {
		return nil, nil, fmt.Errorf("not connected")
	}

	rows, err := d.db.Query(sqlStr, params...)
	if err != nil {
		return nil, nil, fmt.Errorf("sqlite query: %w", err)
	}
	defer rows.Close()

	columns, err := rows.Columns()
	if err != nil {
		return nil, nil, fmt.Errorf("sqlite columns: %w", err)
	}

	var result [][]interface{}
	for rows.Next() {
		values := make([]interface{}, len(columns))
		ptrs := make([]interface{}, len(columns))
		for i := range values {
			ptrs[i] = &values[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			return nil, nil, fmt.Errorf("sqlite scan: %w", err)
		}
		// Convert []byte to string for JSON serialization
		row := make([]interface{}, len(columns))
		for i, v := range values {
			if b, ok := v.([]byte); ok {
				row[i] = string(b)
			} else {
				row[i] = v
			}
		}
		result = append(result, row)
	}

	return columns, result, rows.Err()
}

func (d *SQLiteDriver) QueryStream(sqlStr string, params []interface{}, cb RowCallback) ([]string, error) {
	if d.db == nil {
		return nil, fmt.Errorf("not connected")
	}

	rows, err := d.db.Query(sqlStr, params...)
	if err != nil {
		return nil, fmt.Errorf("sqlite query: %w", err)
	}
	defer rows.Close()

	columns, err := rows.Columns()
	if err != nil {
		return nil, fmt.Errorf("sqlite columns: %w", err)
	}

	for rows.Next() {
		values := make([]interface{}, len(columns))
		ptrs := make([]interface{}, len(columns))
		for i := range values {
			ptrs[i] = &values[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			return columns, fmt.Errorf("sqlite scan: %w", err)
		}
		row := make([]interface{}, len(columns))
		for i, v := range values {
			if b, ok := v.([]byte); ok {
				row[i] = string(b)
			} else {
				row[i] = v
			}
		}
		if err := cb(row); err != nil {
			return columns, err
		}
	}

	return columns, rows.Err()
}

func (d *SQLiteDriver) Connected() bool {
	if d.db == nil {
		return false
	}
	return d.db.Ping() == nil
}

func (d *SQLiteDriver) Close() error {
	if d.db != nil {
		err := d.db.Close()
		d.db = nil
		return err
	}
	return nil
}
