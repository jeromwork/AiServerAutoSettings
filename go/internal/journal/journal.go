package journal

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode/utf8"

	"remoteagents/internal/api"
)

type Options struct {
	MaxBytes int64
	Keep     int
}

type Journal struct {
	paths          api.Paths
	stream         string
	component      string
	opts           Options
	mu             sync.Mutex
	file           *os.File
	fileNum        int
	fileSize       int64
	rolled         bool
	closed         bool
	drops          atomic.Int64
	ring           []string
	lastKey        *dedupKey
	repeat         int
	streamJournals map[string]*Journal
}

var _ api.Logger = (*Journal)(nil)

type dedupKey struct {
	src      string
	ev       string
	dataJSON string
	why      string
}

func New(p api.Paths, stream string, o Options) (*Journal, error) {
	j, err := newJournalInternal(p, stream, o)
	if err != nil {
		return nil, err
	}
	migrateBootLogs(p, o, j)
	return j, nil
}

func newJournalInternal(p api.Paths, stream string, o Options) (*Journal, error) {
	if o.MaxBytes <= 0 {
		o.MaxBytes = 5 * 1024 * 1024
	}
	if o.Keep <= 0 {
		o.Keep = 4
	}
	if stream == "" {
		stream = api.StreamCore
	}
	switch stream {
	case api.StreamCore, api.StreamSup, api.StreamSB, api.StreamShell, api.StreamUpdate, api.StreamBoot:
	default:
		return nil, fmt.Errorf("journal: stream: invalid stream")
	}

	if err := os.MkdirAll(p.Logs, 0750); err != nil {
		return nil, err
	}

	j := &Journal{
		paths:          p,
		stream:         stream,
		component:      stream,
		opts:           o,
		ring:           make([]string, 0, ringMax),
		streamJournals: make(map[string]*Journal),
	}

	if err := j.initFile(); err != nil {
		return nil, err
	}

	return j, nil
}

func (j *Journal) initFile() error {
	re := regexp.MustCompile(`^lab-` + regexp.QuoteMeta(j.stream) + `-(\d+)\.jsonl$`)
	entries, err := os.ReadDir(j.paths.Logs)
	if err != nil {
		return err
	}

	maxN := 0
	for _, e := range entries {
		m := re.FindStringSubmatch(e.Name())
		if len(m) == 2 {
			n, _ := strconv.Atoi(m[1])
			if n > maxN {
				maxN = n
			}
		}
	}
	if maxN == 0 {
		maxN = 1
	}

	j.fileNum = maxN
	filePath := j.filePath(j.fileNum)

	fi, err := os.Stat(filePath)
	if err == nil {
		j.fileSize = fi.Size()
		if j.fileSize >= j.opts.MaxBytes {
			j.fileNum++
			filePath = j.filePath(j.fileNum)
			j.fileSize = 0
		}
	}

	f, err := os.OpenFile(filePath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		j.drops.Add(1)
		return err
	}
	j.file = f
	j.pruneLocked()
	return nil
}

func (j *Journal) filePath(n int) string {
	return filepath.Join(j.paths.Logs, fmt.Sprintf("lab-%s-%d.jsonl", j.stream, n))
}

func (j *Journal) rollLocked() {
	if j.file != nil {
		_ = j.file.Close()
		j.file = nil
	}
	j.fileNum++

	f, err := os.OpenFile(j.filePath(j.fileNum), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		j.drops.Add(1)
		return
	}
	j.file = f
	j.fileSize = 0
	j.pruneLocked()
}

func (j *Journal) pruneLocked() {
	entries, err := os.ReadDir(j.paths.Logs)
	if err != nil {
		j.drops.Add(1)
		return
	}
	removed := false
	re := regexp.MustCompile(`^lab-` + regexp.QuoteMeta(j.stream) + `-(\d+)\.jsonl$`)
	for _, e := range entries {
		m := re.FindStringSubmatch(e.Name())
		if len(m) != 2 {
			continue
		}
		n, _ := strconv.Atoi(m[1])
		if n <= j.fileNum-j.opts.Keep {
			if err := os.Remove(filepath.Join(j.paths.Logs, e.Name())); err != nil {
				j.drops.Add(1)
			} else {
				removed = true
			}
		}
	}
	if removed && !j.rolled {
		j.rolled = true
		j.emitLocked(map[string]any{"ts": timeNowISO(), "src": "journal", "ev": "journal.rollover", "data": map[string]any{"max_files": j.opts.Keep, "file_mb": j.opts.MaxBytes / (1024 * 1024)}})
	}
}

