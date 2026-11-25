package update

import (
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

func New(p api.Paths, log api.Logger, o Options) (api.Updater, error) { panic("not implemented") }
