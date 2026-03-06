package relay

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"nhooyr.io/websocket"

	"github.com/pyrolis-app/pyrolis-connector/internal/config"
)

const (
	heartbeatInterval = 30 * time.Second
	rowBatchSize      = 500
	maxReconnectDelay = 60 * time.Second
	maxRecent         = 20
)

// MessageHandler is called when the relay receives a message from the cloud.
type MessageHandler func(event string, payload map[string]interface{})

// Relay maintains a WebSocket connection to the Pyrolis cloud
// using the Phoenix Channels v2 protocol.
type Relay struct {
	mu sync.RWMutex

	conn    *websocket.Conn
	ctx     context.Context
	cancel  context.CancelFunc
	joinRef string
	topic   string

	// Status tracking
	connectionStatus string
	channelJoined    bool
	lastHeartbeatAt  *time.Time
	commandsReceived int
	recentCommands   []CommandEntry
	recentErrors     []ErrorEntry
	startedAt        time.Time

	// Outgoing message channel
	outCh chan *Message

	// External handler for incoming messages
	handler MessageHandler

	// Version string for heartbeat
	version string
}

// CommandEntry tracks a received command.
type CommandEntry struct {
	RequestID  string    `json:"request_id"`
	DataSource string    `json:"data_source"`
	SQL        string    `json:"sql"`
	Timestamp  time.Time `json:"timestamp"`
}

// ErrorEntry tracks a query error.
type ErrorEntry struct {
	RequestID string    `json:"request_id"`
	Error     string    `json:"error"`
	Timestamp time.Time `json:"timestamp"`
}

// Status is the public relay status.
type Status struct {
	ConnectionStatus string         `json:"connection_status"`
	ChannelJoined    bool           `json:"channel_joined"`
	LastHeartbeatAt  *time.Time     `json:"last_heartbeat_at"`
	CommandsReceived int            `json:"commands_received"`
	RecentCommands   []CommandEntry `json:"recent_commands"`
	RecentErrors     []ErrorEntry   `json:"recent_errors"`
	StartedAt        time.Time      `json:"started_at"`
}

// New creates a new Relay instance.
func New(version string, handler MessageHandler) *Relay {
	return &Relay{
		connectionStatus: "stopped",
		outCh:            make(chan *Message, 100),
		handler:          handler,
		version:          version,
		recentCommands:   make([]CommandEntry, 0),
		recentErrors:     make([]ErrorEntry, 0),
	}
}

// SetHandler sets the message handler. Must be called before Start.
func (r *Relay) SetHandler(handler MessageHandler) {
	r.handler = handler
}

// Start begins the relay connection loop. Blocks until ctx is cancelled.
func (r *Relay) Start(ctx context.Context) {
	r.mu.Lock()
	r.startedAt = time.Now()
	r.mu.Unlock()

	cfg := config.Get()
	if cfg == nil || !cfg.Configured() {
		r.mu.Lock()
		r.connectionStatus = "not_configured"
		r.mu.Unlock()
		slog.Info("Relay not started: connector not configured")
		// Wait for context cancellation or config change
		<-ctx.Done()
		return
	}

	r.connectLoop(ctx, cfg)
}

// Reconnect forces a reconnection (e.g. after config change).
func (r *Relay) Reconnect() {
	r.mu.Lock()
	if r.cancel != nil {
		r.cancel()
	}
	r.mu.Unlock()
}

// GetStatus returns the current relay status.
func (r *Relay) GetStatus() Status {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return Status{
		ConnectionStatus: r.connectionStatus,
		ChannelJoined:    r.channelJoined,
		LastHeartbeatAt:  r.lastHeartbeatAt,
		CommandsReceived: r.commandsReceived,
		RecentCommands:   r.recentCommands,
		RecentErrors:     r.recentErrors,
		StartedAt:        r.startedAt,
	}
}

