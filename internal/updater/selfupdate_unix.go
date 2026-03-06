//go:build !windows

package updater

import (
	"fmt"
	"io"
	"log/slog"
	"os"
	"syscall"
)

// selfUpdate replaces the current binary and re-execs.
// On Unix, overwriting a running binary works because the kernel
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

	// Try rename first (fast, same filesystem), fall back to copy (cross-filesystem)
	if err := os.Rename(newBinaryPath, currentBinary); err != nil {
		slog.Info("Rename failed (cross-filesystem?), falling back to copy", "error", err)
		if err := copyFile(newBinaryPath, currentBinary); err != nil {
			return fmt.Errorf("copy: %w", err)
		}
		os.Remove(newBinaryPath)
	}

	slog.Info("Binary replaced, re-executing...", "path", currentBinary)

	// Re-exec: replaces this process with the new binary
	return syscall.Exec(currentBinary, os.Args, os.Environ())
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0755)
	if err != nil {
		return err
	}
	defer out.Close()

	_, err = io.Copy(out, in)
	return err
}
