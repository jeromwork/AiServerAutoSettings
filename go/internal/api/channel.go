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
	State   string    `json:"state"`
	Path    string    `json:"path"`
	Reason  string    `json:"reason"`
	Since   time.Time `json:"since"`
	Session int       `json:"session"`
}

type Channel interface {
	Component
	State() ChannelState
	Subscribe() (<-chan ChannelState, func())
	DialContext(ctx context.Context, network, addr string) (net.Conn, error)
	Exec(ctx context.Context, cmd string, stdin io.Reader, stdout, stderr io.Writer) (int, error)
	ForcePath(name string) error
}
