package core

import (
	"context"
	"errors"
	"io"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"
	"golang.org/x/net/proxy"
	"remoteagents/internal/api"
	"remoteagents/internal/bus"
)

// Rounds owns the OpenSSH session. Its -D listener is the v2 transport used by
// forward and disk; the bridge stores only events, never polls the child.
type transport struct {
	a      *App
	mu     sync.Mutex
	state  api.ChannelState
	socks  string
	next   int
	subs   map[int]chan api.ChannelState
	unsubs []func()
}

func newTransport(a *App) *transport {
	return &transport{a: a, state: api.ChannelState{State: "waiting", Since: time.Now()}, subs: map[int]chan api.ChannelState{}}
}
func (t *transport) Name() string { return "channel" }
func (t *transport) Start(context.Context) error {
	for _, topic := range []string{"channel.up", "channel.down"} {
		t.unsubs = append(t.unsubs, t.a.bus.Subscribe(topic, t.event))
	}
	return nil
}
func (t *transport) event(e bus.Event) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.state.Since = time.Now()
	t.state.Reason, _ = e.Data["reason"].(string)
	if e.Topic == "channel.up" {
		t.state.State = "up"
		t.state.Session++
		t.state.Path, _ = e.Data["path"].(string)
		t.socks = net.JoinHostPort("127.0.0.1", strconv.Itoa(intValue(e.Data["socks"])))
	} else {
		t.state.State = "down"
		t.socks = ""
	}
	for _, ch := range t.subs {
		select {
		case ch <- t.state:
		default:
			select {
			case <-ch:
			default:
			}
			select {
			case ch <- t.state:
			default:
			}
		}
	}
}
func (t *transport) Stop(context.Context) error {
	for _, f := range t.unsubs {
		f()
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	t.state.State = "down"
	t.socks = ""
	for k, ch := range t.subs {
		close(ch)
		delete(t.subs, k)
	}
	return nil
}
func (t *transport) Status() map[string]any {
	s := t.State()
	return map[string]any{"state": s.State, "path": s.Path, "session": s.Session}
}
func (t *transport) State() api.ChannelState { t.mu.Lock(); defer t.mu.Unlock(); return t.state }
func (t *transport) Subscribe() (<-chan api.ChannelState, func()) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.next++
	id := t.next
	ch := make(chan api.ChannelState, 1)
	ch <- t.state
	t.subs[id] = ch
	return ch, func() {
		t.mu.Lock()
		defer t.mu.Unlock()
		if c, ok := t.subs[id]; ok {
			close(c)
			delete(t.subs, id)
		}
	}
}
func (t *transport) DialContext(ctx context.Context, network, addr string) (net.Conn, error) {
	t.mu.Lock()
	socks := t.socks
	t.mu.Unlock()
	if socks == "" {
		return nil, errors.New("канал не подключён")
	}
	d, err := proxy.SOCKS5("tcp", socks, nil, &net.Dialer{})
	if err != nil {
		return nil, err
	}
	return d.(proxy.ContextDialer).DialContext(ctx, network, addr)
}
func (t *transport) Exec(ctx context.Context, cmd string, stdin io.Reader, stdout, stderr io.Writer) (int, error) {
	server := t.a.cfg.Servers[0]
	signer, err := ssh.ParsePrivateKey(server.Key)
	if err != nil {
		return -1, err
	}
	// The applied config contains an authorized_keys line, optionally prefixed by host.
	keyText := strings.TrimSpace(server.HostKey)
	fields := strings.Fields(keyText)
	if len(fields) > 2 && !strings.HasPrefix(fields[0], "ssh-") && !strings.HasPrefix(fields[0], "ecdsa-") {
		keyText = strings.Join(fields[1:], " ")
	}
	hostKey, _, _, _, err := ssh.ParseAuthorizedKey([]byte(keyText))
	if err != nil {
		return -1, err
	}
	addr := net.JoinHostPort(server.Host, strconv.Itoa(server.Port))
	conn, err := t.DialContext(ctx, "tcp", addr)
	if err != nil {
		return -1, err
	}
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()
	cc, chans, reqs, err := ssh.NewClientConn(conn, addr, &ssh.ClientConfig{User: server.User, Auth: []ssh.AuthMethod{ssh.PublicKeys(signer)}, HostKeyCallback: ssh.FixedHostKey(hostKey)})
	if err != nil {
		return -1, err
	}
	client := ssh.NewClient(cc, chans, reqs)
	defer client.Close()
	session, err := client.NewSession()
	if err != nil {
		return -1, err
	}
	defer session.Close()
	session.Stdin, session.Stdout, session.Stderr = stdin, stdout, stderr
	err = session.Run(cmd)
	var exit *ssh.ExitError
	if errors.As(err, &exit) {
		return exit.ExitStatus(), nil
	}
	if err != nil {
		return -1, err
	}
	return 0, nil
}
func (t *transport) ForcePath(name string) error { return t.a.SwitchPath(name) }

var _ api.Channel = (*transport)(nil)
