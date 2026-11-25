// Package journal mirrors v2 journal.py: JSON lines, secret masking, size rotation, in-memory ring.
// Rotation happens on write when the file reaches the size limit (constitution 5b: no timers).
package journal

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode"
	"unicode/utf8"

	"remoteagents/internal/api"
)

// Limits, as in v2.
const (
	fileMax    = 5 * 1024 * 1024
	filesMax   = 4
	ringMax    = 2000
	fieldMax   = 2000
	recMax     = 16000
	secretsMax = 2000
	listMax    = 200
	lineMax    = 8192 // v2 procs.LINE_MAX
)

// Masker is shared by every stream of the process (v2 has one global masker).
var (
	secMu   sync.RWMutex
	secrets = map[string]bool{}
	sorted  []string
)

func register(v string) {
	secMu.Lock()
	defer secMu.Unlock()
	for _, p := range append([]string{v}, strings.Split(v, "\n")...) {
		if len(strings.TrimSpace(p)) >= 2 && len(secrets) < secretsMax {
			secrets[p] = true
		}
	}
	sorted = sorted[:0]
	for s := range secrets {
		sorted = append(sorted, s)
	}
	sort.Slice(sorted, func(i, j int) bool { return len(sorted[i]) > len(sorted[j]) })
}

func isWord(r rune) bool { return r == '_' || r == '-' || unicode.IsLetter(r) || unicode.IsDigit(r) }

// maskStr: secrets of 4+ chars are replaced as substrings; shorter ones only as whole tokens.
func maskStr(x string) string {
	secMu.RLock()
	defer secMu.RUnlock()
	for _, s := range sorted {
		if len(s) >= 4 {
			x = strings.ReplaceAll(x, s, "***")
			continue
		}
		var b strings.Builder
		for {
			i := strings.Index(x, s)
			if i < 0 {
				break
			}
			before, _ := utf8.DecodeLastRuneInString(x[:i])
			after, _ := utf8.DecodeRuneInString(x[i+len(s):])
			b.WriteString(x[:i])
			if isWord(before) || isWord(after) {
				b.WriteString(s)
			} else {
				b.WriteString("***")
			}
			x = x[i+len(s):]
		}
		x = b.String() + x
	}
	return x
}

// clean masks and clips any value into JSON-friendly data.
func clean(x any) any {
	switch v := x.(type) {
	case nil, bool, int, int64, float64:
		return v
	case string:
		v = maskStr(v)
		if len(v) > fieldMax {
			v = v[:fieldMax] + "...(+" + strconv.Itoa(len(v)-fieldMax) + ")"
		}
		return v
	case error:
		return clean(v.Error())
	case map[string]any:
		m := make(map[string]any, len(v))
		for k, e := range v {
			m[maskStr(k)] = clean(e)
		}
		return m
	case []any:
		if len(v) > listMax {
			v = v[:listMax]
		}
		l := make([]any, len(v))
		for i, e := range v {
			l[i] = clean(e)
		}
		return l
	}
	var back any
	if b, err := json.Marshal(x); err == nil && json.Unmarshal(b, &back) == nil {
		return clean(back)
	}
	return clean(fmt.Sprint(x))
}

var nameRe = regexp.MustCompile(`^lab-([a-z]+)-(\d+)\.jsonl$`)

// Journal writes one stream: <Logs>/lab-<stream>-<N>.jsonl. With a nil file it keeps only the ring.
type Journal struct {
	*state
	src string
}

type state struct {
	mu      sync.Mutex
	dir     string
	stream  string
	fh      *os.File
	size    int64
	num     int
	ring    []string
	last    string
	repeat  int
	lastSrc string
	lastEv  string
	rolled  bool
	drops   atomic.Int64
}

var _ api.Logger = (*Journal)(nil)

// New opens the stream, continuing the last file if it is not full.
func New(p api.Paths, stream string) (*Journal, error) {
	j := &Journal{&state{dir: p.Logs, stream: stream, num: 1}, stream}
	if err := os.MkdirAll(p.Logs, 0o755); err != nil {
		return nil, err
	}
	ents, _ := os.ReadDir(p.Logs)
	for _, e := range ents {
		if m := nameRe.FindStringSubmatch(e.Name()); m != nil && m[1] == stream {
			if n, _ := strconv.Atoi(m[2]); n > j.num {
				j.num = n
			}
		}
	}
	j.open(true)
	return j, nil
}

// Boot returns a logger for early start; on failure it keeps the ring only.
func Boot(home string) api.Logger {
	if j, err := New(api.NewPaths(home), api.StreamBoot); err == nil {
		return j
	}
	return &Journal{&state{stream: api.StreamBoot}, api.StreamBoot}
}

func (j *state) path(n int) string {
	return filepath.Join(j.dir, "lab-"+j.stream+"-"+strconv.Itoa(n)+".jsonl")
}

func (j *state) open(appendMode bool) {
	if j.fh != nil {
		j.fh.Close()
		j.fh = nil
	}
	j.size = 0
	if st, err := os.Stat(j.path(j.num)); err == nil && appendMode {
		j.size = st.Size()
	}
	if j.size >= fileMax {
		j.roll()
		return
	}
	fh, err := os.OpenFile(j.path(j.num), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		fmt.Fprintln(os.Stderr, "journal: open failed")
		return
	}
	j.fh = fh
}

