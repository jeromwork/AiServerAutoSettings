package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"remoteagents/internal/api"
)

func mkGen(t *testing.T, p api.Paths, gen string, schema int, good bool) {
	t.Helper()
	dir := GenDir(p, gen)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	must(os.WriteFile(filepath.Join(dir, "active.json"), []byte("{}\n"), 0o600))
	if schema > 0 { // 0 — поколение старой сборки без meta.json
		must(os.WriteFile(filepath.Join(dir, "meta.json"), []byte(`{"schema":`+string(rune('0'+schema))+"}\n"), 0o600))
	}
	if good {
		must(os.WriteFile(filepath.Join(dir, "good"), []byte("1\n"), 0o600))
	}
}

func setPtr(t *testing.T, p api.Paths, name, val string) {
	t.Helper()
	if err := writeLine(p, name, val); err != nil {
		t.Fatal(err)
	}
}

// Причина: откат версии оставлял current на поколении, которого старая версия не читает, и конфиг «ломался».
func TestCompatRollbackMovesToReadableGeneration(t *testing.T) {
	p := api.NewPaths(t.TempDir())
	mkGen(t, p, "gen-1", 0, true) // старая сборка: нет meta.json = схема 1
	mkGen(t, p, "gen-2", 1, true)
	mkGen(t, p, "gen-3", 2, false) // записана новой версией
	setPtr(t, p, "lastgood", "gen-2")
	setPtr(t, p, "current", "gen-3")
	if err := writeSwitch(p, Switch{Op: "apply", From: "gen-2", To: "gen-3"}); err != nil {
		t.Fatal(err)
	}
	// Версия со схемой 2 читает всё: ничего не меняется.
	if g, err := CompatRollback(p, 2, nil); err != nil || g != "" {
		t.Fatalf("schema 2: got %q %v", g, err)
	}
	g, err := CompatRollback(p, 1, nil)
	if err != nil || g != "gen-2" {
		t.Fatalf("got %q %v, want gen-2", g, err)
	}
	ptr, err := ReadPointers(p)
	if err != nil || ptr.Current != "gen-2" || ptr.Switch != nil {
		t.Fatalf("pointers after rollback: %+v %v", ptr, err)
	}
	// Повторно — уже совместимо.
	if g, _ := CompatRollback(p, 1, nil); g != "" {
		t.Fatalf("second call changed to %q", g)
	}
}

func TestCompatRollbackFallsBackToNewestGoodWhenLastGoodTooNew(t *testing.T) {
	p := api.NewPaths(t.TempDir())
	mkGen(t, p, "gen-1", 1, true)
	mkGen(t, p, "gen-2", 2, true)
	setPtr(t, p, "lastgood", "gen-2")
	setPtr(t, p, "current", "gen-2")
	if g, err := CompatRollback(p, 1, nil); err != nil || g != "gen-1" {
		t.Fatalf("got %q %v", g, err)
	}
}

func TestLoadRefusesNewerSchemaWithClearError(t *testing.T) {
	p := api.NewPaths(t.TempDir())
	mkGen(t, p, "gen-1", SchemaVersion+1, true)
	setPtr(t, p, "current", "gen-1")
	_, _, err := Load(p, nil)
	if err == nil || !strings.Contains(err.Error(), "newer-schema") || !strings.Contains(err.Error(), "config revert") {
		t.Fatalf("want newer-schema hint, got %v", err)
	}
}

func TestRevertSkipsNewerSchema(t *testing.T) {
	p := api.NewPaths(t.TempDir())
	mkGen(t, p, "gen-1", 1, true)
	mkGen(t, p, "gen-2", SchemaVersion+1, true)
	mkGen(t, p, "gen-3", 1, false)
	setPtr(t, p, "lastgood", "gen-2")
	setPtr(t, p, "current", "gen-3")
	// lastgood нечитаем (схема новее) — берётся предыдущее good с подходящей схемой: gen-1.
	if err := Revert(p, nil); err != nil {
		t.Fatal(err)
	}
	ptr, _ := ReadPointers(p)
	if ptr.Current != "gen-1" {
		t.Fatalf("current %s, want gen-1", ptr.Current)
	}
}
