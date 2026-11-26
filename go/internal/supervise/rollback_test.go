//go:build !windows

package supervise

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"remoteagents/internal/api"
	"remoteagents/internal/api/fake"
	"remoteagents/internal/config"
)

// Сценарии отката версии (задание U): кандидат падает / молчит без good / сам просит откат / конфиг не принят.
// Каждая «версия» — shell-скрипт: `version`, `version --json` и `run` с заданным поведением.

func script(version string, schema int, runBody string) string {
	return fmt.Sprintf(`#!/bin/sh
case "$1" in
version)
  if [ "$2" = "--json" ]; then echo '{"version":"%[1]s","schema":%[2]d}'; else echo %[1]s; fi
  exit 0;;
run)
%[3]s
;;
esac
exit 0
`, version, schema, runBody)
}

const runGood = `  echo '{"t":"good","version":"VER"}'
  : > "$3/ok-VER"
  sleep 30
  exit 0`

type rig struct {
	t    *testing.T
	home string
	p    api.Paths
	self string
}

func newRig(t *testing.T, embeddedSchema int) *rig {
	t.Helper()
	root := t.TempDir()
	r := &rig{t: t, home: filepath.Join(root, "home"), self: filepath.Join(root, "remoteagents")}
	r.p = api.NewPaths(r.home)
	for _, d := range []string{r.p.State, r.p.Versions, r.p.Config, r.p.Tmp, r.p.Bin} {
		if err := os.MkdirAll(d, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	body := strings.ReplaceAll(runGood, "VER", "3.0.1")
	r.write(r.self, script("3.0.1", embeddedSchema, body))
	return r
}

func (r *rig) write(path, content string) {
	r.t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		r.t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o700); err != nil {
		r.t.Fatal(err)
	}
}

// slot кладёт версию в versions/<v>.
func (r *rig) slot(v string, schema int, runBody string) {
	r.write(filepath.Join(r.p.Versions, v, "remoteagents"), script(v, schema, runBody))
}

func (r *rig) state(cur, lastGood string) {
	b, _ := json.Marshal(slotState{Schema: 1, Current: cur, LastGood: lastGood, EmbeddedSeen: "3.0.1"})
	if err := os.WriteFile(filepath.Join(r.p.Versions, "state.json"), b, 0o600); err != nil {
		r.t.Fatal(err)
	}
}

func (r *rig) gen(name string, schema int, good bool) {
	dir := config.GenDir(r.p, name)
	r.write(filepath.Join(dir, "active.json"), "{}\n")
	r.write(filepath.Join(dir, "meta.json"), fmt.Sprintf("{\"schema\":%d}\n", schema))
	if good {
		r.write(filepath.Join(dir, "good"), "1\n")
	}
}

func (r *rig) ptr(name, val string) {
	r.write(filepath.Join(r.p.Config, name), val+"\n")
}

// run запускает сторож (--fast: тишина 3 с) и ждёт, пока вернувшаяся на 3.0.1 версия пришлёт good.
func (r *rig) run() slotState {
	r.t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan int, 1)
	go func() {
		done <- Run(ctx, r.p, &fake.Logger{}, NewSimulationProcs(), r.self, api.Mode{Safe: true}, []string{"--home", r.home, "--fast"})
	}()
	marker := filepath.Join(r.home, "ok-3.0.1")
	deadline := time.Now().Add(20 * time.Second)
	for {
		if _, err := os.Stat(marker); err == nil {
			break
		}
		select {
		case code := <-done:
			r.t.Fatalf("supervisor exited early with %d before 3.0.1 became good", code)
		case <-time.After(50 * time.Millisecond):
		}
		if time.Now().After(deadline) {
			cancel()
			r.t.Fatal("3.0.1 never became good (rollback did not happen)")
		}
	}
	cancel()
	select {
	case <-done:
	case <-time.After(15 * time.Second):
		r.t.Fatal("supervisor did not stop")
	}
	var st slotState
	b, err := os.ReadFile(filepath.Join(r.p.Versions, "state.json"))
	if err != nil || json.Unmarshal(b, &st) != nil {
		r.t.Fatalf("state: %v", err)
	}
	return st
}

