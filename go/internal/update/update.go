package update

import (
	"errors"
	"time"

	"remoteagents/internal/api"
)

type Options struct {
	Repo, Channel string
	Signers       []string
	Plat          api.Platform
	Interval      time.Duration
	BaseURL       string
}

func New(p api.Paths, log api.Logger, o Options) (api.Updater, error) {
	return nil, errors.New("update: not-implemented")
}
