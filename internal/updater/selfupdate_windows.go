//go:build windows

package updater

import (
	"fmt"
	"log/slog"
	"os"
	"os/exec"
)

// selfUpdate replaces the current binary and spawns a new process.
// On Windows, a running .exe can be renamed (but not deleted or overwritten).
// So we: rename current → .old, rename new → current, spawn new, exit.
func selfUpdate(newBinaryPath string) error {
	currentBinary, err := os.Executable()
	if err != nil {
		return fmt.Errorf("get executable path: %w", err)
	}

	oldBinary := currentBinary + ".old"

	// Remove previous .old if it exists
	os.Remove(oldBinary)

	// Rename running exe to .old
	if err := os.Rename(currentBinary, oldBinary); err != nil {
		return fmt.Errorf("rename current to .old: %w", err)
	}

	// Move new binary into place
	if err := os.Rename(newBinaryPath, currentBinary); err != nil {
		// Try to restore
		os.Rename(oldBinary, currentBinary)
		return fmt.Errorf("rename new binary: %w", err)
	}

	slog.Info("Binary replaced, starting new process...", "path", currentBinary)

	// Start new process with same args
	cmd := exec.Command(currentBinary, os.Args[1:]...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start new process: %w", err)
	}

	// Exit current process
	os.Exit(0)
	return nil // unreachable
}