func (r *rig) wantRolledBack(st slotState, reason string) {
	r.t.Helper()
	if st.Current != "3.0.1" || st.LastGood != "3.0.1" {
		r.t.Fatalf("state %+v: want current/lastGood 3.0.1", st)
	}
	if !strings.Contains(st.RollbackReason, reason) && st.RollbackReason != "" {
		// после good причина очищается (markGood) — допускаем пустую, но не чужую.
		r.t.Fatalf("rollbackReason %q, want %q", st.RollbackReason, reason)
	}
	ptr, err := config.ReadPointers(r.p)
	if err != nil || ptr.Switch != nil {
		r.t.Fatalf("pointers after rollback: %+v %v (switch must be gone so config apply works)", ptr, err)
	}
}

func TestCandidateCrashRollsBackVersionAndConfig(t *testing.T) {
	r := newRig(t, 1)
	r.slot("3.0.2", 2, "  exit 1")
	r.gen("gen-1", 1, true)
	r.gen("gen-2", 2, false) // новая версия записала конфиг новой схемы
	r.ptr("lastgood", "gen-1")
	r.ptr("current", "gen-2")
	r.state("3.0.2", "3.0.1")
	st := r.run()
	r.wantRolledBack(st, "crashed")
	ptr, _ := config.ReadPointers(r.p)
	if ptr.Current != "gen-1" {
		t.Fatalf("config current %s, want gen-1 (старая версия не читает схему 2)", ptr.Current)
	}
}

func TestCandidateWithoutGoodRollsBack(t *testing.T) {
	r := newRig(t, 1)
	r.slot("3.0.2", 1, "  sleep 60")
	r.state("3.0.2", "3.0.1")
	st := r.run()
	r.wantRolledBack(st, "")
}

func TestCandidateRollbackMessageRollsBack(t *testing.T) {
	r := newRig(t, 1)
	r.slot("3.0.2", 1, `  echo '{"t":"rollback","reason":"user asked"}'
  exit 3`)
	r.state("3.0.2", "3.0.1")
	r.wantRolledBack(r.run(), "")
}

// Конфиг не принят: канал на новой версии не поднялся, switch.json истёк — current возвращается на From,
// версия откатывается, а Apply не блокируется ErrPending.
func TestConfigNotAcceptedRollsBackBoth(t *testing.T) {
	r := newRig(t, 1)
	r.slot("3.0.2", 1, "  sleep 60")
	r.gen("gen-1", 1, true)
	r.gen("gen-2", 1, false)
	r.ptr("lastgood", "gen-1")
	r.ptr("current", "gen-2")
	past := time.Now().Add(-time.Minute).UTC().Format(time.RFC3339Nano)
	r.write(filepath.Join(r.p.Config, "switch.json"), fmt.Sprintf(`{"op":"apply","from":"gen-1","to":"gen-2","started":"%s","deadline":"%s"}`, past, past))
	r.state("3.0.2", "3.0.1")
	st := r.run()
	r.wantRolledBack(st, "")
	ptr, _ := config.ReadPointers(r.p)
	if ptr.Current != "gen-1" {
		t.Fatalf("config current %s, want gen-1", ptr.Current)
	}
}

// Сетевая ошибка не краш версии: версия шлёт good и сразу выходит с кодом 3 (fast-revert конфига) —
// версия остаётся на месте (3.0.2 → lastGood), откат версии не запускается.
func TestNetworkErrorKeepsVersion(t *testing.T) {
	r := newRig(t, 1)
	n := filepath.Join(r.home, "n")
	r.slot("3.0.2", 1, fmt.Sprintf(`  echo '{"t":"good","version":"3.0.2"}'
  if [ -e %[1]s ]; then : > "$3/ok-3.0.2"; sleep 30; exit 0; fi
  : > %[1]s
  exit 3`, n))
	r.state("3.0.2", "3.0.1")
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan int, 1)
	go func() {
		done <- Run(ctx, r.p, &fake.Logger{}, NewSimulationProcs(), r.self, api.Mode{Safe: true}, []string{"--home", r.home, "--fast"})
	}()
	deadline := time.Now().Add(15 * time.Second)
	for {
		if _, err := os.Stat(filepath.Join(r.home, "ok-3.0.2")); err == nil {
			break
		}
		if time.Now().After(deadline) {
			cancel()
			t.Fatal("3.0.2 did not stay current after the network error")
		}
		time.Sleep(50 * time.Millisecond)
	}
	cancel()
	<-done
	var st slotState
	b, _ := os.ReadFile(filepath.Join(r.p.Versions, "state.json"))
	_ = json.Unmarshal(b, &st)
	if st.Current != "3.0.2" || st.LastGood != "3.0.2" {
		t.Fatalf("state %+v: version must stay 3.0.2", st)
	}
}
