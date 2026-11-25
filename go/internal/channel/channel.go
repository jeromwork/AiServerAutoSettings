package channel

import (
	"time"

	"remoteagents/internal/api"
)

type Options struct {
	PC, Version, Rollback  string
	Mode                   api.Mode
	DialTimeout, Keepalive time.Duration
}

func New(cfg *api.Config, sb api.Singbox, agent api.AgentHost, log api.Logger, tr api.Traces, o Options) (api.Channel, error) {
	panic("not implemented")
}
