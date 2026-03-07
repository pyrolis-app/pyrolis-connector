//go:build windows

package db

import (
	"database/sql"
	"fmt"
	"strings"

	_ "github.com/alexbrainman/odbc"
)

// ODBCDriver connects to databases via ODBC DSN.
type ODBCDriver struct {
	db *sql.DB
}

// NewODBCDriver creates a new ODBC driver.
func NewODBCDriver() *ODBCDriver {
	return &ODBCDriver{}
}

func (d *ODBCDriver) Connect(cfg map[string]string) error {
	dsn := cfg["dsn"]
	if dsn == "" {
		return fmt.Errorf("ODBC dsn is required")
	}

	// Build connection string: DSN=xxx;UID=xxx;PWD=xxx
	var parts []string
	parts = append(parts, "DSN="+dsn)
	if uid := cfg["uid"]; uid != "" {
		parts = append(parts, "UID="+uid)
	}
	if pwd := cfg["pwd"]; pwd != "" {
		parts = append(parts, "PWD="+pwd)
	}
	connStr := strings.Join(parts, ";")

	db, err := sql.Open("odbc", connStr)
	if err != nil {
		return fmt.Errorf("open odbc: %w", err)
	}

	if err := db.Ping(); err != nil {
		db.Close()
		return fmt.Errorf("ping odbc: %w", err)
	}

	d.db = db
	return nil
}

func (d *ODBCDriver) Query(sqlStr string, params []interface{}) ([]string, [][]interface{}, error) {
	if d.db == nil {
		return nil, nil, fmt.Errorf("not connected")
	}

	rows, err := d.db.Query(sqlStr, params...)
	if err != nil {
		return nil, nil, fmt.Errorf("odbc query: %w", err)
	}
	defer rows.Close()

	columns, err := rows.Columns()
	if err != nil {
		return nil, nil, fmt.Errorf("odbc columns: %w", err)
	}

	var result [][]interface{}
	for rows.Next() {
		values := make([]interface{}, len(columns))
		scanArgs := make([]interface{}, len(columns))
		for i := range values {
			scanArgs[i] = &values[i]
		}

		if err := rows.Scan(scanArgs...); err != nil {
			return nil, nil, fmt.Errorf("odbc scan: %w", err)
		}

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

func (d *ODBCDriver) Connected() bool {
	if d.db == nil {
		return false
	}
	return d.db.Ping() == nil
}

func (d *ODBCDriver) Close() error {
	if d.db != nil {
		return d.db.Close()
	}
	return nil
}
