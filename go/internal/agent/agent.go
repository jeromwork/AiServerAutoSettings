package agent

import "remoteagents/internal/api"

type Agent struct{}

func (a *Agent) Serve(l interface{}) {}
func (a *Agent) Token() string       { return "" }
func (a *Agent) Close() error        { return nil }

func New(d api.AgentDeps) (*Agent, error) { panic("not implemented") }
