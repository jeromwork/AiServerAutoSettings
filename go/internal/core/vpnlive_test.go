package core

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"os"
	"testing"
	"time"

	"remoteagents/internal/api"
	"remoteagents/internal/api/fake"
	"remoteagents/internal/config"
	"remoteagents/internal/secret"
)

const livePW = "pw-test"

func liveConfig(t *testing.T, vpn map[string]any) []byte {
	t.Helper()
	salt := []byte("0123456789abcdef")
	key, err := secret.Derive(livePW, salt, 10)
	if err != nil {
		t.Fatal(err)
	}
	seal := func(s string) string {
		v, err := secret.Seal(key, []byte(s))
		if err != nil {
			t.Fatal(err)
		}
		return v
	}
	root := map[string]any{
		"format": "remoteagents-2", "name": "pc-test",
		"server": map[string]any{"host": "h.example", "user": "u", "hostKey": "ssh-ed25519 AAAA", "key": seal("PRIVATE KEY\n")},
		"paths":  map[string]any{"channel": seal("{}")},
		"kdf":    map[string]any{"iterations": 10, "salt": base64.StdEncoding.EncodeToString(salt)},
		"check":  seal("remoteagents"),
		"vpn":    vpn,
	}
	b, _ := json.Marshal(root)
	return b
}

