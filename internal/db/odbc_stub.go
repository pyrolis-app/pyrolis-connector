//go:build !windows

package db

import "fmt"

// ODBCDriver is a stub on non-Windows platforms.
type ODBCDriver struct{}

// NewODBCDriver creates a new ODBC driver (unsupported on this platform).
func NewODBCDriver() *ODBCDriver {
	return &ODBCDriver{}
}

func (d *ODBCDriver) Connect(cfg map[string]string) error {
	return fmt.Errorf("ODBC is only supported on Windows")
}

func (d *ODBCDriver) Query(sql string, params []interface{}) ([]string, [][]interface{}, error) {
	return nil, nil, fmt.Errorf("ODBC is only supported on Windows")
}

func (d *ODBCDriver) Connected() bool {
	return false
}

func (d *ODBCDriver) Close() error {
	return nil
}