func (j *Journal) emitLocked(rec map[string]any) {
	lineBytes, err := json.Marshal(rec)
	if err != nil {
		j.drops.Add(1)
		return
	}

	if utf8.RuneCount(lineBytes) > recMax {
		truncRec := map[string]any{
			"ts":  rec["ts"],
			"src": rec["src"],
			"ev":  rec["ev"],
			"data": map[string]any{
				"truncated_chars": utf8.RuneCount(lineBytes),
			},
		}
		lineBytes, _ = json.Marshal(truncRec)
	}

	fullBytes, _ := json.Marshal(rec)
	j.appendToRingLocked(string(fullBytes))

	if j.file == nil {
		j.drops.Add(1)
		return
	}

	lineWithNL := append(lineBytes, '\n')
	n, err := j.file.Write(lineWithNL)
	if err != nil {
		j.drops.Add(1)
		return
	}
	j.fileSize += int64(n)
	if j.fileSize >= j.opts.MaxBytes {
		j.rollLocked()
	}
}

func (j *Journal) appendToRingLocked(line string) {
	if len(j.ring) < ringMax {
		j.ring = append(j.ring, line)
	} else {
		j.ring = append(j.ring[1:], line)
	}
}

func (j *Journal) flushRepeatLocked() {
	if j.repeat > 0 && j.lastKey != nil {
		repeatRec := map[string]any{
			"ts":  timeNowISO(),
			"src": j.lastKey.src,
			"ev":  j.lastKey.ev,
			"data": map[string]any{
				"repeated": j.repeat,
			},
		}
		j.repeat = 0
		j.emitLocked(repeatRec)
	}
}

func (j *Journal) logRecord(src, ev string, data any, why string) {
	if data != nil {
		data = clipValue(MaskValue(data))
	}
	if why != "" {
		why = clipValue(MaskString(why)).(string)
	}

	src = clipString(MaskString(src))
	ev = clipString(MaskString(ev))
	var dataJSON string
	if data != nil {
		b, _ := json.Marshal(data)
		dataJSON = string(b)
	}
	key := dedupKey{src: src, ev: ev, dataJSON: dataJSON, why: why}

	j.mu.Lock()
	defer j.mu.Unlock()

	if j.closed {
		j.drops.Add(1)
		return
	}
	if j.lastKey != nil && *j.lastKey == key {
		j.repeat++
		return
	}

	j.flushRepeatLocked()
	j.lastKey = &key

	rec := map[string]any{
		"ts":  timeNowISO(),
		"src": src,
		"ev":  ev,
	}
	if data != nil {
		rec["data"] = data
	}
	if why != "" {
		rec["why"] = why
	}
	j.emitLocked(rec)
}

func (j *Journal) Info(event string, kv ...any) {
	data, why := parseKV(kv...)
	j.logRecord(j.component, event, data, why)
}

func (j *Journal) Warn(event string, kv ...any) {
	data, why := parseKV(kv...)
	if data == nil {
		data = make(map[string]any)
	}
	if _, ok := data["level"]; !ok {
		data["level"] = "warn"
	}
	j.logRecord(j.component, event, data, why)
}

func (j *Journal) Error(event string, kv ...any) {
	data, why := parseKV(kv...)
	if data == nil {
		data = make(map[string]any)
	}
	if _, ok := data["level"]; !ok {
		data["level"] = "error"
	}
	j.logRecord(j.component, event, data, why)
}

func (j *Journal) With(component string) api.Logger {
	return &componentLogger{
		j:         j,
		component: component,
	}
}

func (j *Journal) Secret(value string) {
	RegisterSecret(value)
}

func (j *Journal) Writer(stream, source string) io.WriteCloser {
	if stream == "" {
		stream = j.stream
	}
	if source == "" {
		source = stream
	}
	targetJournal := j
	if stream != j.stream {
		targetJournal = j.getStreamJournal(stream)
	}
	return newLineWriter(targetJournal, source)
}

func (j *Journal) getStreamJournal(stream string) *Journal {
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.closed {
		return j
	}
	if sj, ok := j.streamJournals[stream]; ok {
		return sj
	}
	sj, err := newJournalInternal(j.paths, stream, j.opts)
	if err != nil {
		j.drops.Add(1)
		return &Journal{}
	}
	j.streamJournals[stream] = sj
	return sj
}

func (j *Journal) Drops() int64 {
	j.mu.Lock()
	defer j.mu.Unlock()
	n := j.drops.Load()
	for _, sj := range j.streamJournals {
		n += sj.Drops()
	}
	return n
}

func (j *Journal) Tail(n int) []string {
	j.mu.Lock()
	defer j.mu.Unlock()
	j.flushRepeatLocked()

	if n <= 0 {
		n = 200
	}
	if n > ringMax {
		n = ringMax
	}
	total := len(j.ring)
	if n > total {
		n = total
	}
	res := make([]string, n)
	copy(res, j.ring[total-n:])
	return res
}