// Push sends a message to the cloud.
func (r *Relay) Push(event string, payload map[string]interface{}) {
	r.mu.RLock()
	jr := r.joinRef
	topic := r.topic
	r.mu.RUnlock()

	if jr == "" || topic == "" {
		return
	}

	msg := NewPush(jr, topic, event, payload)
	select {
	case r.outCh <- msg:
	default:
		slog.Warn("Outgoing message channel full, dropping message", "event", event)
	}
}

// TrackError records an error in recent errors.
func (r *Relay) TrackError(requestID, errMsg string) {
	r.mu.Lock()
	defer r.mu.Unlock()

	entry := ErrorEntry{
		RequestID: requestID,
		Error:     errMsg,
		Timestamp: time.Now(),
	}
	r.recentErrors = prepend(r.recentErrors, entry, maxRecent)
}

// connectLoop handles connection, reconnection with exponential backoff.
func (r *Relay) connectLoop(parentCtx context.Context, cfg *config.Config) {
	delay := time.Second

	for {
		select {
		case <-parentCtx.Done():
			return
		default:
		}

		r.mu.Lock()
		r.connectionStatus = "connecting"
		r.channelJoined = false
		r.mu.Unlock()

		err := r.runSession(parentCtx, cfg)
		if err != nil {
			slog.Warn("Relay session ended", "error", err)
		}

		select {
		case <-parentCtx.Done():
			return
		default:
		}

		// Reload config in case it changed
		newCfg := config.Get()
		if newCfg != nil && newCfg.Configured() {
			cfg = newCfg
		}

		r.mu.Lock()
		r.connectionStatus = "reconnecting"
		r.channelJoined = false
		r.mu.Unlock()

		slog.Info("Reconnecting in", "delay", delay)
		select {
		case <-time.After(delay):
		case <-parentCtx.Done():
			return
		}

		// Exponential backoff capped at maxReconnectDelay
		delay = delay * 2
		if delay > maxReconnectDelay {
			delay = maxReconnectDelay
		}
	}
}

// runSession connects, joins, and runs the read/write/heartbeat loops.
// Returns when the connection is lost or context is cancelled.
func (r *Relay) runSession(parentCtx context.Context, cfg *config.Config) error {
	wsURL, err := cfg.WebSocketURL()
	if err != nil {
		return fmt.Errorf("build ws url: %w", err)
	}

	slog.Info("Connecting to cloud", "url", cfg.Cloud.URL, "connector_id", cfg.Cloud.ConnectorID)

	ctx, cancel := context.WithCancel(parentCtx)
	defer cancel()

	r.mu.Lock()
	r.ctx = ctx
	r.cancel = cancel
	r.mu.Unlock()

	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		return fmt.Errorf("websocket dial: %w", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "closing")

	// Increase read limit for large query results
	conn.SetReadLimit(16 * 1024 * 1024) // 16MB

	r.mu.Lock()
	r.conn = conn
	r.connectionStatus = "connected"
	r.mu.Unlock()

	slog.Info("WebSocket connected")

	// Join the connector channel
	topic := fmt.Sprintf("connector:%s", cfg.Cloud.ConnectorID)
	joinMsg := NewJoinMessage(topic)
	joinRef := joinMsg.JoinRef.(string)

	if err := r.sendMessage(ctx, conn, joinMsg); err != nil {
		return fmt.Errorf("send join: %w", err)
	}

	// Wait for join reply
	joinReply, err := r.waitForReply(ctx, conn, joinRef, 10*time.Second)
	if err != nil {
		return fmt.Errorf("join reply: %w", err)
	}
	if joinReply.ReplyStatus() != "ok" {
		return fmt.Errorf("join rejected: %v", joinReply.Payload)
	}

	r.mu.Lock()
	r.joinRef = joinRef
	r.topic = topic
	r.channelJoined = true
	r.mu.Unlock()

	slog.Info("Joined channel", "topic", topic)

	// Report initial status
	r.reportStatus()

	// Run read loop, write loop, and heartbeat in parallel
	errCh := make(chan error, 3)

	go func() { errCh <- r.readLoop(ctx, conn) }()
	go func() { errCh <- r.writeLoop(ctx, conn) }()
	go func() { errCh <- r.heartbeatLoop(ctx, conn) }()

	// Wait for any goroutine to exit with error
	err = <-errCh
	cancel() // cancel remaining goroutines
	return err
}

