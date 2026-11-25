package api

import (
	"context"
	"io"
	"net"
	"time"
)

type AgentHost interface {
	Serve(l net.Listener)
	Token() string
}

type ChannelState struct {
	State   string    `json:"state"` // waiting | connecting | up | down
	Path    string    `json:"path"`
	Reason  string    `json:"reason"`
	Since   time.Time `json:"since"`
	Session int       `json:"session"`
}

// Channel consumes channel.up/channel.down from the shared bus. The active v2
// SINGLE round waits for uplink.selected, then probes and claims the same SSH
// session through Singbox.ChanAddr; ForcePath selects chan before dropping SSH.
type Channel interface {
	Component
	State() ChannelState
	Subscribe() (<-chan ChannelState, func())
	DialContext(ctx context.Context, network, addr string) (net.Conn, error)
	Exec(ctx context.Context, cmd string, stdin io.Reader, stdout, stderr io.Writer) (int, error)
	ForcePath(name string) error // повтор uplink.force: selector + закрепить 600 с + разорвать ssh для переподключения
}
