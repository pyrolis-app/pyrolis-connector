//go:build !windows

package updater

import (
	"fmt"
	"log/slog"
	"os"
	"syscall"
)

// selfUpdate replaces the current binary and re-execs.
// On Unix, os.Rename over a running binary works because the kernel
// keeps the old inode open until the process exits. Then syscall.Exec
// replaces the process in-place with the new binary.
func selfUpdate(newBinaryPath string) error {
	currentBinary, err := os.Executable()
	if err != nil {
		return fmt.Errorf("get executable path: %w", err)
	}

	// Make the new binary executable
	if err := os.Chmod(newBinaryPath, 0755); err != nil {
		return fmt.Errorf("chmod: %w", err)
	}

	// Replace the current binary
	if err := os.Rename(newBinaryPath, currentBinary); err != nil {
		return fmt.Errorf("rename: %w", err)
	}

	slog.Info("Binary replaced, re-executing...", "path", currentBinary)

	// Re-exec: replaces this process with the new binary
	return syscall.Exec(currentBinary, os.Args, os.Environ())
}