// readLoop reads and dispatches incoming messages.
func (r *Relay) readLoop(ctx context.Context, conn *websocket.Conn) error {
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			return fmt.Errorf("read: %w", err)
		}

		msg, err := DecodeMessage(data)
		if err != nil {
			slog.Warn("Failed to decode message", "error", err)
			continue
		}

		r.handleMessage(msg)
	}
}

// writeLoop sends queued outgoing messages.
func (r *Relay) writeLoop(ctx context.Context, conn *websocket.Conn) error {
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case msg := <-r.outCh:
			data, _ := msg.Encode()
			slog.Debug("WS send", "event", msg.Event, "topic", msg.Topic, "size", len(data))
			if err := r.sendMessage(ctx, conn, msg); err != nil {
				return fmt.Errorf("write: %w", err)
			}
		}
	}
}

// heartbeatLoop sends periodic heartbeats.
func (r *Relay) heartbeatLoop(ctx context.Context, conn *websocket.Conn) error {
	ticker := time.NewTicker(heartbeatInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
			hb := NewHeartbeat()
			if err := r.sendMessage(ctx, conn, hb); err != nil {
				return fmt.Errorf("heartbeat: %w", err)
			}

			now := time.Now()
			r.mu.Lock()
			r.lastHeartbeatAt = &now
			r.mu.Unlock()

			// Also push connector heartbeat on the channel
			r.pushHeartbeat()
		}
	}
}

// handleMessage dispatches an incoming message to the appropriate handler.
func (r *Relay) handleMessage(msg *Message) {
	switch msg.Event {
	case "phx_reply":
		// Join/heartbeat replies handled inline
		return

	case "phx_error":
		slog.Error("Channel error, will reconnect", "topic", msg.Topic, "payload", msg.Payload)
		r.mu.Lock()
		r.channelJoined = false
		if r.cancel != nil {
			r.cancel()
		}
		r.mu.Unlock()
		return

	case "phx_close":
		slog.Warn("Channel closed by server, will reconnect", "topic", msg.Topic)
		r.mu.Lock()
		r.channelJoined = false
		if r.cancel != nil {
			r.cancel()
		}
		r.mu.Unlock()
		return
	}

	// Track query commands
	if msg.Event == "query" {
		r.mu.Lock()
		r.commandsReceived++
		entry := CommandEntry{
			RequestID:  getString(msg.Payload, "request_id"),
			DataSource: getString(msg.Payload, "data_source"),
			SQL:        truncate(getString(msg.Payload, "sql"), 120),
			Timestamp:  time.Now(),
		}
		r.recentCommands = prepend(r.recentCommands, entry, maxRecent)
		r.mu.Unlock()
	}

	// Dispatch to external handler
	if r.handler != nil {
		r.handler(msg.Event, msg.Payload)
	}
}

// pushHeartbeat sends connector-level heartbeat data.
func (r *Relay) pushHeartbeat() {
	r.mu.RLock()
	uptime := int(time.Since(r.startedAt).Seconds())
	r.mu.RUnlock()

	r.Push("heartbeat", map[string]interface{}{
		"version":        r.version,
		"uptime_seconds": uptime,
		"db_connected":   true, // TODO: check actual DB connections
	})
}

