package config

import (
	"errors"
	"testing"
	"time"

	"remoteagents/internal/api"
)

func startTrial(t *testing.T, lock bool) (api.Paths, string, string) {
	t.Helper()
	p := api.NewPaths(t.TempDir())
	applyAndCommit(t, p, sealedConfig(t, map[string]any{"vpn": map[string]any{"mode": "auto", "bridges": []any{"a"}, "lockExit": lock}}))
	ptr, _ := ReadPointers(p)
	from := ptr.Current
	gen, err := SetVPNLock(p, !lock, nil)
	if err != nil {
		t.Fatal(err)
	}
	return p, from, gen
}

// В пробном окне повторное применение и смена галочки отклоняются.
func TestTrialRejectsSecondApply(t *testing.T) {
	p, _, _ := startTrial(t, false)
	if _, err := Apply(p, sealedConfig(t, nil), testPW, nil); !errors.Is(err, ErrPending) {
		t.Fatalf("apply: %v", err)
	}
	if _, err := SetVPNLock(p, false, nil); !errors.Is(err, ErrPending) {
		t.Fatalf("lock: %v", err)
	}
}

// Снять/выключить в окне нельзя отклонять: CancelTrial откатывает к From, окно снято, причина записана.
func TestCancelTrialRollsBackToFrom(t *testing.T) {
	p, from, _ := startTrial(t, true)
	ok, err := CancelTrial(p, nil)
	if err != nil || !ok {
		t.Fatalf("cancel: %v %v", ok, err)
	}
	ptr, _ := ReadPointers(p)
	if ptr.Switch != nil || ptr.Current != from {
		t.Fatalf("после отката: %+v, ждали current=%s", ptr, from)
	}
	if rb, ok := ReadRollback(p); !ok || rb.Reason != ReasonUser {
		t.Fatalf("rollback: %+v %v", rb, ok)
	}
	if ok, _ := CancelTrial(p, nil); ok {
		t.Fatal("окна уже нет")
	}
}

// Откат по сроку публикует причину: запомненную в окне, иначе «канал не поднялся».
func TestExpireRecordsReason(t *testing.T) {
	p, _, gen := startTrial(t, false)
	NoteTrialFailure(p, gen, "проверка туннеля не прошла")
	if exp, err := Expire(p, time.Now().Add(time.Hour), nil); err != nil || !exp {
		t.Fatalf("expire: %v %v", exp, err)
	}
	if rb, ok := ReadRollback(p); !ok || rb.Reason != "проверка туннеля не прошла" {
		t.Fatalf("rollback: %+v", rb)
	}
	p2, _, _ := startTrial(t, false)
	if _, err := Expire(p2, time.Now().Add(time.Hour), nil); err != nil {
		t.Fatal(err)
	}
	if rb, _ := ReadRollback(p2); rb.Reason != "канал не поднялся за 120 с" {
		t.Fatalf("reason: %q", rb.Reason)
	}
}

// Новый apply и commit сбрасывают старую причину отката.
func TestRollbackClearedByNextApply(t *testing.T) {
	p, _, _ := startTrial(t, false)
	_, _ = CancelTrial(p, nil)
	if _, ok := ReadRollback(p); !ok {
		t.Fatal("нет записи")
	}
	if _, err := SetVPNLock(p, true, nil); err != nil {
		t.Fatal(err)
	}
	if _, ok := ReadRollback(p); ok {
		t.Fatal("запись осталась после нового apply")
	}
}
