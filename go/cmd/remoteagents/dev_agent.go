package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"

	"remoteagents/internal/agent"
	"remoteagents/internal/api"
	"remoteagents/internal/api/fake"
)

func init() {
	api.RegisterDev(api.DevCmd{Name: "agent", Help: "agent: самопроверка на временном home (токен, exec, files, переключатель)", Run: runDevAgent})
}

func runDevAgent(ctx context.Context, args []string) int {
	home, err := os.MkdirTemp("", "ra-agent-")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	defer os.RemoveAll(home)
	a, err := agent.New(api.AgentDeps{Log: &fake.Logger{}, Paths: api.NewPaths(home), Status: func() map[string]any { return map[string]any{"ok": true} }})
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	go a.Serve(l)
	defer a.Close()
	call := func(method, path, tok, body string) string {
		req, _ := http.NewRequest(method, "http://"+l.Addr().String()+path, strings.NewReader(body))
		if tok != "" {
			req.Header.Set("Authorization", "Bearer "+tok)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return "ошибка: " + err.Error()
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return fmt.Sprintf("%d %s", resp.StatusCode, b)
	}
	fmt.Println("без токена:", call("GET", "/status", "", ""))
	fmt.Println("status:", call("GET", "/status", a.Token(), ""))
	b, _ := json.Marshal(map[string]any{"cmd": "echo hi", "shell": "cmd", "wait": true})
	fmt.Println("exec:", call("POST", "/exec", a.Token(), string(b)))
	fmt.Println("files:", call("GET", "/files?path="+home, a.Token(), ""))
	_ = agent.SetEnabled(api.NewPaths(home), false)
	fmt.Println("управление выключено:", call("GET", "/procs", a.Token(), ""))
	return 0
}
