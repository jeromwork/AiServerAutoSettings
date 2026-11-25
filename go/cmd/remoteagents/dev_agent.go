package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"remoteagents/internal/agent"
	"remoteagents/internal/api"
	"remoteagents/internal/api/fake"
)

func init() {
	for _, name := range []string{"agent", "p11"} {
		api.RegisterDev(api.DevCmd{
			Name: name,
			Help: "run acceptance checks against fake agent: /status, /exec, auth, /code",
			Run:  devAgent,
		})
	}
}

type devFakeProc struct {
	id        string
	mu        sync.Mutex
	outBuf    []byte
	errBuf    []byte
	exited    bool
	code      int
	truncated bool
}

func (p *devFakeProc) ID() string { return p.id }

func (p *devFakeProc) Read(stream string, off int) api.Chunk {
	p.mu.Lock()
	defer p.mu.Unlock()
	buf := p.outBuf
	if stream == "err" {
		buf = p.errBuf
	}
	if off < 0 {
		off = 0
	}
	if off > len(buf) {
		off = len(buf)
	}
	data := make([]byte, len(buf[off:]))
	copy(data, buf[off:])
	return api.Chunk{
		Data:    data,
		NextOff: off + len(data),
		Base:    0,
	}
}

func (p *devFakeProc) WaitNew(ctx context.Context, outOff, errOff int, max time.Duration) {
	deadline := time.Now().Add(max)
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()
	for {
		p.mu.Lock()
		exited := p.exited
		hasOut := outOff < len(p.outBuf)
		hasErr := errOff < len(p.errBuf)
		p.mu.Unlock()

		if exited || hasOut || hasErr {
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if time.Now().After(deadline) {
				return
			}
		}
	}
}

func (p *devFakeProc) Exited() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.exited
}

func (p *devFakeProc) Drained(outOff, errOff int) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.exited && outOff >= len(p.outBuf) && errOff >= len(p.errBuf)
}

func (p *devFakeProc) Code() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.code
}

func (p *devFakeProc) Truncated() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.truncated
}

func (p *devFakeProc) Kill() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.exited = true
	p.code = -1
	return nil
}

type devFakeShell struct {
	mu    sync.Mutex
	seq   int
	procs map[string]*devFakeProc
}

func (s *devFakeShell) Start(ctx context.Context, req api.ExecReq) (api.ExecProc, error) {
	s.mu.Lock()
	s.seq++
	id := fmt.Sprintf("dev-%d", s.seq)
	proc := &devFakeProc{id: id}
	if s.procs == nil {
		s.procs = make(map[string]*devFakeProc)
	}
	s.procs[id] = proc
	s.mu.Unlock()

	go func() {
		var out, errOut []byte
		var code int
		if strings.Contains(req.Cmd, "echo hi") {
			out = []byte("hi\n")
			code = 0
		} else {
			errOut = []byte("dev fake: unsupported command")
			code = 127
		}

		proc.mu.Lock()
		proc.outBuf = out
		proc.errBuf = errOut
		proc.exited = true
		proc.code = code
		proc.mu.Unlock()
	}()

	return proc, nil
}

func (s *devFakeShell) Get(id string) (api.ExecProc, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	p, ok := s.procs[id]
	return p, ok
}

func (s *devFakeShell) List() []api.ExecProc {
	s.mu.Lock()
	defer s.mu.Unlock()
	res := make([]api.ExecProc, 0, len(s.procs))
	for _, p := range s.procs {
		res = append(res, p)
	}
	return res
}

func (s *devFakeShell) KillAll() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, p := range s.procs {
		_ = p.Kill()
	}
	return nil
}

