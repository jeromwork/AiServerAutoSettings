package core

import (
	"strings"
	"testing"

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