func (j *Journal) Zip(w io.Writer) error {
	j.mu.Lock()
	j.flushRepeatLocked()
	j.mu.Unlock()

	zw := zip.NewWriter(w)
	closed := false
	defer func() {
		if !closed {
			_ = zw.Close()
		}
	}()

	entries, err := os.ReadDir(j.paths.Logs)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}

	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		if !strings.HasPrefix(name, "lab-") {
			continue
		}
		filePath := filepath.Join(j.paths.Logs, name)
		data, err := os.ReadFile(filePath)
		if err != nil {
			continue
		}
		fw, err := zw.Create(name)
		if err != nil {
			return err
		}
		if _, err := fw.Write(data); err != nil {
			return err
		}
	}
	closed = true
	return zw.Close()
}

func (j *Journal) Close() error {
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.closed {
		return nil
	}
	j.closed = true
	j.flushRepeatLocked()

	var firstErr error
	if j.file != nil {
		if err := j.file.Close(); err != nil {
			firstErr = err
		}
		j.file = nil
	}
	for _, sj := range j.streamJournals {
		if err := sj.Close(); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}

type componentLogger struct {
	j         *Journal
	component string
}

func (l *componentLogger) Info(event string, kv ...any) {
	data, why := parseKV(kv...)
	l.j.logRecord(l.component, event, data, why)
}

func (l *componentLogger) Warn(event string, kv ...any) {
	data, why := parseKV(kv...)
	if data == nil {
		data = make(map[string]any)
	}
	if _, ok := data["level"]; !ok {
		data["level"] = "warn"
	}
	l.j.logRecord(l.component, event, data, why)
}

func (l *componentLogger) Error(event string, kv ...any) {
	data, why := parseKV(kv...)
	if data == nil {
		data = make(map[string]any)
	}
	if _, ok := data["level"]; !ok {
		data["level"] = "error"
	}
	l.j.logRecord(l.component, event, data, why)
}

func (l *componentLogger) With(component string) api.Logger {
	return &componentLogger{
		j:         l.j,
		component: component,
	}
}

func (l *componentLogger) Secret(value string) {
	l.j.Secret(value)
}

func (l *componentLogger) Writer(stream, source string) io.WriteCloser {
	if source == "" {
		source = l.component
	}
	return l.j.Writer(stream, source)
}

func (l *componentLogger) Drops() int64 {
	return l.j.Drops()
}

type lineWriter struct {
	j        *Journal
	source   string
	buf      bytes.Buffer
	mu       sync.Mutex
	closed   bool
	overflow bool
}

func newLineWriter(j *Journal, source string) *lineWriter {
	return &lineWriter{
		j:      j,
		source: source,
	}
}

func (w *lineWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.closed {
		return 0, io.ErrClosedPipe
	}
	total := len(p)
	for len(p) > 0 {
		idx := bytes.IndexByte(p, '\n')
		part := p
		if idx >= 0 {
			part = p[:idx]
		}
		if !w.overflow {
			if w.buf.Len()+len(part) > 64*1024 {
				w.buf.Reset()
				w.overflow = true
			} else {
				w.buf.Write(part)
			}
		}
		if idx < 0 {
			break
		}
		if w.overflow {
			w.j.logRecord(w.source, "line", map[string]any{"truncated_chars": true}, "")
		} else {
			w.j.logRecord(w.source, "line", map[string]any{"line": strings.TrimSuffix(w.buf.String(), "\r")}, "")
		}
		w.buf.Reset()
		w.overflow = false
		p = p[idx+1:]
	}

	return total, nil
}

func (w *lineWriter) Close() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.closed {
		return nil
	}
	w.closed = true
	if w.overflow {
		w.j.logRecord(w.source, "line", map[string]any{"truncated_chars": true}, "")
	}
	if w.buf.Len() > 0 {
		s := strings.TrimRight(w.buf.String(), "\r\n")
		w.buf.Reset()
		if len(s) > 0 {
			w.j.logRecord(w.source, "line", map[string]any{"line": s}, "")
		}
	}
	return nil
}

func parseKV(kv ...any) (map[string]any, string) {
	if len(kv) == 0 {
		return nil, ""
	}
	var why string
	if len(kv) == 1 {
		if m, ok := kv[0].(map[string]any); ok {
			data := make(map[string]any, len(m))
			for k, v := range m {
				if k == "why" {
					why = fmt.Sprint(v)
				} else {
					data[k] = v
				}
			}
			return data, why
		}
		return map[string]any{"msg": kv[0]}, ""
	}

	data := make(map[string]any)
	for i := 0; i < len(kv); i += 2 {
		k := fmt.Sprint(kv[i])
		if i+1 < len(kv) {
			v := kv[i+1]
			if k == "why" {
				why = fmt.Sprint(v)
			} else {
				data[k] = v
			}
		} else {
			data["extra"] = kv[i]
		}
	}
	return data, why
}

func timeNowISO() string {
	return time.Now().Format("2006-01-02T15:04:05.000-07:00")
}
