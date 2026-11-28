package channel

import (
	"context"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/json"
	"encoding/pem"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	"remoteagents/internal/api"
	"remoteagents/internal/api/fake"
)

// sshStub принимает любой ключ клиента и сразу закрывает сессии: достаточно, чтобы пройти проверку отпечатка.
func sshStub(t *testing.T, hostKeys ...ssh.Signer) string {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	cfg := &ssh.ServerConfig{PublicKeyCallback: func(ssh.ConnMetadata, ssh.PublicKey) (*ssh.Permissions, error) { return nil, nil }}
	for _, k := range hostKeys {
		cfg.AddHostKey(k)
	}
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				conn, chans, reqs, err := ssh.NewServerConn(c, cfg)
				if err != nil {
					return
				}
				go ssh.DiscardRequests(reqs)
				go func() {
					for nc := range chans {
						_ = nc.Reject(ssh.Prohibited, "test")
					}
				}()
				_ = conn.Wait()
			}()
		}
	}()
	return l.Addr().String()
}

func newECDSASigner(t *testing.T) ssh.Signer {
	k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	s, err := ssh.NewSignerFromKey(k)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func newSigner(t *testing.T) ssh.Signer {
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	s, err := ssh.NewSignerFromKey(priv)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

// selectorSB — sing-box с селектором chan: ChanAddr ведёт на сервер текущего пути.
type selectorSB struct {
	fake.Singbox
	mu    sync.Mutex
	names []string
	addr  map[string]string
	now   string
}

func (s *selectorSB) Ready() <-chan struct{} { c := make(chan struct{}); close(c); return c }
func (s *selectorSB) PathNames() []string    { return s.names }
func (s *selectorSB) ChanAddr() string       { s.mu.Lock(); defer s.mu.Unlock(); return s.addr[s.now] }
func (s *selectorSB) Clash(ctx context.Context, method, path string, body, out any) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if method == "PUT" {
		s.now = body.(map[string]string)["name"]
		return nil
	}
	b, _ := json.Marshal(map[string]string{"now": s.now})
	return json.Unmarshal(b, out)
}

// Причина отката из-за одного пути: первый путь отвечает чужим ключом (перехват) — это не фатально,
// надо идти ко второму, где ключ верный.
func TestHostKeyMismatchOnOnePathTriesNext(t *testing.T) {
	good, evil := newSigner(t), newSigner(t)
	sb := &selectorSB{names: []string{"hijacked", "good"}, now: "hijacked",
		addr: map[string]string{"hijacked": sshStub(t, evil), "good": sshStub(t, good)}}
	_, cpriv, _ := ed25519.GenerateKey(rand.Reader)
	pemKey := marshalPEM(t, cpriv)
	cfg := &api.Config{Servers: []api.Server{{Host: "203.0.113.1", Port: 22, User: "u", Key: pemKey,
		HostKey: strings.TrimSpace(string(ssh.MarshalAuthorizedKey(good.PublicKey())))}}}
	ch, err := New(cfg, sb, fake.NewAgentHost("tok"), &fake.Logger{}, fake.NewTraces("0123456789abcdef0123456789abcdef"), Options{PC: "pc-v3", DialTimeout: 2 * time.Second})
	if err != nil {
		t.Fatal(err)
	}
	updates, unsub := ch.Subscribe()
	defer unsub()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := ch.Start(ctx); err != nil {
		t.Fatal(err)
	}
	defer ch.Stop(context.Background())

	var sawIntercepted, sawGoodTry bool
	deadline := time.After(10 * time.Second)
	for !sawGoodTry {
		select {
		case st := <-updates:
			if strings.Contains(st.Reason, "host key mismatch") {
				t.Fatalf("mismatch на одном пути объявлен фатальным: %+v", st)
			}
			if st.State == "down" && st.Path == "hijacked" && strings.HasPrefix(st.Reason, reasonIntercepted) && strings.Contains(st.Reason, ssh.FingerprintSHA256(evil.PublicKey())) {
				sawIntercepted = true
			}
			if st.State == "connecting" && st.Path == "good" {
				sawGoodTry = true
			}
		case <-deadline:
			t.Fatalf("таймаут: intercepted=%v goodTry=%v", sawIntercepted, sawGoodTry)
		}
	}
	if !sawIntercepted {
		t.Fatal("не было причины «путь перехвачен» у первого пути")
	}
}

// Если чужой отпечаток на ВСЕХ путях — это фатально (подмена или устаревший конфиг).
func TestHostKeyMismatchOnAllPathsIsFatal(t *testing.T) {
	good, evil := newSigner(t), newSigner(t)
	sb := &selectorSB{names: []string{"a", "b"}, now: "a", addr: map[string]string{"a": sshStub(t, evil), "b": sshStub(t, evil)}}
	_, cpriv, _ := ed25519.GenerateKey(rand.Reader)
	cfg := &api.Config{Servers: []api.Server{{Host: "203.0.113.1", Port: 22, User: "u", Key: marshalPEM(t, cpriv),
		HostKey: strings.TrimSpace(string(ssh.MarshalAuthorizedKey(good.PublicKey())))}}}
	ch, err := New(cfg, sb, fake.NewAgentHost("tok"), &fake.Logger{}, fake.NewTraces("0123456789abcdef0123456789abcdef"), Options{PC: "pc-v3", DialTimeout: 2 * time.Second})
	if err != nil {
		t.Fatal(err)
	}
	updates, unsub := ch.Subscribe()
	defer unsub()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	_ = ch.Start(ctx)
	defer ch.Stop(context.Background())
	deadline := time.After(10 * time.Second)
	for {
		select {
		case st := <-updates:
			if strings.Contains(st.Reason, "host key mismatch") {
				return
			}
		case <-deadline:
			t.Fatal("фатальный mismatch на всех путях не объявлен")
		}
	}
}

func marshalPEM(t *testing.T, k ed25519.PrivateKey) []byte {
	blk, err := ssh.MarshalPrivateKey(k, "")
	if err != nil {
		t.Fatal(err)
	}
	return pem.EncodeToMemory(blk)
}

// Причина «все пути — отпечаток не совпал» при верном hostKey: сервер держит ключи нескольких типов, а клиент Go
// первым просил ecdsa и получал не тот ключ, что закреплён в конфиге (ed25519).
func TestPinnedEd25519WorksWhenServerAlsoHasECDSA(t *testing.T) {
	ed := newSigner(t)
	sb := &selectorSB{names: []string{"a"}, now: "a", addr: map[string]string{"a": sshStub(t, newECDSASigner(t), ed)}}
	_, cpriv, _ := ed25519.GenerateKey(rand.Reader)
	cfg := &api.Config{Servers: []api.Server{{Host: "203.0.113.1", Port: 22, User: "u", Key: marshalPEM(t, cpriv),
		HostKey: strings.TrimSpace(string(ssh.MarshalAuthorizedKey(ed.PublicKey())))}}}
	ch, err := New(cfg, sb, fake.NewAgentHost("tok"), &fake.Logger{}, fake.NewTraces("0123456789abcdef0123456789abcdef"), Options{PC: "pc-v3", DialTimeout: 2 * time.Second})
	if err != nil {
		t.Fatal(err)
	}
	updates, unsub := ch.Subscribe()
	defer unsub()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	_ = ch.Start(ctx)
	defer ch.Stop(context.Background())
	deadline := time.After(5 * time.Second)
	for {
		select {
		case st := <-updates:
			if strings.Contains(st.Reason, "отпечаток") || strings.Contains(st.Reason, "host key mismatch") {
				t.Fatalf("верный ключ отвергнут: %+v", st)
			}
			if st.State == "down" { // дошли до сессии (стаб её отклоняет) — отпечаток принят
				return
			}
		case <-deadline:
			t.Fatal("таймаут")
		}
	}
}

func TestRetryDelayBounds(t *testing.T) {
	want := []time.Duration{500 * time.Millisecond, 500 * time.Millisecond, time.Second, 2 * time.Second, 4 * time.Second, 8 * time.Second, 16 * time.Second, 30 * time.Second, 30 * time.Second}
	for i, w := range want {
		if got := retryDelay(i); got != w {
			t.Errorf("fails=%d: %v, want %v", i, got, w)
		}
	}
	if retryDelay(100) != 30*time.Second {
		t.Fatal("нет верхней границы")
	}
}

func newTestChan(t *testing.T, sb api.Singbox, hostKey ssh.Signer) api.Channel {
	t.Helper()
	_, cpriv, _ := ed25519.GenerateKey(rand.Reader)
	cfg := &api.Config{Servers: []api.Server{{Host: "203.0.113.1", Port: 22, User: "u", Key: marshalPEM(t, cpriv),
		HostKey: strings.TrimSpace(string(ssh.MarshalAuthorizedKey(hostKey.PublicKey())))}}}
	ch, err := New(cfg, sb, fake.NewAgentHost("tok"), &fake.Logger{}, fake.NewTraces("0123456789abcdef0123456789abcdef"), Options{PC: "pc-v3", DialTimeout: 2 * time.Second})
	if err != nil {
		t.Fatal(err)
	}
	return ch
}

// Смена сети: попытка обрывается, публикуется причина, круг путей начинается с первого по рангу (а не с того, где остановились).
func TestNetChangedRestartsFromFirstPath(t *testing.T) {
	good := newSigner(t)
	sb := &selectorSB{names: []string{"a", "b"}, now: "a", addr: map[string]string{"a": sshStub(t, good), "b": sshStub(t, good)}}
	ch := newTestChan(t, sb, good)
	updates, unsub := ch.Subscribe()
	defer unsub()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	_ = ch.Start(ctx)
	defer ch.Stop(context.Background())
	sb.mu.Lock()
	sb.now = "b" // как будто последним работал второй путь
	sb.mu.Unlock()
	nc, ok := ch.(interface{ NetChanged() })
	if !ok {
		t.Fatal("канал не реализует NetChanged")
	}
	nc.NetChanged()
	deadline := time.After(5 * time.Second)
	sawReason := false
	for !sawReason {
		select {
		case st := <-updates:
			sawReason = st.Reason == reasonNetChanged
		case <-deadline:
			t.Fatal("причина «сеть сменилась» не опубликована")
		}
	}
	for i := 0; i < 100; i++ {
		sb.mu.Lock()
		now := sb.now
		sb.mu.Unlock()
		if now == "a" {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("после смены сети не выбран первый путь")
}

// Возврат на предпочтительный путь: таймер ставится только на пути не первого ранга и не на закреплённом.
func TestArmReturnOnlyOnNonPreferredPath(t *testing.T) {
	old := returnBase
	returnBase = 20 * time.Millisecond
	defer func() { returnBase = old }()
	sb := &selectorSB{names: []string{"a", "b"}, now: "a", addr: map[string]string{}}
	c := &chn{sb: sb, retPref: make(chan struct{}, 1)}
	c.armReturn("a")
	select {
	case <-c.retPref:
		t.Fatal("возврат запрошен на предпочтительном пути")
	case <-time.After(80 * time.Millisecond):
	}
	c.armReturn("b")
	select {
	case <-c.retPref:
	case <-time.After(2 * time.Second):
		t.Fatal("возврат не запрошен на запасном пути")
	}
	c.pinned = time.Now().Add(time.Minute)
	c.armReturn("b")
	select {
	case <-c.retPref:
		t.Fatal("возврат при закреплённом пути")
	case <-time.After(80 * time.Millisecond):
	}
}

// Задержка возврата растёт при неудачных возвратах (без дёрганья), сбрасывается на предпочтительном пути.
func TestArmReturnBacksOff(t *testing.T) {
	sb := &selectorSB{names: []string{"a", "b"}, now: "a", addr: map[string]string{}}
	c := &chn{sb: sb, retPref: make(chan struct{}, 1)}
	c.armReturn("b")
	c.armReturn("b")
	if c.retFails != 2 {
		t.Fatalf("retFails=%d", c.retFails)
	}
	c.armReturn("a")
	if c.retFails != 0 {
		t.Fatal("счётчик не сброшен")
	}
	c.disarmReturnKeep()
}

// Короткая сессия, оборванная keepalive, помечает путь плохим: берётся следующий; по истечении срока — снова предпочтительный.
func TestKeepaliveLossMarksPathBad(t *testing.T) {
	sb := &selectorSB{names: []string{"hy2", "tcp"}, now: "hy2", addr: map[string]string{}}
	c := &chn{sb: sb, log: &fake.Logger{}}
	c.failoverUnstable("hy2", 5*time.Minute) // одна долгая сессия — не повод
	if sb.now != "hy2" {
		t.Fatalf("переключились без причины: %s", sb.now)
	}
	c.failoverUnstable("hy2", 30*time.Second) // короткая — плохой
	if sb.now != "tcp" {
		t.Fatalf("ожидался tcp, получен %s", sb.now)
	}
	now := time.Now()
	if got := c.firstGood(sb.names, now); got != "tcp" {
		t.Fatalf("firstGood=%s", got)
	}
	if got := c.firstGood(sb.names, now.Add(badPathTTL+time.Second)); got != "hy2" {
		t.Fatalf("после срока ожидался hy2, получен %s", got)
	}
}

// Две долгие, но частые потери подряд за окно — тоже нестабильность.
func TestTwoLossesInWindowMarkBad(t *testing.T) {
	c := &chn{}
	now := time.Now()
	if c.noteKeepaliveLoss("p", 10*time.Minute, now) {
		t.Fatal("первая долгая потеря не должна метить")
	}
	if !c.noteKeepaliveLoss("p", 10*time.Minute, now.Add(time.Minute)) {
		t.Fatal("вторая за окно должна метить")
	}
	c2 := &chn{}
	c2.noteKeepaliveLoss("p", 10*time.Minute, now)
	if c2.noteKeepaliveLoss("p", 10*time.Minute, now.Add(unstableWindow+time.Second)) {
		t.Fatal("потери вне окна не считаются подряд")
	}
}

// Единственный путь или все остальные плохие — переключаться некуда.
func TestNoFailoverWhenNoAlternative(t *testing.T) {
	sb := &selectorSB{names: []string{"hy2"}, now: "hy2", addr: map[string]string{}}
	c := &chn{sb: sb, log: &fake.Logger{}}
	c.failoverUnstable("hy2", time.Second)
	if sb.now != "hy2" {
		t.Fatal("переключение без альтернативы")
	}
}
