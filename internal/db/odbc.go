//go:build windows

package db

import (
	"fmt"
	"strings"
	"syscall"
	"unicode/utf16"
	"unsafe"
)

var (
	odbc32             = syscall.NewLazyDLL("odbc32.dll")
	procSQLAllocHandle = odbc32.NewProc("SQLAllocHandle")
	procSQLFreeHandle  = odbc32.NewProc("SQLFreeHandle")
	procSQLSetEnvAttr  = odbc32.NewProc("SQLSetEnvAttr")
	procSQLDriverConnW = odbc32.NewProc("SQLDriverConnectW")
	procSQLExecDirectW = odbc32.NewProc("SQLExecDirectW")
	procSQLFetch       = odbc32.NewProc("SQLFetch")
	procSQLNumResultCols = odbc32.NewProc("SQLNumResultCols")
	procSQLDescribeColW  = odbc32.NewProc("SQLDescribeColW")
	procSQLGetData       = odbc32.NewProc("SQLGetData")
	procSQLDisconnect    = odbc32.NewProc("SQLDisconnect")
	procSQLCloseCursor   = odbc32.NewProc("SQLCloseCursor")
)

const (
	sqlHandleEnv  = 1
	sqlHandleDBC  = 2
	sqlHandleStmt = 3

	sqlSuccess         = 0
	sqlSuccessWithInfo = 1
	sqlNoData          = 100
	sqlNullHandle      = 0
	sqlNTS             = -3
	sqlNullData        = -1

	sqlAttrODBCVersion = 200
	sqlOVODBC3         = 3

	sqlDriverNoPrompt = 0

	sqlCharType      = 1
	sqlWVarCharType  = -9
	sqlCWChar        = -8
)

func sqlOK(ret uintptr) bool {
	return ret == sqlSuccess || ret == sqlSuccessWithInfo
}

// ODBCDriver connects to databases via ODBC using SQLExecDirect.
type ODBCDriver struct {
	hEnv  uintptr
	hDBC  uintptr
	connected bool
}

func NewODBCDriver() *ODBCDriver {
	return &ODBCDriver{}
}

func (d *ODBCDriver) Connect(cfg map[string]string) error {
	dsn := cfg["dsn"]
	if dsn == "" {
		return fmt.Errorf("ODBC dsn is required")
	}

	var parts []string
	parts = append(parts, "DSN="+dsn)
	if uid := cfg["uid"]; uid != "" {
		parts = append(parts, "UID="+uid)
	}
	if pwd := cfg["pwd"]; pwd != "" {
		parts = append(parts, "PWD="+pwd)
	}
	connStr := strings.Join(parts, ";")

	// Allocate environment handle
	ret, _, _ := procSQLAllocHandle.Call(sqlHandleEnv, sqlNullHandle, uintptr(unsafe.Pointer(&d.hEnv)))
	if !sqlOK(ret) {
		return fmt.Errorf("SQLAllocHandle(ENV) failed: %d", ret)
	}

	// Set ODBC version
	ret, _, _ = procSQLSetEnvAttr.Call(d.hEnv, sqlAttrODBCVersion, sqlOVODBC3, 0)
	if !sqlOK(ret) {
		return fmt.Errorf("SQLSetEnvAttr failed: %d", ret)
	}

	// Allocate connection handle
	ret, _, _ = procSQLAllocHandle.Call(sqlHandleDBC, d.hEnv, uintptr(unsafe.Pointer(&d.hDBC)))
	if !sqlOK(ret) {
		return fmt.Errorf("SQLAllocHandle(DBC) failed: %d", ret)
	}

	// Connect
	connUTF16 := utf16Str(connStr)
	var outBuf [1024]uint16
	var outLen int16
	ret, _, _ = procSQLDriverConnW.Call(
		d.hDBC,
		0, // no window handle
		uintptr(unsafe.Pointer(&connUTF16[0])),
		uintptr(len(connUTF16)),
		uintptr(unsafe.Pointer(&outBuf[0])),
		uintptr(len(outBuf)),
		uintptr(unsafe.Pointer(&outLen)),
		sqlDriverNoPrompt,
	)
	if !sqlOK(ret) {
		return fmt.Errorf("SQLDriverConnect failed: %d", ret)
	}

	d.connected = true
	return nil
}

