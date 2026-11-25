package tray

import "context"

// macOS has no tray in this build; the supervisor and web UI remain available.
func (t *Tray) Run(ctx context.Context) error {
	if t.o.Ready != nil {
		t.o.Ready()
	}
	<-ctx.Done()
	return nil
}
func clipboardCommand() (string, []string) { return "pbcopy", nil }