func devAgent(ctx context.Context, args []string) int {
	var lc net.ListenConfig
	ln, err := lc.Listen(ctx, "tcp", "127.0.0.1:0")
	if err != nil {
		fmt.Fprintf(os.Stderr, "agent: listen: %v\n", err)
		return 1
	}
	defer func() { _ = ln.Close() }()

	homeDir, err := os.MkdirTemp("", "ra3-dev-agent-")
	if err != nil {
		fmt.Fprintf(os.Stderr, "agent: temp: %v\n", err)
		return 1
	}
	defer func() { _ = os.RemoveAll(homeDir) }()

	paths := api.NewPaths(homeDir)
	log := &fake.Logger{}
	act := &fake.Actions{}
	shell := &devFakeShell{}

	ag, err := agent.New(api.AgentDeps{
		Log:     log,
		Shell:   shell,
		Act:     act,
		Paths:   paths,
		Control: func() bool { return true },
		Status: func() map[string]any {
			return map[string]any{"state": "running", "version": "v3-dev"}
		},
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "agent: new: %v\n", err)
		return 1
	}
	ag.Serve(ln)
	defer func() { _ = ag.Close() }()

	baseURL := fmt.Sprintf("http://127.0.0.1:%d", ln.Addr().(*net.TCPAddr).Port)
	client := &http.Client{Timeout: 5 * time.Second}

	// 1. без токена -> 403
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, baseURL+"/status", nil)
	resp, err := client.Do(req)
	if err != nil {
		fmt.Fprintf(os.Stderr, "agent: test 1 failed: %v\n", err)
		return 1
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden {
		fmt.Fprintf(os.Stderr, "agent: expected 403 without token, got %d\n", resp.StatusCode)
		return 1
	}

	// 2. curl /status -> 200 с platform
	req, _ = http.NewRequestWithContext(ctx, http.MethodGet, baseURL+"/status", nil)
	req.Header.Set("Authorization", "Bearer "+ag.Token())
	resp, err = client.Do(req)
	if err != nil {
		fmt.Fprintf(os.Stderr, "agent: test 2 failed: %v\n", err)
		return 1
	}
	body, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		fmt.Fprintf(os.Stderr, "agent: expected 200 for /status, got %d: %s\n", resp.StatusCode, string(body))
		return 1
	}
	var st map[string]any
	if err := json.Unmarshal(body, &st); err != nil || st["platform"] == nil || st["platform"] == "" {
		fmt.Fprintf(os.Stderr, "agent: /status missing platform: %s\n", string(body))
		return 1
	}

	// 3. /code -> 501
	req, _ = http.NewRequestWithContext(ctx, http.MethodPost, baseURL+"/code", strings.NewReader("sample"))
	req.Header.Set("Authorization", "Bearer "+ag.Token())
	resp, err = client.Do(req)
	if err != nil {
		fmt.Fprintf(os.Stderr, "agent: test 3 failed: %v\n", err)
		return 1
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusNotImplemented {
		fmt.Fprintf(os.Stderr, "agent: expected 501 for /code, got %d\n", resp.StatusCode)
		return 1
	}

	// 4. /exec {"cmd":"echo hi","shell":"sh","wait":true} -> out содержит hi
	execPayload := []byte(`{"cmd":"echo hi","shell":"sh","wait":true}`)
	req, _ = http.NewRequestWithContext(ctx, http.MethodPost, baseURL+"/exec", bytes.NewReader(execPayload))
	req.Header.Set("Authorization", "Bearer "+ag.Token())
	resp, err = client.Do(req)
	if err != nil {
		fmt.Fprintf(os.Stderr, "agent: test 4 failed: %v\n", err)
		return 1
	}
	execRespBody, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		fmt.Fprintf(os.Stderr, "agent: expected 200 for /exec, got %d: %s\n", resp.StatusCode, string(execRespBody))
		return 1
	}
	var execRes map[string]any
	if err := json.Unmarshal(execRespBody, &execRes); err != nil {
		fmt.Fprintf(os.Stderr, "agent: invalid json from /exec: %s\n", string(execRespBody))
		return 1
	}
	outStr, _ := execRes["out"].(string)
	if !strings.Contains(outStr, "hi") {
		fmt.Fprintf(os.Stderr, "agent: expected out to contain hi, got: %q\n", outStr)
		return 1
	}

	fmt.Printf("agent dev driver OK: /status -> 200 with platform=%v, /exec -> out contains hi, auth -> 403, /code -> 501\n", st["platform"])

	if len(args) > 0 && args[0] == "listen" {
		fmt.Printf("agent listening on %s\n", baseURL)
		<-ctx.Done()
	}

	return 0
}
