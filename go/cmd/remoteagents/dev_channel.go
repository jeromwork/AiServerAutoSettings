package main

import (
	"bufio"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/pem"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"

	"remoteagents/internal/api"
	"remoteagents/internal/api/fake"
	"remoteagents/internal/channel"
	"remoteagents/internal/config"
	"remoteagents/internal/journal"
)

func init() {
	for _, name := range []string{"channel", "p13"} {
		api.RegisterDev(api.DevCmd{
			Name: name,
			Help: "channel: --config F --password-file F [--pc N] [--no-singbox] | --selftest (in-process fake ssh server)",
			Run:  devChannelRun,
		})
	}
}

// devAgent is a minimal stand-in for the P11 agent: /status -> 200 behind the reverse port.
type devHTTPAgent struct {
	fake.AgentHost
	mu sync.Mutex
	ls []net.Listener
}

func (a *devHTTPAgent) Serve(l net.Listener) {
	a.mu.Lock()
	a.ls = append(a.ls, l)
	a.mu.Unlock()
	mux := http.NewServeMux()
	mux.HandleFunc("/status", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+a.Token() {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		_, _ = io.WriteString(w, `{"ok":true}`)
	})
	go func() { _ = http.Serve(l, mux) }()
}

func devChannelRun(ctx context.Context, args []string) int {
	fs := flag.NewFlagSet("channel", flag.ContinueOnError)
	cfgPath := fs.String("config", "", "configuration file")
	pwFile := fs.String("password-file", "", "configuration password file")
	pc := fs.String("pc", "bench-dev", "computer name")
	noSB := fs.Bool("no-singbox", false, "direct ssh")
	self := fs.Bool("selftest", false, "run against an in-process fake ssh server")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	home, err := os.MkdirTemp("", "ra3-p13-")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	defer os.RemoveAll(home)
	log := journal.Boot(home)
	var cfg *api.Config
	var srv *devSSHServer
	if *self {
		if srv, err = newDevSSHServer(); err != nil {
			fmt.Fprintln(os.Stderr, "selftest:", err)
			return 1
		}
		defer srv.close()
		cfg = srv.config()
		*noSB = true
	} else {
		if cfg, err = config.LoadFile(*cfgPath, *pwFile, log); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
	}
	agent := &devHTTPAgent{AgentHost: *fake.NewAgentHost("tok-" + hex.EncodeToString(randBytes(8)))}
	ch, err := channel.New(cfg, &fake.Singbox{}, agent, log, nil, channel.Options{PC: *pc, Version: "dev", Mode: api.Mode{NoSingbox: *noSB}})
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	ctx, cancel := signal.NotifyContext(ctx, os.Interrupt)
	defer cancel()
	states, unsub := ch.Subscribe()
	defer unsub()
	if err = ch.Start(ctx); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	defer func() {
		stop, done := context.WithTimeout(context.Background(), 10*time.Second)
		defer done()
		_ = ch.Stop(stop)
	}()
	var limit <-chan time.Time
	if *self {
		limit = time.After(30 * time.Second)
	}
	ups, dropped := 0, false
	for {
		select {
		case st := <-states:
			fmt.Printf("state=%s path=%s session=%d reason=%q\n", st.State, st.Path, st.Session, st.Reason)
			if st.State != "up" {
				continue
			}
			ups++
			fmt.Println("RALAB-CHANNEL-UP")
			if !*self {
				continue
			}
			if ups == 1 && !dropped {
				dropped = true
				fmt.Println("selftest: dropping server connection")
				srv.dropAll()
				continue
			}
			var out strings.Builder
			code, err := ch.Exec(ctx, "echo hi", nil, &out, io.Discard)
			fmt.Printf("selftest: reconnect ok session=%d exec code=%d err=%v out=%q claims=%d\n", st.Session, code, err, strings.TrimSpace(out.String()), srv.claimCount())
			return 0
		case <-limit:
			fmt.Fprintln(os.Stderr, "selftest: timeout")
			return 1
		case <-ctx.Done():
			return 0
		}
	}
}

func randBytes(n int) []byte { b := make([]byte, n); _, _ = rand.Read(b); return b }

// devSSHServer: minimal sshd: public-key auth, tcpip-forward, exec "ra-lab session" protocol, exec echo.
type devSSHServer struct {
	l       net.Listener
	conf    *ssh.ServerConfig
	hostPub ssh.PublicKey
	keyPEM  []byte
	mu      sync.Mutex
	conns   []*ssh.ServerConn
	claims  int
}

func newDevSSHServer() (*devSSHServer, error) {
	hpub, hpriv, _ := ed25519.GenerateKey(rand.Reader)
	upub, upriv, _ := ed25519.GenerateKey(rand.Reader)
	hs, err := ssh.NewSignerFromKey(hpriv)
	if err != nil {
		return nil, err
	}
	us, err := ssh.NewPublicKey(upub)
	if err != nil {
		return nil, err
	}
	_ = hpub
	blk, err := ssh.MarshalPrivateKey(upriv, "")
	if err != nil {
		return nil, err
	}
	s := &devSSHServer{hostPub: hs.PublicKey(), keyPEM: pem.EncodeToMemory(blk)}
	s.conf = &ssh.ServerConfig{PublicKeyCallback: func(_ ssh.ConnMetadata, k ssh.PublicKey) (*ssh.Permissions, error) {
		if string(k.Marshal()) == string(us.Marshal()) {
			return nil, nil
		}
		return nil, fmt.Errorf("denied")
	}}
	s.conf.AddHostKey(hs)
	if s.l, err = net.Listen("tcp", "127.0.0.1:0"); err != nil {
		return nil, err
	}
	go s.accept()
	return s, nil
}

