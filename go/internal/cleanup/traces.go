package cleanup

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"remoteagents/internal/api"
)

func (c *Cleaner) Intent(t api.Trace) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if t.Kind == "" || t.ID == "" || t.Owner == "" || (t.Instance != "" && t.Instance != c.instance) {
		return fmt.Errorf("cleanup: trace: invalid identity")
	}
	t.Phase, t.Instance = "intent", c.instance
	return c.append(t)
}

func (c *Cleaner) Applied(kind, id string, data, set map[string]string) error {
	return c.transition(kind, id, "applied", data, set)
}

func (c *Cleaner) Done(kind, id string) error {
	return c.transition(kind, id, "done", nil, nil)
}

func (c *Cleaner) Instance() string {
	return c.instance
}

func (c *Cleaner) transition(kind, id, phase string, data, set map[string]string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	traces, err := c.read()
	if err != nil {
		return err
	}
	for i := len(traces) - 1; i >= 0; i-- {
		t := traces[i]
		if t.Kind != kind || t.ID != id {
			continue
		}
		if t.Phase == "done" && phase == "done" {
			return nil
		}
		if t.Phase == "done" && phase != "done" {
			break
		}
		t.Phase = phase
		if t.Data == nil {
			t.Data = map[string]string{}
		}
		for k, v := range data {
			t.Data[k] = v
		}
		if set != nil {
			t.Set = set
		}
		return c.append(t)
	}
	return fmt.Errorf("cleanup: trace: unknown intent")
}

func (c *Cleaner) read() ([]api.Trace, error) {
	f, err := os.Open(filepath.Join(c.p.State, "traces.jsonl"))
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("cleanup: read: %w", err)
	}
	defer func() { _ = f.Close() }()
	var traces []api.Trace
	s := bufio.NewScanner(f)
	s.Buffer(make([]byte, 4096), 4<<20)
	for s.Scan() {
		line := bytes.TrimSpace(s.Bytes())
		if len(line) == 0 {
			continue
		}
		var t api.Trace
		if json.Unmarshal(line, &t) == nil && t.Instance == c.instance {
			traces = append(traces, t)
		}
	}
	return traces, s.Err()
}

func (c *Cleaner) append(t api.Trace) error {
	b, err := json.Marshal(t)
	if err != nil {
		return fmt.Errorf("cleanup: encode: %w", err)
	}
	f, err := os.OpenFile(filepath.Join(c.p.State, "traces.jsonl"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		return fmt.Errorf("cleanup: journal: %w", err)
	}
	defer func() { _ = f.Close() }()
	// A leading newline isolates a record from an interrupted preceding write.
	_, err = f.Write(append(append([]byte{'\n'}, b...), '\n'))
	if err == nil {
		err = f.Sync()
	}
	if err == nil {
		var dir *os.File
		dir, err = os.Open(c.p.State)
		if err == nil {
			err = dir.Sync()
			_ = dir.Close()
		}
	}
	if err != nil {
		return fmt.Errorf("cleanup: sync: %w", err)
	}
	return nil
}
