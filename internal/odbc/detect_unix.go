//go:build !windows

package odbc

import (
	"os/exec"
	"strings"
)

// InstalledDrivers returns ODBC driver names on Unix via odbcinst.
func InstalledDrivers() []string {
	out, err := exec.Command("odbcinst", "-q", "-d").CombinedOutput()
	if err != nil {
		return nil
	}
	return parseBracketedOutput(string(out))
}

// AvailableDSNs returns configured DSN names on Unix via odbcinst.
func AvailableDSNs() []string {
	out, err := exec.Command("odbcinst", "-q", "-s").CombinedOutput()
	if err != nil {
		return nil
	}
	return parseBracketedOutput(string(out))
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

func parseBracketedOutput(output string) []string {
	var result []string
	for _, line := range strings.Split(output, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			name := line[1 : len(line)-1]
			if name != "" {
				result = append(result, name)
			}
		}
	}
	return result
}
