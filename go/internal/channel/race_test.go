package channel

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"net"
	"reflect"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	"remoteagents/internal/api"
	"remoteagents/internal/api/fake"
)

type raceSB struct {
	selectorSB
	paddr map[string]string
}

func (s *raceSB) PathAddr(n string) string { s.mu.Lock(); defer s.mu.Unlock(); return s.paddr[n] }

// hangListener принимает TCP и молчит (SSH-баннера нет); closed получает сигнал, когда клиент оборвал соединение.
func hangListener(t *testing.T) (addr string, closed chan struct{}) {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	closed = make(chan struct{}, 8)
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			go func() {
				buf := make([]byte, 1)
				_, _ = c.Read(buf) // вернётся с ошибкой, когда клиент закроет
				c.Close()
				closed <- struct{}{}
			}()
		}
	}()
	return l.Addr().String(), closed
}

func deadAddr(t *testing.T) string {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	a := l.Addr().String()
	l.Close()
	return a
}

func newRaceChan(t *testing.T, sb *raceSB, hk ssh.Signer) *chn {
	t.Helper()
	_, cpriv, _ := ed25519.GenerateKey(rand.Reader)
	cfg := &api.Config{Servers: []api.Server{{Host: "203.0.113.1", Port: 22, User: "u", Key: marshalPEM(t, cpriv),
		HostKey: strings.TrimSpace(string(ssh.MarshalAuthorizedKey(hk.PublicKey())))}}}
	ch, err := New(cfg, sb, fake.NewAgentHost("tok"), &fake.Logger{}, fake.NewTraces("0123456789abcdef0123456789abcdef"), Options{PC: "pc-v3", DialTimeout: 5 * time.Second})
	if err != nil {
		t.Fatal(err)
	}
	return ch.(*chn)
}

func TestRaceOrder(t *testing.T) {
	names := []string{"hy2-x", "ws-clinic", "ssh-direct", "socks10808", "vless-direct", "tuic-x"}
	none := func(string) bool { return false }
	if got := raceOrder(names, nil, none, false, ""); !reflect.DeepEqual(got, names) {
		t.Fatalf("без чужого VPN и замера порядок по рангу: %v", got)
	}
	want := []string{"ws-clinic", "ssh-direct", "vless-direct", "hy2-x", "socks10808", "tuic-x"}
	if got := raceOrder(names, nil, none, true, ""); !reflect.DeepEqual(got, want) {
		t.Fatalf("чужой VPN: прямые первыми: %v", got)
	}
	ms := map[string]int{"tuic-x": 50, "hy2-x": 300}
	if got := raceOrder(names, ms, none, false, ""); got[0] != "tuic-x" || got[1] != "hy2-x" {
		t.Fatalf("замер: быстрый впереди: %v", got)
	}
	bad := func(n string) bool { return n == "hy2-x" }
	if got := raceOrder(names, nil, bad, false, ""); got[len(got)-1] != "hy2-x" {
		t.Fatalf("плохой последним: %v", got)
	}
	if got := raceOrder(names, nil, bad, true, "tuic-x"); got[0] != "tuic-x" {
		t.Fatalf("prefer первым: %v", got)
	}
}

// Зависший и отказавший пути не мешают: побеждает рабочий; зависший оборван (отмена), победа быстрее таймаута рукопожатия.
func TestRaceFirstSuccessWinsAndCancelsOthers(t *testing.T) {
	old := raceStagger
	raceStagger = 30 * time.Millisecond
	defer func() { raceStagger = old }()
	good := newSigner(t)
	hang, hangClosed := hangListener(t)
	sb := &raceSB{paddr: map[string]string{"hang": hang, "refused": deadAddr(t), "ok": sshStub(t, good)}}
	sb.names = []string{"hang", "refused", "ok"}
	c := newRaceChan(t, sb, good)
	t0 := time.Now()
	cl, _, win, err := c.race(context.Background(), sb, sb.names)
	if err != nil {
		t.Fatal(err)
	}
	defer cl.Close()
	if win != "ok" {
		t.Fatalf("победитель %s", win)
	}
	if el := time.Since(t0); el > 2*time.Second {
		t.Fatalf("гонка ждала таймаут зависшего пути: %v", el)
	}
	select {
	case <-hangClosed:
	case <-time.After(2 * time.Second):
		t.Fatal("зависший кандидат не отменён после победы")
	}
}