// reportStatus pushes data source status to the cloud.
func (r *Relay) reportStatus() {
	cfg := config.Get()
	if cfg == nil {
		return
	}

	sources := make([]map[string]interface{}, 0, len(cfg.DataSources))
	for _, ds := range cfg.DataSources {
		sources = append(sources, map[string]interface{}{
			"name":      ds.Name,
			"db_type":   ds.DBType,
			"connected": false, // TODO: check actual connection
			"enabled":   ds.Enabled,
		})
	}

	r.Push("status", map[string]interface{}{
		"data_sources": sources,
	})
}

// ReportStatus triggers a status push (public API).
func (r *Relay) ReportStatus() {
	r.reportStatus()
}

// PushLogs sends log entries to the cloud.
func (r *Relay) PushLogs(entries []map[string]interface{}) {
	r.Push("logs", map[string]interface{}{
		"entries": entries,
	})
}

// sendMessage encodes and writes a message to the WebSocket.
func (r *Relay) sendMessage(ctx context.Context, conn *websocket.Conn, msg *Message) error {
	data, err := msg.Encode()
	if err != nil {
		return fmt.Errorf("encode: %w", err)
	}
	return conn.Write(ctx, websocket.MessageText, data)
}

// waitForReply reads messages until a reply with the given ref is received.
func (r *Relay) waitForReply(ctx context.Context, conn *websocket.Conn, ref string, timeout time.Duration) (*Message, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			return nil, err
		}

		msg, err := DecodeMessage(data)
		if err != nil {
			continue
		}

		if refStr, ok := msg.Ref.(string); ok && refStr == ref && msg.Event == "phx_reply" {
			return msg, nil
		}
	}
}

// StreamRows sends query result rows in batches.
func (r *Relay) StreamRows(requestID string, columns []string, rows [][]interface{}) {
	total := len(rows)

	if total == 0 {
		r.Push("rows", map[string]interface{}{
			"request_id": requestID,
			"rows":       []interface{}{},
			"done":       true,
		})
		return
	}

	for i := 0; i < total; i += rowBatchSize {
		end := i + rowBatchSize
		if end > total {
			end = total
		}
		batch := rows[i:end]
		isLast := end >= total

		rowMaps := make([]map[string]interface{}, 0, len(batch))
		for _, row := range batch {
			m := make(map[string]interface{}, len(columns))
			for j, col := range columns {
				if j < len(row) {
					m[col] = row[j]
				}
			}
			rowMaps = append(rowMaps, m)
		}

		r.Push("rows", map[string]interface{}{
			"request_id": requestID,
			"rows":       rowMaps,
			"done":       isLast,
		})
	}

	slog.Info("Streamed rows", "request_id", requestID, "count", total)
}

// PushQueryError sends a query error to the cloud.
func (r *Relay) PushQueryError(requestID, errMsg string) {
	r.Push("query_error", map[string]interface{}{
		"request_id": requestID,
		"error":      errMsg,
	})
	r.TrackError(requestID, errMsg)
}

// Pong responds to a ping from the cloud.
func (r *Relay) Pong() {
	r.Push("pong", map[string]interface{}{
		"version":   r.version,
		"timestamp": time.Now().UTC().Format(time.RFC3339),
	})
}

// Helpers

func getString(m map[string]interface{}, key string) string {
	if v, ok := m[key]; ok {
		if s, ok := v.(string); ok {
			return s
		}
		return fmt.Sprint(v)
	}
	return ""
}

func truncate(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen]
}

func prepend[T any](slice []T, item T, maxLen int) []T {
	result := make([]T, 0, maxLen)
	result = append(result, item)
	remaining := maxLen - 1
	if len(slice) < remaining {
		remaining = len(slice)
	}
	result = append(result, slice[:remaining]...)
	return result
}

// MarshalPayload is a helper to convert a struct to map[string]interface{}.
func MarshalPayload(v interface{}) (map[string]interface{}, error) {
	data, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	var m map[string]interface{}
	err = json.Unmarshal(data, &m)
	return m, err
}
