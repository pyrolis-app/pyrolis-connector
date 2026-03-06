package updater

import (
	"archive/zip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/pyrolis-app/pyrolis-connector/internal/config"
)

const (
	githubReleasesAPI = "https://api.github.com/repos/pyrolis-app/pyrolis-connector/releases/latest"
	checkInterval     = 6 * time.Hour
)

// Status values
const (
	StatusIdle        = "idle"
	StatusAvailable   = "available"
	StatusDownloading = "downloading"
	StatusReady       = "ready"
	StatusApplying    = "applying"
	StatusError       = "error"
)

// State represents the current update state.
type State struct {
	Status           string    `json:"status"`
	AvailableVersion string    `json:"available_version,omitempty"`
	DownloadURL      string    `json:"download_url,omitempty"`
	Checksum         string    `json:"checksum,omitempty"`
	DownloadPath     string    `json:"download_path,omitempty"`
	Error            string    `json:"error,omitempty"`
	CheckedAt        time.Time `json:"checked_at,omitempty"`
	CurrentVersion   string    `json:"current_version"`
}

// Updater manages self-updates.
type Updater struct {
	mu      sync.RWMutex
	state   State
	version string
	stopCh  chan struct{}
}

// New creates a new Updater.
func New(version string) *Updater {
	return &Updater{
		version: version,
		state:   State{Status: StatusIdle, CurrentVersion: version},
		stopCh:  make(chan struct{}),
	}
}

// Start begins the periodic update check loop.
func (u *Updater) Start() {
	// Initial check after a short delay
	go func() {
		time.Sleep(30 * time.Second)
		u.CheckGitHub()
	}()

	go func() {
		ticker := time.NewTicker(checkInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				u.mu.RLock()
				s := u.state.Status
				u.mu.RUnlock()
				if s == StatusIdle {
					u.CheckGitHub()
				}
			case <-u.stopCh:
				return
			}
		}
	}()
}

// Stop halts periodic checks.
func (u *Updater) Stop() {
	close(u.stopCh)
}

// GetState returns the current update state.
func (u *Updater) GetState() State {
	u.mu.RLock()
	defer u.mu.RUnlock()
	s := u.state
	s.CurrentVersion = u.version
	return s
}

// NotifyAvailable is called when the cloud pushes an update notification.
func (u *Updater) NotifyAvailable(version, downloadURL, checksum string) {
	cfg := config.Get()
	if cfg != nil && !cfg.Settings.AllowRemoteUpdates {
		slog.Info("Ignoring remote update push (remote updates disabled)")
		return
	}

	if !newerVersion(version, u.version) {
		slog.Debug("Ignoring update, already at or newer", "available", version, "current", u.version)
		return
	}

	slog.Info("Update available", "version", version)

	u.mu.Lock()
	u.state = State{
		Status:           StatusAvailable,
		AvailableVersion: version,
		DownloadURL:      downloadURL,
		Checksum:         checksum,
		CurrentVersion:   u.version,
	}
	u.mu.Unlock()

	// Auto-act based on mode
	if cfg != nil {
		switch cfg.Settings.AutoApplyMode {
		case "auto":
			slog.Info("Auto-install: downloading and applying")
			go u.DownloadAndApply()
		case "download":
			slog.Info("Auto-download: downloading")
			go u.Download()
		default:
			slog.Info("Manual mode: waiting for user action")
		}
	}
}

