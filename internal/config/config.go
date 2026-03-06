package config

import (
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"sync"

	"github.com/BurntSushi/toml"
)

// Config is the top-level configuration.
type Config struct {
	Cloud       CloudConfig    `toml:"cloud"`
	Settings    Settings       `toml:"settings"`
	DataSources []DataSource   `toml:"data_sources"`
}

type CloudConfig struct {
	URL         string `toml:"url"`
	APIKey      string `toml:"api_key"`
	ConnectorID string `toml:"connector_id"`
}

type Settings struct {
	AllowRemoteUpdates bool   `toml:"allow_remote_updates"`
	AutoApplyMode      string `toml:"auto_apply_mode"` // auto | download | manual
	LogStreaming        bool   `toml:"log_streaming"`
	WebPort            int    `toml:"web_port"`
	BaseURL            string `toml:"base_url,omitempty"` // Override base domain for pairing (default: pyrolis.com)
}

type DataSource struct {
	Name    string            `toml:"name"`
	DBType  string            `toml:"db_type"`
	Enabled bool              `toml:"enabled"`
	Config  map[string]string `toml:"config"`
}

var (
	mu       sync.RWMutex
	current  *Config
	filePath string
)

// DefaultConfig returns a config with sane defaults.
func DefaultConfig() *Config {
	return &Config{
		Settings: Settings{
			AllowRemoteUpdates: true,
			AutoApplyMode:      "auto",
			WebPort:            4100,
		},
	}
}

// Dir returns the OS-appropriate config directory for pyrolis-connector.
func Dir() (string, error) {
	configDir, err := os.UserConfigDir()
	if err != nil {
		// Fallback: next to binary
		exe, err2 := os.Executable()
		if err2 != nil {
			return "", fmt.Errorf("cannot determine config dir: %w", err)
		}
		return filepath.Dir(exe), nil
	}
	return filepath.Join(configDir, "pyrolis-connector"), nil
}

// Path returns the full path to config.toml.
func Path() (string, error) {
	if filePath != "" {
		return filePath, nil
	}
	dir, err := Dir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "config.toml"), nil
}

// Load reads the config from disk. Returns default config if file doesn't exist.
func Load() (*Config, error) {
	mu.Lock()
	defer mu.Unlock()

	path, err := Path()
	if err != nil {
		return nil, err
	}

	cfg := DefaultConfig()

	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			current = cfg
			return cfg, nil
		}
		return nil, fmt.Errorf("read config: %w", err)
	}

	if err := toml.Unmarshal(data, cfg); err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}

	current = cfg
	filePath = path
	return cfg, nil
}

// Save writes the config to disk.
func Save(cfg *Config) error {
	mu.Lock()
	defer mu.Unlock()

	path, err := Path()
	if err != nil {
		return err
	}

	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return fmt.Errorf("create config dir: %w", err)
	}

	f, err := os.Create(path)
	if err != nil {
		return fmt.Errorf("create config file: %w", err)
	}
	defer f.Close()

	enc := toml.NewEncoder(f)
	if err := enc.Encode(cfg); err != nil {
		return fmt.Errorf("encode config: %w", err)
	}

	current = cfg
	filePath = path
	return nil
}

// Get returns the current in-memory config. Returns nil if not loaded.
func Get() *Config {
	mu.RLock()
	defer mu.RUnlock()
	return current
}

// Set updates the in-memory config and saves to disk.
func Set(cfg *Config) error {
	return Save(cfg)
}

// Configured returns true if cloud connection details are set.
func (c *Config) Configured() bool {
	return c.Cloud.URL != "" && c.Cloud.APIKey != "" && c.Cloud.ConnectorID != ""
}

// WebSocketURL builds the Phoenix Channels WebSocket URL.
func (c *Config) WebSocketURL() (string, error) {
	u, err := url.Parse(c.Cloud.URL)
	if err != nil {
		return "", fmt.Errorf("invalid cloud URL: %w", err)
	}

	scheme := "wss"
	if u.Scheme == "http" {
		scheme = "ws"
	}

	host := u.Host // includes port if non-standard

	return fmt.Sprintf("%s://%s/connector/websocket?api_key=%s&vsn=2.0.0",
		scheme, host, url.QueryEscape(c.Cloud.APIKey)), nil
}

// ResolveBaseURL returns the base URL for pairing (settings override, env var, or default).
func (c *Config) ResolveBaseURL() string {
	if c.Settings.BaseURL != "" {
		return c.Settings.BaseURL
	}
	if env := os.Getenv("PYROLIS_BASE_URL"); env != "" {
		return env
	}
	return "https://pyrolis.com"
}

// FindDataSource returns the data source with the given name, or nil.
func (c *Config) FindDataSource(name string) *DataSource {
	for i := range c.DataSources {
		if c.DataSources[i].Name == name {
			return &c.DataSources[i]
		}
	}
	return nil
}

// SaveDataSource adds or updates a data source and saves config.
func SaveDataSource(ds DataSource) error {
	cfg := Get()
	if cfg == nil {
		cfg = DefaultConfig()
	}

	found := false
	for i := range cfg.DataSources {
		if cfg.DataSources[i].Name == ds.Name {
			cfg.DataSources[i] = ds
			found = true
			break
		}
	}
	if !found {
		cfg.DataSources = append(cfg.DataSources, ds)
	}

	return Save(cfg)
}

// DeleteDataSource removes a data source by name and saves config.
func DeleteDataSource(name string) error {
	cfg := Get()
	if cfg == nil {
		return nil
	}

	filtered := make([]DataSource, 0, len(cfg.DataSources))
	for _, ds := range cfg.DataSources {
		if ds.Name != name {
			filtered = append(filtered, ds)
		}
	}
	cfg.DataSources = filtered
	return Save(cfg)
}

// UpdateSetting updates a single setting field and saves.
func UpdateSetting(key string, value interface{}) error {
	cfg := Get()
	if cfg == nil {
		cfg = DefaultConfig()
	}

	switch key {
	case "allow_remote_updates":
		if v, ok := value.(bool); ok {
			cfg.Settings.AllowRemoteUpdates = v
		}
	case "auto_apply_mode":
		if v, ok := value.(string); ok {
			cfg.Settings.AutoApplyMode = v
		}
	case "log_streaming":
		if v, ok := value.(bool); ok {
			cfg.Settings.LogStreaming = v
		}
	case "web_port":
		if v, ok := value.(int); ok {
			cfg.Settings.WebPort = v
		}
	}

	return Save(cfg)
}
