package agent

import (
	"errors"
	"net"

	"remoteagents/internal/api"
)

type Agent struct{}

func (a *Agent) Serve(l net.Listener) {}
func (a *Agent) Token() string        { return "" }
func (a *Agent) Close() error         { return errors.New("agent: not-implemented") }

func New(d api.AgentDeps) (*Agent, error) {
	return nil, errors.New("agent: not-implemented")
}
