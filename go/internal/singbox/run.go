package singbox

import (
	"errors"

	"remoteagents/internal/api"
)

type Options struct {
	Mode      api.Mode
	Instance  string
	LockJSON  string
	LANSocks  func() string
	RawConfig string
}

func New(cfg *api.Config, p api.Paths, log api.Logger, tr api.Traces, pr api.Procs, o Options) (api.Singbox, error) {
	return nil, errors.New("singbox: not-implemented")
}
