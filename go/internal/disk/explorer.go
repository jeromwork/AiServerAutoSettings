package disk

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"time"

	"remoteagents/internal/api"
)

// Explorer retains the v2 Windows controller. Its helper is built from explorer/;
// it has an asInvoker manifest and uses only current-user registry entries.
type explorer struct {
	process api.Process
	input   *os.File
}

func (d *Disk) startExplorer(ctx context.Context) *explorer {
	if runtime.GOOS != "windows" {
		return nil
	}
	path := d.o.ExplorerExe
	if path == "" {
		path = filepath.Join(filepath.Dir(d.o.Exe), "disk-explorer.exe")
	}
	if !exists(path) {
		d.log("explorer-unavailable")
		return nil
	}
	reader, writer, e := os.Pipe()
	if e != nil {
		return nil
	}
	p, e := d.o.Procs.Start(ctx, api.ProcSpec{Name: "disk.explorer", Path: path, Args: []string{"serve", d.o.Installed, d.home}, Stdin: reader, Stream: api.StreamCore})
	_ = reader.Close()
	if e != nil {
		_ = writer.Close()
		d.log("explorer-unavailable")
		return nil
	}
	return &explorer{process: p, input: writer}
}
func (e *explorer) wake() {
	if e != nil {
		_, _ = e.input.Write([]byte("wake\n"))
	}
}
func (e *explorer) stop() {
	if e == nil {
		return
	}
	_ = e.input.Close()
	// One shutdown deadline: let v2 remove its menu and mark icons unavailable.
	t := time.NewTimer(5 * time.Second)
	defer t.Stop()
	select {
	case <-e.process.Done():
		return
	case <-t.C:
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_ = e.process.Stop(ctx)
}
