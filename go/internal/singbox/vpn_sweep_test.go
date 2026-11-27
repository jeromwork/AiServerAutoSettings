package singbox

import (
	"context"
	"testing"
	"time"

	"remoteagents/internal/api"
	"remoteagents/internal/api/fake"
)

type deadProc struct{ done chan struct{} }

func (deadProc) PID() int                   { return 1 }
func (deadProc) Started() time.Time         { return time.Time{} }
func (d deadProc) Done() <-chan struct{}    { return d.done }
func (deadProc) ExitCode() int              { return 137 }
func (deadProc) Stop(context.Context) error { return nil }

func countSweeps(t *testing.T) *int {
	n := 0
	old := sweepVPNLock
	sweepVPNLock = func(context.Context) error { n++; return nil }
	t.Cleanup(func() { sweepVPNLock = old })
	return &n
}

// Выключение VPN: правила (nft/ip rule) убираются сразу, не ждут перезапуска программы.
func TestStopVPNSweepsLockRules(t *testing.T) {
	n := countSweeps(t)
	s := &box{log: &fake.Logger{}, binary: "sb", o: Options{Role: RoleVPN}}
	if err := s.stopVPN(context.Background()); err != nil || *n != 1 {
		t.Fatalf("err=%v sweeps=%d", err, *n)
	}
	// Основной (не VPN) процесс правил галочки не держит.
	*n = 0
	m := &box{log: &fake.Logger{}, binary: "sb"}
	_ = m.stopVPN(context.Background())
	if *n != 0 {
		t.Fatal("канальный бокс не должен трогать правила VPN")
	}
}

// Процесс VPN убит/упал (kill, SIGKILL ядра): остатки правил убираются сразу, до перезапуска.
func TestVPNProcessDeathSweepsLockRules(t *testing.T) {
	n := countSweeps(t)
	s := &box{log: &fake.Logger{}, binary: "sb", o: Options{Role: RoleVPN}}
	s.restart = func(context.Context, api.Effective) error { return nil }
	s.sleep = func(context.Context, time.Duration) bool { return false }
	p := deadProc{done: make(chan struct{})}
	close(p.done)
	s.proc = p
	s.watch(context.Background(), p, api.Effective{VPN: true})
	if *n != 1 {
		t.Fatalf("sweeps=%d", *n)
	}
}