// liveCore — ядро с настоящим хранилищем конфига (принятое поколение) и сторожем; перезапуск запрещён (канал quit без читателя поймает).
func liveCore(t *testing.T, vpn map[string]any) (*core, *fvSb) {
	t.Helper()
	p := api.NewPaths(t.TempDir())
	_ = os.MkdirAll(p.State, 0o700)
	gen, err := config.Apply(p, liveConfig(t, vpn), livePW, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := config.Commit(p, gen, timeNowPlus()); err != nil {
		t.Fatal(err)
	}
	cfg, gen, err := config.Load(p, nil)
	if err != nil {
		t.Fatal(err)
	}
	sb := &fvSb{}
	c := &core{p: p, log: &fake.Logger{}, plat: &fvPlat{}, vsb: sb, cfg: cfg, gen: gen, quit: make(chan quitReq, 1)}
	c.tun = &tunGuard{c: c, mode: cfg.VPN.Mode, vpnState: "off", lanState: "off", inst: "testinst"}
	return c, sb
}

func savedVPN(t *testing.T, c *core) *api.Config {
	t.Helper()
	cfg, _, err := config.Load(c.p, nil)
	if err != nil {
		t.Fatal(err)
	}
	return cfg
}

func noRestart(t *testing.T, c *core) {
	t.Helper()
	select {
	case q := <-c.quit:
		t.Fatalf("перезапуск программы запрошен: %v", q)
	default:
	}
}

func TestSetVPNModeLive(t *testing.T) {
	c, _ := liveCore(t, map[string]any{"mode": "off"})
	if err := c.ConfigSetVPN(context.Background(), "auto"); err != nil {
		t.Fatal(err)
	}
	noRestart(t, c)
	if c.tun.mode != "auto" || c.cfg.VPN.Mode != "auto" || savedVPN(t, c).VPN.Mode != "auto" {
		t.Fatalf("guard=%s mem=%s saved=%s", c.tun.mode, c.cfg.VPN.Mode, savedVPN(t, c).VPN.Mode)
	}
	if ptr, _ := config.ReadPointers(c.p); ptr.Switch == nil || ptr.Current != c.gen {
		t.Fatalf("окно должно идти: %+v gen=%s", ptr, c.gen)
	}
	c.confirmLiveTrial()
	if ptr, _ := config.ReadPointers(c.p); ptr.Switch != nil || ptr.LastGood != c.gen {
		t.Fatalf("поколение не принято: %+v", ptr)
	}
}

func TestSetVPNLockLive(t *testing.T) {
	c, _ := liveCore(t, map[string]any{"mode": "auto", "lockExit": false})
	if err := c.ConfigSetVPNLock(context.Background(), true); err != nil {
		t.Fatal(err)
	}
	noRestart(t, c)
	if !c.tun.lock() || !savedVPN(t, c).VPN.LockExit {
		t.Fatalf("lock mem=%v saved=%v", c.tun.lock(), savedVPN(t, c).VPN.LockExit)
	}
	c.tun.blocked.Store(true)
	if err := c.ConfigSetVPNLock(context.Background(), false); err != nil {
		t.Fatal(err)
	}
	noRestart(t, c)
	if c.tun.lock() || c.tun.blocked.Load() || savedVPN(t, c).VPN.LockExit {
		t.Fatalf("lock не снят: mem=%v blocked=%v", c.tun.lock(), c.tun.blocked.Load())
	}
}

// /api/vpn/off → Actions.VPN("off") затем сохранение: persistVPNMode пишет mode=off в конфиг.
func TestVPNOffPersisted(t *testing.T) {
	c, _ := liveCore(t, map[string]any{"mode": "auto"})
	c.tun.setMode(context.Background(), "off")
	if err := c.persistVPNMode("off", true); err != nil {
		t.Fatal(err)
	}
	if savedVPN(t, c).VPN.Mode != "off" || c.cfg.VPN.Mode != "off" {
		t.Fatalf("saved=%s", savedVPN(t, c).VPN.Mode)
	}
}

// 3-я неудача: failLocked выключает режим и сам сохраняет off в конфиг (через хук, асинхронно).
func TestThirdFailPersistsOff(t *testing.T) {
	c, _ := liveCore(t, map[string]any{"mode": "auto"})
	g := c.tun
	for i := 0; i < 3; i++ {
		g.mu.Lock()
		g.failLocked(context.Background(), "x")
		g.mu.Unlock()
	}
	if g.mode != "off" {
		t.Fatalf("mode=%s", g.mode)
	}
	waitFor(t, func() bool { return savedVPN(t, c).VPN.Mode == "off" })
	c.persistWG.Wait() // запись закончена до очистки TempDir
}

func timeNowPlus() time.Time { return time.Now().Add(time.Minute) }

func waitFor(t *testing.T, ok func() bool) {
	t.Helper()
	for i := 0; i < 200; i++ {
		if ok() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("условие не выполнилось")
}

// Включение галочки открывает пробное окно (не коммитится сразу); срок окна — откат на ходу: в памяти lockExit=false, блок снят.
func TestLockOnTrialRollsBackLive(t *testing.T) {
	c, _ := liveCore(t, map[string]any{"mode": "auto", "lockExit": false})
	if err := c.ConfigSetVPNLock(context.Background(), true); err != nil {
		t.Fatal(err)
	}
	if ptr, _ := config.ReadPointers(c.p); ptr.Switch == nil || !c.tun.lock() {
		t.Fatalf("окно должно идти: %+v lock=%v", ptr.Switch, c.tun.lock())
	}
	c.tun.blocked.Store(true)
	c.expireLiveTrial(time.Now().Add(10 * time.Minute))
	noRestart(t, c)
	if c.tun.lock() || c.tun.blocked.Load() || c.cfg.VPN.LockExit || savedVPN(t, c).VPN.LockExit {
		t.Fatalf("откат не применён: mem=%v blocked=%v", c.tun.lock(), c.tun.blocked.Load())
	}
	if ptr, _ := config.ReadPointers(c.p); ptr.Switch != nil {
		t.Fatal("окно не закрыто")
	}
}

// Подтверждение выхода закрывает окно без отката.
func TestLockOnTrialConfirmed(t *testing.T) {
	c, _ := liveCore(t, map[string]any{"mode": "auto", "lockExit": false})
	if err := c.ConfigSetVPNLock(context.Background(), true); err != nil {
		t.Fatal(err)
	}
	c.confirmLiveTrial()
	if ptr, _ := config.ReadPointers(c.p); ptr.Switch != nil || ptr.LastGood != c.gen || !c.tun.lock() {
		t.Fatalf("не подтверждено: %+v", ptr)
	}
}

// Путь tun.crashed: 3-е падение TUN тоже сохраняет off.
func TestTunCrashPersistsOff(t *testing.T) {
	c, _ := liveCore(t, map[string]any{"mode": "auto"})
	for i := 0; i < 3; i++ {
		c.tun.onTunCrash(context.Background(), api.Effective{VPN: true})
	}
	waitFor(t, func() bool { return savedVPN(t, c).VPN.Mode == "off" })
	c.persistWG.Wait() // запись закончена до очистки TempDir
}