// CheckGitHub checks GitHub releases for a newer version.
func (u *Updater) CheckGitHub() {
	slog.Debug("Checking GitHub for updates")

	u.mu.Lock()
	u.state.CheckedAt = time.Now()
	u.mu.Unlock()

	req, _ := http.NewRequest("GET", githubReleasesAPI, nil)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "pyrolis-connector")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		slog.Warn("GitHub update check failed", "error", err)
		u.mu.Lock()
		u.state.Error = fmt.Sprintf("Check failed: %v", err)
		u.mu.Unlock()
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		slog.Warn("GitHub API returned", "status", resp.StatusCode)
		return
	}

	var release struct {
		TagName string `json:"tag_name"`
		Assets  []struct {
			Name               string `json:"name"`
			BrowserDownloadURL string `json:"browser_download_url"`
		} `json:"assets"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&release); err != nil {
		slog.Warn("Failed to parse GitHub release", "error", err)
		return
	}

	version := strings.TrimPrefix(release.TagName, "pyrolis-connector-v")
	target := PlatformTarget()

	var downloadURL, checksumURL string
	for _, a := range release.Assets {
		if strings.Contains(a.Name, target) && !strings.HasSuffix(a.Name, ".txt") {
			downloadURL = a.BrowserDownloadURL
		}
		if a.Name == "SHA256SUMS.txt" {
			checksumURL = a.BrowserDownloadURL
		}
	}

	if downloadURL == "" {
		slog.Debug("No binary found for platform", "target", target)
		return
	}

	checksum := fetchChecksum(checksumURL, target)

	if newerVersion(version, u.version) {
		slog.Info("GitHub check: update available", "version", version, "current", u.version)
		u.mu.Lock()
		u.state = State{
			Status:           StatusAvailable,
			AvailableVersion: version,
			DownloadURL:      downloadURL,
			Checksum:         checksum,
			CheckedAt:        time.Now(),
			CurrentVersion:   u.version,
		}
		u.mu.Unlock()
	} else {
		slog.Debug("Already up to date", "current", u.version)
		u.mu.Lock()
		u.state.Status = StatusIdle
		u.state.Error = ""
		u.mu.Unlock()
	}
}

// Download downloads the available update.
func (u *Updater) Download() {
	u.mu.RLock()
	if u.state.Status != StatusAvailable || u.state.DownloadURL == "" {
		u.mu.RUnlock()
		return
	}
	url := u.state.DownloadURL
	u.mu.RUnlock()

	u.mu.Lock()
	u.state.Status = StatusDownloading
	u.state.Error = ""
	u.mu.Unlock()

	u.mu.RLock()
	checksum := u.state.Checksum
	u.mu.RUnlock()

	slog.Info("Downloading update", "url", url)

	path, err := downloadFile(url, checksum)
	if err != nil {
		slog.Error("Download failed", "error", err)
		u.mu.Lock()
		u.state.Status = StatusError
		u.state.Error = fmt.Sprintf("Download failed: %v", err)
		u.mu.Unlock()
		return
	}

	u.mu.Lock()
	u.state.Status = StatusReady
	u.state.DownloadPath = path
	u.mu.Unlock()

	slog.Info("Download complete", "path", path)
}

// DownloadAndApply downloads and then applies the update.
func (u *Updater) DownloadAndApply() {
	u.Download()

	u.mu.RLock()
	if u.state.Status != StatusReady {
		u.mu.RUnlock()
		return
	}
	u.mu.RUnlock()

	u.Apply()
}

// Apply applies a downloaded update.
func (u *Updater) Apply() {
	u.mu.Lock()
	if u.state.Status != StatusReady || u.state.DownloadPath == "" {
		u.mu.Unlock()
		return
	}
	path := u.state.DownloadPath
	u.state.Status = StatusApplying
	u.mu.Unlock()

	slog.Info("Applying update", "path", path)

	// Platform-specific binary replacement + restart
	if err := selfUpdate(path); err != nil {
		slog.Error("Self-update failed", "error", err)
		os.Remove(path)
		u.mu.Lock()
		u.state.Status = StatusError
		u.state.Error = err.Error()
		u.mu.Unlock()
	}
	// If selfUpdate succeeds, the process is replaced and we never get here
}

// Dismiss resets the update state.
func (u *Updater) Dismiss() {
	u.mu.Lock()
	defer u.mu.Unlock()
	if u.state.DownloadPath != "" {
		os.Remove(u.state.DownloadPath)
	}
	u.state = State{Status: StatusIdle, CheckedAt: u.state.CheckedAt, CurrentVersion: u.version}
}

// PlatformTarget returns the platform identifier for asset matching.
func PlatformTarget() string {
	os := runtime.GOOS
	arch := runtime.GOARCH
	return fmt.Sprintf("%s-%s", os, arch)
}

func downloadFile(url, checksum string) (string, error) {
	// Download to a temp file
	tmpFile, err := os.CreateTemp("", "pyrolis-connector-update-*")
	if err != nil {
		return "", err
	}
	defer tmpFile.Close()

	resp, err := http.Get(url)
	if err != nil {
		os.Remove(tmpFile.Name())
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		os.Remove(tmpFile.Name())
		return "", fmt.Errorf("HTTP %d", resp.StatusCode)
	}

	if _, err := io.Copy(tmpFile, resp.Body); err != nil {
		os.Remove(tmpFile.Name())
		return "", err
	}
	tmpFile.Close()

	// Verify checksum on the downloaded archive before extracting
	if checksum != "" {
		if err := verifyChecksum(tmpFile.Name(), checksum); err != nil {
			os.Remove(tmpFile.Name())
			return "", fmt.Errorf("checksum: %w", err)
		}
	}

	// If the download is a zip, extract the binary from it
	if strings.HasSuffix(url, ".zip") {
		extracted, err := extractBinaryFromZip(tmpFile.Name())
		os.Remove(tmpFile.Name())
		if err != nil {
			return "", fmt.Errorf("extract zip: %w", err)
		}
		return extracted, nil
	}

	return tmpFile.Name(), nil
}

// extractBinaryFromZip opens a zip archive and extracts the pyrolis-connector binary.
func extractBinaryFromZip(zipPath string) (string, error) {
	r, err := zip.OpenReader(zipPath)
	if err != nil {
		return "", err
	}
	defer r.Close()

	binaryName := "pyrolis-connector"
	if runtime.GOOS == "windows" {
		binaryName = "pyrolis-connector.exe"
	}

	for _, f := range r.File {
		name := filepath.Base(f.Name)
		if name != binaryName {
			continue
		}

		rc, err := f.Open()
		if err != nil {
			return "", err
		}
		defer rc.Close()

		tmpFile, err := os.CreateTemp("", "pyrolis-connector-bin-*")
		if err != nil {
			return "", err
		}

		if _, err := io.Copy(tmpFile, rc); err != nil {
			tmpFile.Close()
			os.Remove(tmpFile.Name())
			return "", err
		}
		tmpFile.Close()
		return tmpFile.Name(), nil
	}

	return "", fmt.Errorf("binary %q not found in zip", binaryName)
}

func fetchChecksum(checksumURL, target string) string {
	if checksumURL == "" {
		return ""
	}
	resp, err := http.Get(checksumURL)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	for _, line := range strings.Split(string(body), "\n") {
		parts := strings.Fields(line)
		if len(parts) == 2 && strings.Contains(parts[1], target) {
			return "sha256:" + parts[0]
		}
	}
	return ""
}

func verifyChecksum(path, expected string) error {
	if !strings.HasPrefix(expected, "sha256:") {
		return nil
	}
	expectedHex := strings.TrimPrefix(expected, "sha256:")

	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()

	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return err
	}

	actual := hex.EncodeToString(h.Sum(nil))
	if !strings.EqualFold(actual, expectedHex) {
		return fmt.Errorf("checksum mismatch: expected %s, got %s", expectedHex, actual)
	}
	return nil
}

func newerVersion(available, current string) bool {
	// Simple semver comparison: split on "." and compare numerically
	av := parseVersion(available)
	cv := parseVersion(current)
	if av == nil || cv == nil {
		return false
	}
	for i := 0; i < 3; i++ {
		if av[i] > cv[i] {
			return true
		}
		if av[i] < cv[i] {
			return false
		}
	}
	return false
}

func parseVersion(v string) []int {
	// Strip git describe suffix like "-4-gabcdef"
	if idx := strings.Index(v, "-"); idx > 0 {
		rest := v[idx+1:]
		if len(rest) > 0 && rest[0] >= '0' && rest[0] <= '9' {
			v = v[:idx]
		}
	}
	v = strings.TrimSpace(v)

	parts := strings.Split(v, ".")
	if len(parts) < 3 {
		return nil
	}
	nums := make([]int, 3)
	for i := 0; i < 3; i++ {
		fmt.Sscanf(parts[i], "%d", &nums[i])
	}
	return nums
}
