package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"remoteagents/internal/api"
	"remoteagents/internal/config"
)

// Причина: update.Stage вызывает `config check --current --home H`, а CLI не знал флага --current
// и выходил с кодом 2 («candidate rejected current config: exit status 2»).
func TestConfigCheckCurrent(t *testing.T) {
	home := t.TempDir()
	run := func() int {
		return runCLI(context.Background(), "config", []string{"check", "--current", "--home", home})
	}
	if c := run(); c != 0 {
		t.Fatalf("no config at all must pass, got %d", c)
	}
	sample := filepath.Join(t.TempDir(), "s.json")
	if err := writeSample(sample, "pw"); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(sample)
	p := api.NewPaths(home)
	if _, err := config.Apply(p, b, "pw", nil); err != nil {
		t.Fatal(err)
	}
	if c := run(); c != 0 {
		t.Fatalf("valid current gen must pass, got %d", c)
	}
	if err := os.Remove(filepath.Join(config.GenDir(p, "gen-1"), "active.json")); err != nil {
		t.Fatal(err)
	}
	if c := run(); c != 1 {
		t.Fatalf("broken current gen must fail with 1, got %d", c)
	}
}
