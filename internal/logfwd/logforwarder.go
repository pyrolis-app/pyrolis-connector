package logfwd

import (
	"context"
	"fmt"
	"log/slog"
	"sync"
	"time"
)

const (
	maxBuffer     = 100
	flushInterval = time.Second
)

// PushFunc is the function called to push log entries to the relay.
type PushFunc func(entries []map[string]interface{})

// Forwarder captures log entries and sends them in batches.
// It also implements slog.Handler to intercept all log output.
type Forwarder struct {
	mu      sync.Mutex
	enabled bool
	buffer  []map[string]interface{}
	pushFn  PushFunc
	stopCh  chan struct{}

	// The underlying handler that actually writes to stderr
	base slog.Handler
}

// New creates a new log forwarder wrapping the given base handler.
func New(pushFn PushFunc, base slog.Handler) *Forwarder {
	return &Forwarder{
		pushFn: pushFn,
		buffer: make([]map[string]interface{}, 0, maxBuffer),
		stopCh: make(chan struct{}),
		base:   base,
	}
}

// Enable starts capturing and forwarding logs.
func (f *Forwarder) Enable() {
	f.mu.Lock()
	if f.enabled {
		f.mu.Unlock()
		return
	}
	f.enabled = true
	f.mu.Unlock()

	go f.flushLoop()
	slog.Info("Log forwarding enabled")
}

// Disable stops capturing logs.
func (f *Forwarder) Disable() {
	f.mu.Lock()
	if !f.enabled {
		f.mu.Unlock()
		return
	}
	f.enabled = false
	f.mu.Unlock()

	select {
	case f.stopCh <- struct{}{}:
	default:
	}

	f.flush()
	slog.Info("Log forwarding disabled")
}

// IsEnabled returns whether log forwarding is active.
func (f *Forwarder) IsEnabled() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.enabled
}

// Toggle switches the enabled state.
func (f *Forwarder) Toggle() {
	if f.IsEnabled() {
		f.Disable()
	} else {
		f.Enable()
	}
}

// slog.Handler implementation

func (f *Forwarder) Enabled(_ context.Context, level slog.Level) bool {
	return f.base.Enabled(context.Background(), level)
}

func (f *Forwarder) Handle(_ context.Context, r slog.Record) error {
	// Always write to the base handler (stderr)
	err := f.base.Handle(context.Background(), r)

	// If forwarding is enabled, buffer the entry
	f.mu.Lock()
	if f.enabled {
		entry := map[string]interface{}{
			"level":     r.Level.String(),
			"message":   r.Message,
			"timestamp": r.Time.UTC().Format(time.RFC3339),
		}
		// Capture first attribute as module hint
		r.Attrs(func(a slog.Attr) bool {
			entry[a.Key] = fmt.Sprint(a.Value)
			return true
		})

		f.buffer = append(f.buffer, entry)

		if len(f.buffer) >= maxBuffer {
			entries := f.buffer
			f.buffer = make([]map[string]interface{}, 0, maxBuffer)
			go f.pushFn(entries)
		}
	}
	f.mu.Unlock()

	return err
}

func (f *Forwarder) WithAttrs(attrs []slog.Attr) slog.Handler {
	return &Forwarder{
		pushFn:  f.pushFn,
		buffer:  f.buffer,
		stopCh:  f.stopCh,
		enabled: f.enabled,
		base:    f.base.WithAttrs(attrs),
	}
}

func (f *Forwarder) WithGroup(name string) slog.Handler {
	return &Forwarder{
		pushFn:  f.pushFn,
		buffer:  f.buffer,
		stopCh:  f.stopCh,
		enabled: f.enabled,
		base:    f.base.WithGroup(name),
	}
}

func (f *Forwarder) flushLoop() {
	ticker := time.NewTicker(flushInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ticker.C:
			f.flush()
		case <-f.stopCh:
			return
		}
	}
}

func (f *Forwarder) flush() {
	f.mu.Lock()
	if len(f.buffer) == 0 {
		f.mu.Unlock()
		return
	}
	entries := f.buffer
	f.buffer = make([]map[string]interface{}, 0, maxBuffer)
	f.mu.Unlock()

	f.pushFn(entries)
}
