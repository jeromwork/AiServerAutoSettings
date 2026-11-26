package channel

import (
	"context"
	"crypto/ed25519"
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
func sshStub(t *testing.T, hostKey ssh.Signer) string {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	cfg := &ssh.ServerConfig{PublicKeyCallback: func(ssh.ConnMetadata, ssh.PublicKey) (*ssh.Permissions, error) { return nil, nil }}
	cfg.AddHostKey(hostKey)
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
			if st.State == "down" && st.Path == "hijacked" && st.Reason == reasonIntercepted {
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