func (j *state) roll() {
	j.num++
	removed := false
	ents, _ := os.ReadDir(j.dir)
	for _, e := range ents {
		if m := nameRe.FindStringSubmatch(e.Name()); m != nil && m[1] == j.stream {
			if n, _ := strconv.Atoi(m[2]); n <= j.num-filesMax && os.Remove(filepath.Join(j.dir, e.Name())) == nil {
				removed = true
			}
		}
	}
	j.open(false)
	if removed && !j.rolled {
		j.rolled = true // overflow is recorded once
		j.emit(rec{"ts": now(), "src": "journal", "ev": "journal.rollover", "data": map[string]any{"max_files": filesMax, "file_mb": fileMax >> 20}})
	}
}

type rec = map[string]any

func now() string { return time.Now().Format("2006-01-02T15:04:05.000-07:00") }

func (j *state) emit(r rec) {
	b, _ := json.Marshal(r)
	if len(b) > recMax {
		b, _ = json.Marshal(rec{"ts": r["ts"], "src": r["src"], "ev": r["ev"], "data": map[string]any{"truncated_chars": len(b)}})
	}
	if j.ring = append(j.ring, string(b)); len(j.ring) > ringMax {
		j.ring = j.ring[len(j.ring)-ringMax:]
	}
	if j.fh == nil {
		j.drops.Add(1)
		return
	}
	b = append(b, '\n')
	n, err := j.fh.Write(b)
	if err != nil {
		j.drops.Add(1)
		return
	}
	if j.size += int64(n); j.size >= fileMax {
		j.roll()
	}
}

func (j *state) flushRepeat() {
	if j.repeat > 0 {
		n := j.repeat
		j.repeat = 0
		j.emit(rec{"ts": now(), "src": j.lastSrc, "ev": j.lastEv, "data": map[string]any{"repeated": n}})
	}
}

// log writes {"ts","src","ev","data","why"}; identical consecutive records fold into "repeated N".
func (j *state) log(src, ev string, data map[string]any, why string) {
	r := rec{"ts": now(), "src": src, "ev": ev}
	if len(data) > 0 {
		r["data"] = clean(data)
	}
	if why != "" {
		r["why"] = clean(why)
	}
	kb, _ := json.Marshal([]any{src, ev, r["data"], r["why"]})
	key := string(kb)
	j.mu.Lock()
	defer j.mu.Unlock()
	if key == j.last {
		j.repeat++
		return
	}
	j.flushRepeat()
	j.last, j.lastSrc, j.lastEv = key, src, ev
	j.emit(r)
}

// kvs turns key/value pairs into data; "why" goes to its own field.
func kvs(kv []any) (map[string]any, string) {
	m := map[string]any{}
	why := ""
	for i := 0; i < len(kv); i += 2 {
		k := fmt.Sprint(kv[i])
		if i+1 >= len(kv) {
			m[k] = nil
		} else if k == "why" {
			why = fmt.Sprint(kv[i+1])
		} else {
			m[k] = kv[i+1]
		}
	}
	return m, why
}

func (j *Journal) at(level, event string, kv []any) {
	d, why := kvs(kv)
	if level != "" {
		d["level"] = level
	}
	j.log(j.src, event, d, why)
}

func (j *Journal) Info(event string, kv ...any)  { j.at("", event, kv) }
func (j *Journal) Warn(event string, kv ...any)  { j.at("warn", event, kv) }
func (j *Journal) Error(event string, kv ...any) { j.at("error", event, kv) }

// With returns a logger of the same stream whose records carry src=component.
func (j *Journal) With(component string) api.Logger { return &Journal{j.state, component} }

// Secret registers a value for masking in all streams.
func (j *Journal) Secret(value string) { register(value) }

// Drops is the number of records that could not be written to the file.
func (j *Journal) Drops() int64 { return j.drops.Load() }

// Tail returns the last n records (JSON lines) from the ring.
func (j *Journal) Tail(n int) []string {
	j.mu.Lock()
	defer j.mu.Unlock()
	j.flushRepeat()
	n = max(1, min(n, ringMax))
	return append([]string(nil), j.ring[max(0, len(j.ring)-n):]...)
}

// Close flushes the folded repeat and closes the file.
func (j *Journal) Close() error {
	j.mu.Lock()
	defer j.mu.Unlock()
	j.flushRepeat()
	if j.fh == nil {
		return nil
	}
	err := j.fh.Close()
	j.fh = nil
	return err
}

// Writer logs each written line as ev=<stream>.line with src=source (masked).
func (j *Journal) Writer(stream, source string) io.WriteCloser {
	return &lineWriter{j: j, ev: stream + ".line", src: source}
}

type lineWriter struct {
	j       *Journal
	ev, src string
	buf     []byte
}

func (w *lineWriter) Write(p []byte) (int, error) {
	n := len(p)
	for len(p) > 0 {
		i := bytes.IndexByte(p, '\n')
		part := p
		if i >= 0 {
			part = p[:i]
		}
		// Keep at most LINE_MAX bytes, as in v2; discard the rest of an
		// oversized chunk rather than accumulating an unbounded line.
		w.buf = append(w.buf, part[:min(len(part), lineMax-len(w.buf))]...)
		if i >= 0 || len(w.buf) == lineMax {
			w.put(w.buf)
			w.buf = w.buf[:0]
		}
		if i < 0 {
			break
		}
		p = p[i+1:]
	}
	return n, nil
}

func (w *lineWriter) put(b []byte) {
	if s := strings.TrimRight(string(b), "\r"); s != "" {
		w.j.state.log(w.src, w.ev, map[string]any{"line": s}, "")
	}
}

func (w *lineWriter) Close() error {
	w.put(w.buf)
	w.buf = nil
	return nil
}

// Mask applies the journal's shared secret masker to launcher protocol text.
func Mask(text string) string { return maskStr(text) }
