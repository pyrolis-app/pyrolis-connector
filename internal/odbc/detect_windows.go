//go:build windows

package odbc

import (
	"os/exec"
	"strings"
)

// InstalledDrivers returns ODBC driver names from the Windows Registry.
func InstalledDrivers() []string {
	out, err := exec.Command("reg", "query",
		`HKLM\SOFTWARE\ODBC\ODBCINST.INI\ODBC Drivers`).CombinedOutput()
	if err != nil {
		return nil
	}
	return parseRegValueNames(string(out))
}

// AvailableDSNs returns ODBC DSN names from the Windows Registry.
func AvailableDSNs() []string {
	system := queryRegDSNs(`HKLM\SOFTWARE\ODBC\ODBC.INI\ODBC Data Sources`)
	user := queryRegDSNs(`HKCU\SOFTWARE\ODBC\ODBC.INI\ODBC Data Sources`)

	seen := make(map[string]bool)
	var result []string
	for _, dsn := range append(system, user...) {
		if !seen[dsn] {
			seen[dsn] = true
			result = append(result, dsn)
		}
	}
	return result
}

// HFSQLDriverInstalled returns true if an HFSQL ODBC driver is detected.
func HFSQLDriverInstalled() bool {
	for _, d := range InstalledDrivers() {
		if strings.Contains(strings.ToLower(d), "hfsql") {
			return true
		}
	}
	return false
}

func queryRegDSNs(key string) []string {
	out, err := exec.Command("reg", "query", key).CombinedOutput()
	if err != nil {
		return nil
	}
	return parseRegValueNames(string(out))
}

func parseRegValueNames(output string) []string {
	var result []string
	for _, line := range strings.Split(output, "\n") {
		line = strings.TrimSpace(line)
		if strings.Contains(line, "REG_SZ") {
			parts := strings.SplitN(line, "REG_SZ", 2)
			name := strings.TrimSpace(parts[0])
			if name != "" {
				result = append(result, name)
			}
		}
	}
	return result
}
