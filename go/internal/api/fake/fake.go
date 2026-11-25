// Package fake provides stub implementations of api interfaces for dev drivers and bench tests.
package fake

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"time"

	"remoteagents/internal/api"
)

// Logger is a no-op api.Logger.
type Logger struct{}

func (l *Logger) Info(event string, kv ...any)                {}
func (l *Logger) Warn(event string, kv ...any)                {}
func (l *Logger) Error(event string, kv ...any)               {}
func (l *Logger) With(component string) api.Logger            { return l }
func (l *Logger) Secret(value string)                         {}
func (l *Logger) Writer(stream, source string) io.WriteCloser { return discardWC{} }

type discardWC struct{}

func (discardWC) Write(p []byte) (int, error) { return len(p), nil }
func (discardWC) Close() error                { return nil }
func (l *Logger) Drops() int64                { return 0 }

// Traces is a no-op api.Traces.
type Traces struct{ inst string }

func NewTraces(inst string) *Traces                                          { return &Traces{inst: inst} }
func (t *Traces) Intent(tr api.Trace) error                                  { return nil }
func (t *Traces) Applied(kind, id string, data, set map[string]string) error { return nil }
func (t *Traces) Done(kind, id string) error                                 { return nil }
func (t *Traces) Instance() string                                           { return t.inst }

// Actions is a stub api.Actions that prints method names to stderr.
type Actions struct{}

func (a *Actions) Status() map[string]any { return map[string]any{"state": "fake"} }
func (a *Actions) UpdateCheck(ctx context.Context) (*api.Release, error) {
	return nil, errors.New("fake: UpdateCheck")
}
func (a *Actions) UpdateNow(ctx context.Context) error { fmt.Println("fake: UpdateNow"); return nil }
func (a *Actions) InstallDev(ctx context.Context, body io.Reader, sha256, version string) error {
	fmt.Println("fake: InstallDev")
	return nil
}
func (a *Actions) ConfigCheck(data []byte, password string) error {
	return errors.New("fake: ConfigCheck")
}
func (a *Actions) ConfigApply(ctx context.Context, data []byte, password string) error {
	fmt.Println("fake: ConfigApply")
	return nil
}
func (a *Actions) ConfigRevert(ctx context.Context) error {
	fmt.Println("fake: ConfigRevert")
	return nil
}
func (a *Actions) SetControl(on bool) error { return nil }
func (a *Actions) SwitchPath(name string) error {
	fmt.Printf("fake: SwitchPath %s\n", name)
	return nil
}
func (a *Actions) VPN(mode string) error                           { return api.ErrNotSupported }
func (a *Actions) HappierURL() (string, error)                     { return "http://localhost:47831", nil }
func (a *Actions) LogTail(n int) []string                          { return nil }
func (a *Actions) LogZip(w io.Writer) error                        { return errors.New("fake: LogZip") }
func (a *Actions) LogSend(ctx context.Context) error               { fmt.Println("fake: LogSend"); return nil }
func (a *Actions) Leftovers(ctx context.Context) ([]string, error) { return nil, nil }
func (a *Actions) Restart(ctx context.Context) error               { fmt.Println("fake: Restart"); return nil }
func (a *Actions) Rollback(ctx context.Context, reason string) error {
	fmt.Printf("fake: Rollback %s\n", reason)
	return nil
}
func (a *Actions) Exit(ctx context.Context) error { fmt.Println("fake: Exit"); return nil }

// Channel is a stub api.Channel.
type Channel struct{}

func (c *Channel) Name() string { return "fake-channel" }
func (c *Channel) Start(ctx context.Context) error {
	return errors.New("fake: channel: not-implemented")
}
func (c *Channel) Stop(ctx context.Context) error { return nil }
func (c *Channel) Status() map[string]any         { return map[string]any{"state": "waiting"} }
func (c *Channel) State() api.ChannelState {
	return api.ChannelState{State: "waiting", Since: time.Now()}
}
func (c *Channel) Subscribe() (<-chan api.ChannelState, func()) {
	ch := make(chan api.ChannelState)
	var once sync.Once
	return ch, func() { once.Do(func() { close(ch) }) }
}
func (c *Channel) DialContext(ctx context.Context, network, addr string) (net.Conn, error) {
	return nil, errors.New("fake: channel: not-implemented")
}
func (c *Channel) Exec(ctx context.Context, cmd string, stdin io.Reader, stdout, stderr io.Writer) (int, error) {
	return 1, errors.New("fake: channel: not-implemented")
}
func (c *Channel) ForcePath(name string) error { return errors.New("fake: channel: not-implemented") }

// Forwarder is a stub api.Forwarder.
type Forwarder struct{}

func (f *Forwarder) Name() string { return "fake-forward" }
func (f *Forwarder) Start(ctx context.Context) error {
	return errors.New("fake: forward: not-implemented")
}
func (f *Forwarder) Stop(ctx context.Context) error { return nil }
func (f *Forwarder) Status() map[string]any         { return nil }
func (f *Forwarder) Expose(name string, serverPort, pcPort int) (api.Exposed, error) {
	return api.Exposed{}, errors.New("fake: forward: not-implemented")
}
func (f *Forwarder) Unexpose(name string) error { return errors.New("fake: forward: not-implemented") }
func (f *Forwarder) List() []api.Exposed        { return nil }
func (f *Forwarder) InternalSocks() string      { return "" }

// Singbox is a stub api.Singbox.
type Singbox struct{}

func (s *Singbox) Name() string { return "fake-singbox" }
func (s *Singbox) Start(ctx context.Context) error {
	return errors.New("fake: singbox: not-implemented")
}
func (s *Singbox) Stop(ctx context.Context) error { return nil }
func (s *Singbox) Status() map[string]any         { return nil }
func (s *Singbox) Ready() <-chan struct{} {
	ch := make(chan struct{})
	close(ch)
	return ch
}
func (s *Singbox) ChanAddr() string         { return "" }
func (s *Singbox) PathNames() []string      { return nil }
func (s *Singbox) Effective() api.Effective { return api.Effective{} }
func (s *Singbox) Apply(ctx context.Context, e api.Effective) error {
	return errors.New("fake: singbox: not-implemented")
}
func (s *Singbox) Clash(ctx context.Context, method, path string, body, out any) error {
	return errors.New("fake: singbox: not-implemented")
}

// AgentHost is a stub api.AgentHost.
type AgentHost struct{ token string }

func NewAgentHost(token string) *AgentHost { return &AgentHost{token: token} }
func (a *AgentHost) Serve(l net.Listener)  {}
func (a *AgentHost) Token() string         { return a.token }
