package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"strconv"

	"remoteagents/internal/api"
	"remoteagents/internal/forward"
	"remoteagents/internal/journal"
)

func init() {
	api.RegisterDev(api.DevCmd{Name: "forward", Help: "forward expose <serverPort> [pcPort] — проброс 127.0.0.1 -> 127.0.0.1:serverPort (канал заменён прямым соединением), до Ctrl+C", Run: runDevForward})
}

// directChannel — канал-заглушка для ручной проверки: всегда «up», соединения напрямую.
type directChannel struct{}

func (directChannel) Name() string                { return "direct" }
func (directChannel) Start(context.Context) error { return nil }
func (directChannel) Stop(context.Context) error  { return nil }
func (directChannel) Status() map[string]any      { return nil }
func (directChannel) State() api.ChannelState     { return api.ChannelState{State: "up", Session: 1} }
func (directChannel) ForcePath(string) error      { return nil }
func (directChannel) Subscribe() (<-chan api.ChannelState, func()) {
	return make(chan api.ChannelState), func() {}
}
func (directChannel) Exec(context.Context, string, io.Reader, io.Writer, io.Writer) (int, error) {
	return 1, errors.New("dev: no exec")
}
func (directChannel) DialContext(ctx context.Context, n, a string) (net.Conn, error) {
	var d net.Dialer
	return d.DialContext(ctx, n, a)
}

func runDevForward(ctx context.Context, args []string) int {
	if len(args) < 2 || args[0] != "expose" {
		fmt.Fprintln(os.Stderr, "usage: remoteagents dev forward expose <serverPort> [pcPort]")
		return 1
	}
	home, err := os.MkdirTemp("", "ra-forward-")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	defer os.RemoveAll(home)
	sp, _ := strconv.Atoi(args[1])
	pc := 0
	if len(args) > 2 {
		pc, _ = strconv.Atoi(args[2])
	}
	f, err := forward.New(&api.Config{}, directChannel{}, api.NewPaths(home), journal.Boot(home), nil, api.Mode{Safe: true})
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	f.Start(ctx)
	defer f.Stop(ctx)
	e, err := f.Expose("dev", sp, pc)
	if err != nil {
		fmt.Fprintln(os.Stderr, "expose:", err)
		return 1
	}
	fmt.Printf("http://localhost:%d -> 127.0.0.1:%d\n", e.PCPort, e.ServerPort)
	<-ctx.Done()
	return 0
}
