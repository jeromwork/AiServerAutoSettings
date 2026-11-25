package tray

import (
	"context"
	"os"
	"strings"
	"sync"

	"remoteagents/internal/api"
	"remoteagents/internal/bus"
)

type Options struct {
	Ready func()
	Bus   *bus.Bus
	Log   api.Logger
	Procs api.Procs
}
type Tray struct {
	o                                        Options
	mu                                       sync.Mutex
	url, home, tip                           string
	control, running, locked, rollback, disk bool
	lines                                    []string
}

func New(o Options) *Tray { return &Tray{o: o, tip: "Запуск"} }

var _ api.Tray = (*Tray)(nil)

func (t *Tray) command(kind string, data map[string]any) {
	if data == nil {
		data = map[string]any{}
	}
	data["t"] = kind
	t.o.Bus.Publish("supervisor.command", data)
}
func (t *Tray) launch(path string, args ...string) {
	if _, err := t.o.Procs.Start(context.Background(), api.ProcSpec{Name: "tray.open", Path: path, Args: args, Stream: api.StreamShell}); err != nil {
		t.o.Log.Warn("tray.open", "err", err)
	}
}
func (t *Tray) copy(ctx context.Context, text string) {
	path, args := clipboardCommand()
	p, err := t.o.Procs.Start(ctx, api.ProcSpec{Name: "tray.clipboard", Path: path, Args: args, Stdin: strings.NewReader(text), Stream: api.StreamShell})
	if err == nil {
		select {
		case <-p.Done():
		case <-ctx.Done():
			_ = p.Stop(context.Background())
		}
	} else {
		t.o.Log.Warn("tray.clipboard", "err", err)
	}
}
func desktopAvailable() bool { return os.Getenv("DISPLAY") != "" || os.Getenv("WAYLAND_DISPLAY") != "" }
