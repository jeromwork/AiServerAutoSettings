package core

import (
	"context"
	"errors"
	"testing"
)

type fakePF struct {
	applied  int
	released int
	tun      string
	active   bool
	failRel  bool
}

func (f *fakePF) Apply(_ context.Context, tun string, _ []string) error {
	f.applied++
	f.tun, f.active = tun, true
	return nil
}
func (f *fakePF) Release(context.Context) error {
	f.released++
	if f.failRel {
		return errors.New("pfctl не ответил")
	}
	f.active = false
	return nil
}

func newPFCore(lock bool) (*core, *fvSb, *fakePF) {
	c, sb := newLockCore(lock)
	pf := &fakePF{}
	c.tun.pfh.sw = pf
	c.p.State = "/tmp/pf-test"
	return c, sb, pf
}

// Галочка + VPN поднят → якорь стоит; снятие галочки снимает якорь.
func TestPFAppliedWithLockAndRemovedWithoutIt(t *testing.T) {
	c, _, pf := newPFCore(true)
	g := c.tun
	g.mu.Lock()
	g.syncPF(context.Background(), true, true)
	g.mu.Unlock()
	if !pf.active || pf.tun != "ra3-testinst-vpn" {
		t.Fatalf("якорь не стоит: %+v", pf)
	}
	c.cfg.VPN.LockExit = false
	g.mu.Lock()
	g.syncPF(context.Background(), true, true)
	g.mu.Unlock()
	if pf.active {
		t.Fatal("галочку сняли — якорь обязан сняться")
	}
}

// ГЛАВНОЕ: выключение VPN снимает якорь, даже если процесс VPN не останавливается (Apply висит/падает) и даже без mu.
func TestPFOffReleases(t *testing.T) {
	c, _, pf := newPFCore(true)
	g := c.tun
	g.mu.Lock()
	g.syncPF(context.Background(), true, true)
	g.mu.Unlock()
	if !pf.active {
		t.Fatal("якорь не стоит")
	}
	g.setMode(context.Background(), "off")
	if pf.active {
		t.Fatal("после off якорь остался")
	}
}

// Падение sing-box (VPN не поднят) с галочкой: уже стоящий якорь остаётся (это и есть блок), новый не ставится до TUN.
func TestPFStaysWhenCoreDiesAndNotAppliedBeforeTun(t *testing.T) {
	c, _, pf := newPFCore(true)
	g := c.tun
	g.mu.Lock()
	g.syncPF(context.Background(), true, false)
	g.mu.Unlock()
	if pf.applied != 0 {
		t.Fatal("якорь до TUN не ставится")
	}
	g.mu.Lock()
	g.syncPF(context.Background(), true, true)
	g.syncPF(context.Background(), true, false)
	g.mu.Unlock()
	if !pf.active {
		t.Fatal("якорь должен остаться при падении процесса VPN")
	}
}

// Старт программы и выход снимают якорь; ошибка снятия не паникует и пишется в журнал.
func TestPFReleaseOnStartAndErrorsAreSurvivable(t *testing.T) {
	c, _, pf := newPFCore(true)
	pf.active = true
	c.tun.releasePF(context.Background(), "start")
	if pf.active || pf.released != 1 {
		t.Fatalf("%+v", pf)
	}
	pf.failRel = true
	c.tun.releasePF(context.Background(), "exit")
}
