package journal

import (
	"bufio"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"sync"

	"remoteagents/internal/api"
)

var bootMu sync.Mutex
var boots []*bootLogger

type bootLogger struct {
	mu     sync.Mutex
	target *Journal
	path   string
}

func Boot(home string) api.Logger {
	bootMu.Lock()
	defer bootMu.Unlock()
	dir := os.TempDir()
	if home != "" {
		dir = api.NewPaths(home).Logs
	}
	path := filepath.Join(dir, "ra3-boot-"+strconv.Itoa(os.Getuid())+".log")
	for _, b := range boots {
		if b.path == path {
			return b
		}
	}
	j := &Journal{opts: Options{MaxBytes: 1 << 62, Keep: 4}, component: api.StreamBoot, stream: api.StreamBoot, ring: make([]string, 0, ringMax)}
	if err := os.MkdirAll(dir, 0750); err != nil {
		j.drops.Add(1)
	} else {
		f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
		if err != nil {
			j.drops.Add(1)
		} else {
			j.file = f
		}
	}
	b := &bootLogger{target: j, path: path}
	boots = append(boots, b)
	return b
}
func (b *bootLogger) Info(e string, kv ...any) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.target.Info(e, kv...)
}
func (b *bootLogger) Warn(e string, kv ...any) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.target.Warn(e, kv...)
}
func (b *bootLogger) Error(e string, kv ...any) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.target.Error(e, kv...)
}
func (b *bootLogger) Secret(s string)          { RegisterSecret(s) }
func (b *bootLogger) Drops() int64             { b.mu.Lock(); defer b.mu.Unlock(); return b.target.Drops() }
func (b *bootLogger) With(c string) api.Logger { return &bootComponent{b: b, c: c} }
func (b *bootLogger) Writer(stream, src string) io.WriteCloser {
	return &bootWriter{b: b, stream: stream, src: src}
}

type bootComponent struct {
	b *bootLogger
	c string
}

func (c *bootComponent) Info(e string, kv ...any) {
	c.b.mu.Lock()
	defer c.b.mu.Unlock()
	c.b.target.With(c.c).Info(e, kv...)
}
func (c *bootComponent) Warn(e string, kv ...any) {
	c.b.mu.Lock()
	defer c.b.mu.Unlock()
	c.b.target.With(c.c).Warn(e, kv...)
}
func (c *bootComponent) Error(e string, kv ...any) {
	c.b.mu.Lock()
	defer c.b.mu.Unlock()
	c.b.target.With(c.c).Error(e, kv...)
}
func (c *bootComponent) Secret(s string)          { c.b.Secret(s) }
func (c *bootComponent) Drops() int64             { return c.b.Drops() }
func (c *bootComponent) With(s string) api.Logger { return c.b.With(s) }
func (c *bootComponent) Writer(s, src string) io.WriteCloser {
	if src == "" {
		src = c.c
	}
	return c.b.Writer(s, src)
}

type bootWriter struct {
	mu          sync.Mutex
	b           *bootLogger
	stream, src string
	w           io.WriteCloser
	closed      bool
}

func (w *bootWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.closed {
		return 0, io.ErrClosedPipe
	}
	if w.w == nil {
		w.b.mu.Lock()
		w.w = w.b.target.Writer(w.stream, w.src)
		w.b.mu.Unlock()
	}
	return w.w.Write(p)
}
func (w *bootWriter) Close() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.closed = true
	if w.w != nil {
		return w.w.Close()
	}
	return nil
}

// Keep the boot logger itself valid after migration; all its views share the target.
func migrateBootLogs(p api.Paths, o Options, root *Journal) {
	bootMu.Lock()
	defer bootMu.Unlock()
	for _, b := range boots {
		b.mu.Lock()
		if b.path == "" {
			b.mu.Unlock()
			continue
		}
		target := root
		if root.stream != api.StreamBoot {
			target = root.getStreamJournal(api.StreamBoot)
			if target.file == nil {
				b.mu.Unlock()
				continue
			}
		}

		before := target.drops.Load()
		old := b.target
		old.mu.Lock()
		if old.file != nil {
			_ = old.file.Close()
			old.file = nil
		}
		f, err := os.Open(b.path)
		if err == nil {
			scanner := bufio.NewScanner(f)
			scanner.Buffer(make([]byte, 4096), 1024*1024)
			for scanner.Scan() {
				var rec map[string]any
				if json.Unmarshal(scanner.Bytes(), &rec) != nil {
					target.drops.Add(1)
					continue
				}
				masked, ok := MaskValue(rec).(map[string]any)
				if !ok {
					continue
				}
				target.mu.Lock()
				target.emitLocked(masked)
				target.mu.Unlock()
			}
			err = scanner.Err()
			_ = f.Close()
		}
		old.mu.Unlock()
		if target.drops.Load() != before {
			err = io.ErrShortWrite
		}
		if err == nil {
			if err = os.Remove(b.path); err != nil {
				target.drops.Add(1)
			}
		} else {
			target.drops.Add(1)
		}
		if err == nil {
			target.drops.Add(old.drops.Load())
			b.target = target
			b.path = ""
		} else {
			old.mu.Lock()
			old.file, _ = os.OpenFile(b.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
			old.mu.Unlock()
		}
		b.mu.Unlock()
	}
}

var _ api.Logger = (*bootLogger)(nil)