func (s *devSSHServer) config() *api.Config {
	a := s.l.Addr().(*net.TCPAddr)
	return &api.Config{Servers: []api.Server{{Host: "127.0.0.1", Port: a.Port, User: "ra3test",
		HostKey: strings.TrimSpace(string(ssh.MarshalAuthorizedKey(s.hostPub))), Key: s.keyPEM}}}
}
func (s *devSSHServer) close() { _ = s.l.Close(); s.dropAll() }
func (s *devSSHServer) dropAll() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, c := range s.conns {
		_ = c.Close()
	}
	s.conns = nil
}
func (s *devSSHServer) claimCount() int { s.mu.Lock(); defer s.mu.Unlock(); return s.claims }

func (s *devSSHServer) accept() {
	for {
		raw, err := s.l.Accept()
		if err != nil {
			return
		}
		go func() {
			sc, chans, reqs, err := ssh.NewServerConn(raw, s.conf)
			if err != nil {
				return
			}
			s.mu.Lock()
			s.conns = append(s.conns, sc)
			s.mu.Unlock()
			go s.requests(sc, reqs)
			for nc := range chans {
				ch, creqs, err := nc.Accept()
				if err != nil {
					continue
				}
				go s.session(ch, creqs)
			}
		}()
	}
}

// requests: tcpip-forward (reverse port) and keepalive.
func (s *devSSHServer) requests(sc *ssh.ServerConn, reqs <-chan *ssh.Request) {
	for r := range reqs {
		if r.Type != "tcpip-forward" {
			_ = r.Reply(false, nil)
			continue
		}
		var p struct {
			Host string
			Port uint32
		}
		_ = ssh.Unmarshal(r.Payload, &p)
		l, err := net.Listen("tcp", net.JoinHostPort(p.Host, strconv.Itoa(int(p.Port))))
		if err != nil {
			_ = r.Reply(false, nil)
			continue
		}
		_ = r.Reply(true, nil)
		go func() {
			<-waitClosed(sc)
			_ = l.Close()
		}()
		go func() {
			for {
				c, err := l.Accept()
				if err != nil {
					return
				}
				go func() {
					pl := ssh.Marshal(struct {
						Host string
						Port uint32
						OH   string
						OP   uint32
					}{p.Host, p.Port, "127.0.0.1", 1})
					fc, freqs, err := sc.OpenChannel("forwarded-tcpip", pl)
					if err != nil {
						_ = c.Close()
						return
					}
					go ssh.DiscardRequests(freqs)
					go func() { _, _ = io.Copy(fc, c); _ = fc.CloseWrite() }()
					_, _ = io.Copy(c, fc)
					_ = c.Close()
				}()
			}
		}()
	}
}

func waitClosed(sc *ssh.ServerConn) <-chan struct{} {
	c := make(chan struct{})
	go func() { _ = sc.Wait(); close(c) }()
	return c
}

func (s *devSSHServer) session(ch ssh.Channel, reqs <-chan *ssh.Request) {
	defer ch.Close()
	for r := range reqs {
		if r.Type != "exec" {
			_ = r.Reply(false, nil)
			continue
		}
		var p struct{ Cmd string }
		_ = ssh.Unmarshal(r.Payload, &p)
		_ = r.Reply(true, nil)
		switch {
		case strings.HasPrefix(p.Cmd, "pkill"):
			_, _ = ch.SendRequest("exit-status", false, ssh.Marshal(struct{ C uint32 }{0}))
		case p.Cmd == "echo hi":
			_, _ = io.WriteString(ch, "hi\n")
			_, _ = ch.SendRequest("exit-status", false, ssh.Marshal(struct{ C uint32 }{0}))
		default:
			s.raLab(ch, p.Cmd)
		}
		return
	}
}

// raLab: the server side of "ra-lab session" (lab/server/ra_lab.py cmd_session).
func (s *devSSHServer) raLab(ch ssh.Channel, cmd string) {
	f := strings.Fields(cmd)
	var n string
	var port int
	for i, w := range f {
		if w == "--nonce" {
			n = f[i+1]
		}
		if w == "--port" {
			port, _ = strconv.Atoi(f[i+1])
		}
	}
	data := randBytes(65536)
	sum := sha256.Sum256(data)
	_, _ = fmt.Fprintf(ch, "RALAB-PROBE1 %s 65536\n", n)
	_, _ = ch.Write(data)
	_, _ = fmt.Fprintf(ch, "\nSHA256 %s\n", hex.EncodeToString(sum[:]))
	r := bufio.NewReader(ch)
	got := make([]byte, 65536)
	if _, err := io.ReadFull(r, got); err != nil {
		return
	}
	gs := sha256.Sum256(got)
	_, _ = fmt.Fprintf(ch, "RALAB-UP1 %s %s\n", n, hex.EncodeToString(gs[:]))
	if l, _ := r.ReadString('\n'); strings.TrimSpace(l) != "CLAIM" {
		return
	}
	tok, _ := r.ReadString('\n')
	tok = strings.TrimSpace(tok)
	req, _ := http.NewRequest("GET", fmt.Sprintf("http://127.0.0.1:%d/status", port), nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	resp, err := http.DefaultClient.Do(req)
	if err != nil || resp.StatusCode != 200 {
		_, _ = io.WriteString(ch, "RALAB-AGENT-FAIL 0\n")
		return
	}
	_ = resp.Body.Close()
	s.mu.Lock()
	s.claims++
	s.mu.Unlock()
	_, _ = io.WriteString(ch, "RALAB-CHANNEL-UP go-dev\n")
	_, _ = io.Copy(io.Discard, r)
}
