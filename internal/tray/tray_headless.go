//go:build !desktop

package tray

// Tray is a no-op on headless builds (no CGO / no desktop environment).
type Tray struct {
	quitCh chan struct{}
}

// New creates a no-op Tray.
func New(port int, version string) *Tray {
	return &Tray{quitCh: make(chan struct{})}
}

// Run is a no-op on headless builds.
func (t *Tray) Run() {}

// Quit is a no-op.
func (t *Tray) Quit() {}

// QuitCh returns a channel that is never closed (headless has no tray quit).
func (t *Tray) QuitCh() <-chan struct{} {
	return t.quitCh
}

// SetStatus is a no-op.
func (t *Tray) SetStatus(status string) {}
