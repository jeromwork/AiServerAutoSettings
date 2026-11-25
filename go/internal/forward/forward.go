package forward

import (
	"errors"

	"remoteagents/internal/api"
)

func New(cfg *api.Config, ch api.Channel, p api.Paths, log api.Logger, tr api.Traces, mode api.Mode) (api.Forwarder, error) {
	return nil, errors.New("forward: not-implemented")
}