// Следующий кандидат стартует по сдвигу, не дожидаясь отказа зависшего: при сдвиге 40 мс победа на третьем месте — быстро.
func TestRaceStaggerStartsNextWithoutWaitingForHang(t *testing.T) {
	old := raceStagger
	raceStagger = 40 * time.Millisecond
	defer func() { raceStagger = old }()
	good := newSigner(t)
	h1, _ := hangListener(t)
	h2, _ := hangListener(t)
	sb := &raceSB{paddr: map[string]string{"h1": h1, "h2": h2, "ok": sshStub(t, good)}}
	sb.names = []string{"h1", "h2", "ok"}
	c := newRaceChan(t, sb, good)
	t0 := time.Now()
	cl, _, win, err := c.race(context.Background(), sb, sb.names)
	if err != nil || win != "ok" {
		t.Fatalf("win=%s err=%v", win, err)
	}
	cl.Close()
	if el := time.Since(t0); el > time.Second {
		t.Fatalf("слишком долго: %v", el)
	}
}

// Отказ TCP на входе sing-box (рестарт) повторяется, а не считается отказом пути.
func TestDialPathRetriesRefusedLocalInput(t *testing.T) {
	old := refusedBackoff
	refusedBackoff = 20 * time.Millisecond
	defer func() { refusedBackoff = old }()
	good := newSigner(t)
	l, _ := net.Listen("tcp", "127.0.0.1:0")
	addr := l.Addr().String()
	l.Close()
	sb := &raceSB{paddr: map[string]string{"p": addr}}
	sb.names = []string{"p"}
	c := newRaceChan(t, sb, good)
	go func() { // вход поднимается через 100 мс
		time.Sleep(100 * time.Millisecond)
		l2, err := net.Listen("tcp", addr)
		if err != nil {
			return
		}
		t.Cleanup(func() { l2.Close() })
		cfg := &ssh.ServerConfig{PublicKeyCallback: func(ssh.ConnMetadata, ssh.PublicKey) (*ssh.Permissions, error) { return nil, nil }}
		cfg.AddHostKey(good)
		for {
			cn, err := l2.Accept()
			if err != nil {
				return
			}
			go func() {
				conn, chans, reqs, err := ssh.NewServerConn(cn, cfg)
				if err != nil {
					return
				}
				go ssh.DiscardRequests(reqs)
				go func() {
					for nc := range chans {
						_ = nc.Reject(ssh.Prohibited, "t")
					}
				}()
				_ = conn.Wait()
			}()
		}
	}()
	cl, _, err := c.dialPath(context.Background(), sb, "p")
	if err != nil {
		t.Fatalf("отказ входа не повторён: %v", err)
	}
	cl.Close()
}

// Чужой отпечаток на всех путях — одна фатальная ошибка с «host key mismatch»; на одном — гонку выигрывает другой.
func TestRaceHostKeyMismatch(t *testing.T) {
	good, evil := newSigner(t), newSigner(t)
	sb := &raceSB{paddr: map[string]string{"a": sshStub(t, evil), "b": sshStub(t, evil)}}
	sb.names = []string{"a", "b"}
	c := newRaceChan(t, sb, good)
	_, _, _, err := c.race(context.Background(), sb, sb.names)
	if err == nil || !isHostKeyMismatch(err) {
		t.Fatalf("ожидался host key mismatch: %v", err)
	}
	sb.paddr["b"] = sshStub(t, good)
	cl, _, win, err := c.race(context.Background(), sb, sb.names)
	if err != nil || win != "b" {
		t.Fatalf("win=%s err=%v", win, err)
	}
	cl.Close()
}

// Отмена контекста (смена сети) обрывает гонку сразу, не по таймауту рукопожатия.
func TestRaceCancel(t *testing.T) {
	good := newSigner(t)
	h, _ := hangListener(t)
	sb := &raceSB{paddr: map[string]string{"h": h}}
	sb.names = []string{"h"}
	c := newRaceChan(t, sb, good)
	ctx, cancel := context.WithCancel(context.Background())
	go func() { time.Sleep(100 * time.Millisecond); cancel() }()
	t0 := time.Now()
	_, _, _, err := c.race(ctx, sb, sb.names)
	if err == nil || time.Since(t0) > 2*time.Second {
		t.Fatalf("err=%v за %v", err, time.Since(t0))
	}
}
