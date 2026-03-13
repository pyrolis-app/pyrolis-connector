package db

import (
	"database/sql"
	"fmt"
	"time"

	_ "github.com/go-sql-driver/mysql"
)

// MySQLDriver connects to MySQL/MariaDB databases.
type MySQLDriver struct {
	db *sql.DB
}

// NewMySQLDriver creates a new MySQL driver.
func NewMySQLDriver() *MySQLDriver {
	return &MySQLDriver{}
}

func (d *MySQLDriver) Connect(cfg map[string]string) error {
	host := cfg["host"]
	if host == "" {
		host = "localhost"
	}
	port := cfg["port"]
	if port == "" {
		port = "3306"
	}
	database := cfg["database"]
	username := cfg["username"]
	if username == "" {
		username = "root"
	}
	password := cfg["password"]

	dsn := fmt.Sprintf("%s:%s@tcp(%s:%s)/%s?charset=utf8mb4&parseTime=true",
		username, password, host, port, database)

	db, err := sql.Open("mysql", dsn)
	if err != nil {
		return fmt.Errorf("open mysql: %w", err)
	}

	if err := db.Ping(); err != nil {
		db.Close()
		return fmt.Errorf("ping mysql: %w", err)
	}

	// Connection pool limits to prevent unbounded growth
	d.db.SetMaxOpenConns(5)
	d.db.SetMaxIdleConns(2)
	d.db.SetConnMaxLifetime(30 * time.Minute)

	d.db = db
	return nil
}

func (d *MySQLDriver) Query(sqlStr string, params []interface{}) ([]string, [][]interface{}, error) {
	if d.db == nil {
		return nil, nil, fmt.Errorf("not connected")
	}

	rows, err := d.db.Query(sqlStr, params...)
	if err != nil {
		return nil, nil, fmt.Errorf("mysql query: %w", err)
	}
	defer rows.Close()

	columns, err := rows.Columns()
	if err != nil {
		return nil, nil, fmt.Errorf("mysql columns: %w", err)
	}

	var result [][]interface{}
	for rows.Next() {
		values := make([]interface{}, len(columns))
		scanArgs := make([]interface{}, len(columns))
		for i := range values {
			scanArgs[i] = &values[i]
		}

		if err := rows.Scan(scanArgs...); err != nil {
			return nil, nil, fmt.Errorf("mysql scan: %w", err)
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

func (d *MySQLDriver) QueryStream(sqlStr string, params []interface{}, cb RowCallback) ([]string, error) {
	if d.db == nil {
		return nil, fmt.Errorf("not connected")
	}

	rows, err := d.db.Query(sqlStr, params...)
	if err != nil {
		return nil, fmt.Errorf("mysql query: %w", err)
	}
	defer rows.Close()

	columns, err := rows.Columns()
	if err != nil {
		return nil, fmt.Errorf("mysql columns: %w", err)
	}

	for rows.Next() {
		values := make([]interface{}, len(columns))
		scanArgs := make([]interface{}, len(columns))
		for i := range values {
			scanArgs[i] = &values[i]
		}

		if err := rows.Scan(scanArgs...); err != nil {
			return columns, fmt.Errorf("mysql scan: %w", err)
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

func (d *MySQLDriver) Connected() bool {
	if d.db == nil {
		return false
	}
	return d.db.Ping() == nil
}

func (d *MySQLDriver) Close() error {
	if d.db != nil {
		return d.db.Close()
	}
	return nil
}
