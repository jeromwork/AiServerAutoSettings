package core

import (
	"context"
	"testing"

	"remoteagents/internal/api"
	"remoteagents/internal/api/fake"
)

func newLockCore(lock bool) (*core, *fvSb) {
	sb := &fvSb{}
	c := &core{log: &fake.Logger{}, plat: &fvPlat{}, vsb: sb, cfg: &api.Config{VPN: api.VPNCfg{LockExit: lock, ExitIPs: []string{"104.0.0.1"}}}}
	c.tun = &tunGuard{c: c, mode: "auto", vpnState: "up", lanState: "off", inst: "testinst"}
	sb.eff.VPN = true
	return c, sb
}

// С галочкой сбой не отпускает сеть: процесс VPN остаётся, состояние blocked, сторож не откатывается лестницей fail-open.
func TestLockFailBlocksInsteadOfFailOpen(t *testing.T) {
	c, sb := newLockCore(true)
	g := c.tun
	for i := 0; i < 4; i++ {
		g.mu.Lock()
		g.failLocked(context.Background(), "проверка туннеля не прошла")
		g.mu.Unlock()
	}
	if g.vpnState != "blocked" || g.mode != "auto" || !g.blocked.Load() || !sb.eff.VPN || g.fails != 0 {
		t.Fatalf("state=%s mode=%s blocked=%v vpn=%v fails=%d", g.vpnState, g.mode, g.blocked.Load(), sb.eff.VPN, g.fails)
	}
	if sb.applied != 1 {
		t.Fatalf("конфиг перерисовывается один раз при входе в перекрытие, applied=%d", sb.applied)
	}
	if st := g.statusLocked(); st["blocked"] != true || st["lock"] != true {
		t.Fatalf("status: %v", st)
	}
}

// Без галочки прежняя лестница: 2-я неудача — failopen и остановка VPN.
func TestNoLockFailOpenUnchanged(t *testing.T) {
	c, _ := newLockCore(false)
	g := c.tun
	g.mu.Lock()
	g.failLocked(context.Background(), "x")
	g.failLocked(context.Background(), "x")
	g.mu.Unlock()
	if g.vpnState != "failopen" || g.blocked.Load() {
		t.Fatalf("state=%s blocked=%v", g.vpnState, g.blocked.Load())
	}
}

// ГЛАВНОЕ: в перекрытом состоянии выключение работает — процесс остановлен, блок снят, режим off.
func TestOffWorksWhileBlocked(t *testing.T) {
	c, sb := newLockCore(true)
	g := c.tun
	g.mu.Lock()
	g.failLocked(context.Background(), "x")
	g.mu.Unlock()
	if !g.blocked.Load() {
		t.Fatal("не перекрыто")
	}
	g.setMode(context.Background(), "off")
	if sb.eff.VPN || g.blocked.Load() || g.vpnState != "off" || g.mode != "off" {
		t.Fatalf("vpn=%v blocked=%v state=%s mode=%s", sb.eff.VPN, g.blocked.Load(), g.vpnState, g.mode)
	}
	if st := g.statusLocked(); st["blocked"] != false {
		t.Fatalf("status: %v", st)
	}
}

// Выключение работает и когда перекрытие осталось от процесса, который не запускается (Apply падает при включении, но не при выключении).
func TestOffWhenVPNProcessDoesNotStart(t *testing.T) {
	c, sb := newLockCore(true)
	g := c.tun
	sb.eff.VPN = false
	g.blocked.Store(true)
	g.vpnState = "blocked"
	g.setMode(context.Background(), "off")
	if g.blocked.Load() || g.vpnState != "off" {
		t.Fatalf("blocked=%v state=%s", g.blocked.Load(), g.vpnState)
	}
}

// Итог проверки выхода: чужой адрес → перекрыть; наш → снять перекрытие; выключенный VPN не трогаем.
func TestExitVerdictBlocksAndUnblocks(t *testing.T) {
	c, sb := newLockCore(true)
	g := c.tun
	ctx := context.Background()
	g.mu.Lock()
	g.exitVerdictLocked(ctx, exitResult{IP: "5.5.5.5", Via: "Ethernet", Known: true, Expected: []string{"104.0.0.1"}})
	g.mu.Unlock()
	if g.vpnState != "blocked" || !g.blocked.Load() {
		t.Fatalf("state=%s", g.vpnState)
	}
	if w := g.vpnWhy; w == "" || !contains(w, "104.0.0.1") || !contains(w, "5.5.5.5") {
		t.Fatalf("причина должна называть адрес и текущий выход: %q", w)
	}
	g.mu.Lock()
	g.exitVerdictLocked(ctx, exitResult{IP: "104.0.0.1", OK: true, Known: true, Expected: []string{"104.0.0.1"}})
	g.mu.Unlock()
	if g.vpnState != "up" || g.blocked.Load() || !sb.eff.VPN {
		t.Fatalf("state=%s blocked=%v", g.vpnState, g.blocked.Load())
	}
	// не удалось проверить — не доказано, что выход наш: перекрыть
	g.mu.Lock()
	g.exitVerdictLocked(ctx, exitResult{Err: "timeout", Known: true, Expected: []string{"104.0.0.1"}})
	g.mu.Unlock()
	if !g.blocked.Load() {
		t.Fatal("ошибка проверки должна перекрывать")
	}
	// выключили — вердикт ничего не делает
	g.setMode(ctx, "off")
	g.mu.Lock()
	g.exitVerdictLocked(ctx, exitResult{IP: "5.5.5.5", Known: true, Expected: []string{"104.0.0.1"}})
	g.mu.Unlock()
	if g.blocked.Load() || g.vpnState != "off" {
		t.Fatalf("выключенный VPN не должен перекрываться: %s", g.vpnState)
	}
}

// Падение процесса с галочкой: перекрытие, а не открытая сеть.
func TestTunCrashWithLockBlocks(t *testing.T) {
	c, _ := newLockCore(true)
	g := c.tun
	g.onTunCrash(context.Background(), api.Effective{VPN: true})
	if !g.blocked.Load() {
		t.Fatal("после падения с галочкой должно быть перекрытие")
	}
}

// Старт с галочкой: интернет перекрыт до проверки выхода (не наоборот).
func TestStartWithLockIsBlockedUntilVerified(t *testing.T) {
	c, sb := newLockCore(true)
	g := c.tun
	sb.eff.VPN = false
	g.vpnState = "off"
	g.reconcile(context.Background(), "start")
	if !sb.eff.VPN || !g.blocked.Load() || g.vpnState != "blocked" {
		t.Fatalf("vpn=%v blocked=%v state=%s", sb.eff.VPN, g.blocked.Load(), g.vpnState)
	}
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}

// Под чужим VPN неудача пробы — сразу failopen, даже с галочкой: перекрытие снимается, процесс VPN останавливается.
func TestForeignProbeFailFailsOpenImmediately(t *testing.T) {
	c, sb := newLockCore(true)
	g := c.tun
	g.lastForeign = "happ-tun"
	g.blocked.Store(true)
	g.mu.Lock()
	g.failLocked(context.Background(), "проверка туннеля не прошла")
	g.mu.Unlock()
	if g.vpnState != "failopen" || g.blocked.Load() {
		t.Fatalf("state=%s blocked=%v", g.vpnState, g.blocked.Load())
	}
	_ = sb
}
