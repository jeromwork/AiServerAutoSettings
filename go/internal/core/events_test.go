package core

import (
	"context"
	"strings"
	"testing"

	"remoteagents/internal/api"
	"remoteagents/internal/api/fake"
	"remoteagents/internal/journal"
)

func TestCheckPCName(t *testing.T) {
	if err := checkPCName("", "Ноутбук Ивана"); err != nil {
		t.Fatalf("кириллица переводится в латиницу: %v", err)
	}
	if err := checkPCName("", "!!! ???"); err == nil || !strings.Contains(err.Error(), "латиницей") {
		t.Fatalf("пустое имя должно отклоняться понятно: %v", err)
	}
	if err := checkPCName("", ""); err == nil {
		t.Fatal("пустое имя принято")
	}
	if err := checkPCName("bad name", "x"); err == nil {
		t.Fatal("плохой --pc принят")
	}
	if err := checkPCName("good-pc", ""); err != nil {
		t.Fatal(err)
	}
}

func TestSanitize(t *testing.T) {
	journal.RegisterSecret("supersecretvalue")
	in := "dial tcp 203.0.113.5:443: i/o timeout; lookup node.example.com: no such host; supersecretvalue; [2001:db8::1]:22"
	out := sanitize(in)
	for _, bad := range []string{"203.0.113.5", "example.com", "supersecretvalue", "2001:db8"} {
		if strings.Contains(out, bad) {
			t.Fatalf("утечка %q в %q", bad, out)
		}
	}
	if !strings.Contains(out, "i/o timeout") {
		t.Fatalf("испорчен текст: %q", out)
	}
}

// Причина «страница показывает устаревшее»: после up/commit не публиковались ready и свежий status, а при
// подключении SSE отдавалось последнее опубликованное, а не текущее.
func TestChannelUpPublishesReadyAndClearsError(t *testing.T) {
	dir := t.TempDir()
	c := &core{p: api.NewPaths(dir), log: &fake.Logger{}, quit: make(chan quitReq, 1)}
	c.ev.kick = make(chan struct{}, 1)
	c.errMu.Lock()
	c.lastErr = "Не запустился sing-box: старая ошибка"
	c.errMu.Unlock()
	c.publishApply("checking", "проверяю")

	updates := make(chan api.ChannelState, 2)
	updates <- api.ChannelState{State: "connecting", Path: "hy2-sparfum"}
	updates <- api.ChannelState{State: "up", Path: "hy2-sparfum", Session: 1}
	close(updates)
	c.watchChannel(context.Background(), updates, func() {})

	snap := c.snapshot()
	ap, _ := snap["apply"].(map[string]any)
	if ap["stage"] != "ready" {
		t.Fatalf("apply=%v", ap)
	}
	st, _ := snap["status"].(map[string]any)
	conn, _ := st["connect"].(map[string]any)
	if conn["error"] != "" {
		t.Fatalf("ошибка прошлой попытки осталась: %v", conn)
	}
	att, _ := snap["attempts"].([]attempt)
	if len(att) != 2 || att[0].Path != "hy2-sparfum" || att[1].State != "ok" {
		t.Fatalf("attempts=%v", att)
	}
}