func (d *ODBCDriver) Query(sqlStr string, params []interface{}) ([]string, [][]interface{}, error) {
	if !d.connected {
		return nil, nil, fmt.Errorf("not connected")
	}

	// Allocate statement handle
	var hStmt uintptr
	ret, _, _ := procSQLAllocHandle.Call(sqlHandleStmt, d.hDBC, uintptr(unsafe.Pointer(&hStmt)))
	if !sqlOK(ret) {
		return nil, nil, fmt.Errorf("SQLAllocHandle(STMT) failed: %d", ret)
	}
	defer procSQLFreeHandle.Call(sqlHandleStmt, hStmt)

	// Execute directly (no prepare — avoids HFSQL parameter counting issues)
	sqlUTF16 := utf16Str(sqlStr)
	ret, _, _ = procSQLExecDirectW.Call(
		hStmt,
		uintptr(unsafe.Pointer(&sqlUTF16[0])),
		^uintptr(2), // SQL_NTS = -3 as uintptr (two's complement)
	)
	if !sqlOK(ret) {
		return nil, nil, fmt.Errorf("SQLExecDirect failed: %d", ret)
	}

	// Get column count
	var numCols int16
	ret, _, _ = procSQLNumResultCols.Call(hStmt, uintptr(unsafe.Pointer(&numCols)))
	if !sqlOK(ret) {
		return nil, nil, fmt.Errorf("SQLNumResultCols failed: %d", ret)
	}

	// Get column names
	columns := make([]string, numCols)
	for i := int16(0); i < numCols; i++ {
		var nameBuf [256]uint16
		var nameLen, dataType, decimalDigits, nullable int16
		var colSize uint64
		procSQLDescribeColW.Call(
			hStmt,
			uintptr(i+1),
			uintptr(unsafe.Pointer(&nameBuf[0])),
			uintptr(len(nameBuf)),
			uintptr(unsafe.Pointer(&nameLen)),
			uintptr(unsafe.Pointer(&dataType)),
			uintptr(unsafe.Pointer(&colSize)),
			uintptr(unsafe.Pointer(&decimalDigits)),
			uintptr(unsafe.Pointer(&nullable)),
		)
		columns[i] = utf16ToString(nameBuf[:nameLen])
	}

	// Fetch rows
	var result [][]interface{}
	for {
		ret, _, _ = procSQLFetch.Call(hStmt)
		if ret == sqlNoData {
			break
		}
		if !sqlOK(ret) {
			return nil, nil, fmt.Errorf("SQLFetch failed: %d", ret)
		}

		row := make([]interface{}, numCols)
		for i := int16(0); i < numCols; i++ {
			var buf [4096]byte
			var indicator int64
			ret, _, _ = procSQLGetData.Call(
				hStmt,
				uintptr(i+1),
				sqlCharType,
				uintptr(unsafe.Pointer(&buf[0])),
				uintptr(len(buf)),
				uintptr(unsafe.Pointer(&indicator)),
			)
			if !sqlOK(ret) && ret != sqlSuccessWithInfo {
				row[i] = nil
				continue
			}
			if indicator == sqlNullData || indicator < 0 {
				row[i] = nil
			} else {
				n := indicator
				if n > int64(len(buf))-1 {
					n = int64(len(buf)) - 1
				}
				row[i] = string(buf[:n])
			}
		}
		result = append(result, row)
	}

	return columns, result, nil
}

func (d *ODBCDriver) Connected() bool {
	return d.connected
}

func (d *ODBCDriver) Close() error {
	if d.connected {
		procSQLDisconnect.Call(d.hDBC)
		d.connected = false
	}
	if d.hDBC != 0 {
		procSQLFreeHandle.Call(sqlHandleDBC, d.hDBC)
		d.hDBC = 0
	}
	if d.hEnv != 0 {
		procSQLFreeHandle.Call(sqlHandleEnv, d.hEnv)
		d.hEnv = 0
	}
	return nil
}

func utf16Str(s string) []uint16 {
	return utf16.Encode([]rune(s + "\x00"))
}

func utf16ToString(s []uint16) string {
	return string(utf16.Decode(s))
}
