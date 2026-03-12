package relay

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"time"

	"github.com/pyrolis-app/pyrolis-connector/internal/config"
)

const (
	pollIntervalDisconnected = 30 * time.Second
	pollIntervalConnected    = 60 * time.Second
	pollHTTPTimeout          = 15 * time.Second
)

// Poller provides an HTTP polling fallback for when the WebSocket is down.
// It periodically polls the cloud for pending commands and submits results.
type Poller struct {
	relay   *Relay
	handler MessageHandler
	client  *http.Client
}

// NewPoller creates a new HTTP polling fallback.
func NewPoller(r *Relay, handler MessageHandler) *Poller {
	return &Poller{
		relay:   r,
		handler: handler,
		client: &http.Client{
			Timeout: pollHTTPTimeout,
		},
	}
}

// Start runs the polling loop. Blocks until ctx is cancelled.
func (p *Poller) Start(ctx context.Context) {
	// Wait before starting to give WebSocket a chance to connect first
	select {
	case <-time.After(10 * time.Second):
	case <-ctx.Done():
		return
	}

	slog.Info("HTTP polling fallback started")

	for {
		interval := p.currentInterval()

		select {
		case <-ctx.Done():
			slog.Info("HTTP polling fallback stopped")
			return
		case <-time.After(interval):
			p.poll(ctx)
		}
	}
}

func (p *Poller) currentInterval() time.Duration {
	status := p.relay.GetStatus()
	if status.ChannelJoined {
		return pollIntervalConnected
	}
	return pollIntervalDisconnected
}

func (p *Poller) poll(ctx context.Context) {
	cfg := config.Get()
	if cfg == nil || !cfg.Configured() {
		return
	}

	url := fmt.Sprintf("%s/api/connector/%s/pending-commands",
		cfg.Cloud.URL, cfg.Cloud.ConnectorID)

	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return
	}
	req.Header.Set("Authorization", "Bearer "+cfg.Cloud.APIKey)
	req.Header.Set("Accept", "application/json")

	resp, err := p.client.Do(req)
	if err != nil {
		// Only log when WebSocket is also down (avoid noise when connected)
		if !p.relay.GetStatus().ChannelJoined {
			slog.Debug("Poll request failed", "error", err)
		}
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		slog.Debug("Poll returned non-200", "status", resp.StatusCode, "body", string(body))
		return
	}

	var result struct {
		Commands []struct {
			ID      string                 `json:"id"`
			Event   string                 `json:"event"`
			Payload map[string]interface{} `json:"payload"`
		} `json:"commands"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		slog.Warn("Failed to decode poll response", "error", err)
		return
	}

	if len(result.Commands) == 0 {
		return
	}

	slog.Info("Received commands via polling", "count", len(result.Commands))

	for _, cmd := range result.Commands {
		if p.handler != nil {
			p.handler(cmd.Event, cmd.Payload)
		}
		// Acknowledge the command so it isn't re-delivered
		if err := p.ackCommand(ctx, cmd.ID); err != nil {
			slog.Warn("Failed to ack polled command", "id", cmd.ID, "error", err)
		}
	}
}

// ackCommand acknowledges a polled command so it is not re-delivered.
func (p *Poller) ackCommand(ctx context.Context, commandID string) error {
	cfg := config.Get()
	if cfg == nil || !cfg.Configured() || commandID == "" {
		return nil
	}

	url := fmt.Sprintf("%s/api/connector/%s/ack-command/%s",
		cfg.Cloud.URL, cfg.Cloud.ConnectorID, commandID)

	req, err := http.NewRequestWithContext(ctx, "POST", url, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+cfg.Cloud.APIKey)

	resp, err := p.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 && resp.StatusCode != 204 {
		return fmt.Errorf("ack command: HTTP %d", resp.StatusCode)
	}
	return nil
}

// SubmitResult sends a command result back via HTTP.
func (p *Poller) SubmitResult(ctx context.Context, commandID, event string, payload map[string]interface{}) error {
	cfg := config.Get()
	if cfg == nil || !cfg.Configured() {
		return fmt.Errorf("not configured")
	}

	url := fmt.Sprintf("%s/api/connector/%s/command-result",
		cfg.Cloud.URL, cfg.Cloud.ConnectorID)

	body := map[string]interface{}{
		"command_id": commandID,
		"event":      event,
		"payload":    payload,
	}

	data, err := json.Marshal(body)
	if err != nil {
		return err
	}

	req, err := http.NewRequestWithContext(ctx, "POST", url, bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+cfg.Cloud.APIKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := p.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return fmt.Errorf("submit result: HTTP %d", resp.StatusCode)
	}

	return nil
}
