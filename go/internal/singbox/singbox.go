package singbox

import (
	"time"

	"remoteagents/internal/api"
)

func Render(rc api.RenderContext) ([]byte, error) { panic("not implemented") }

type Options struct {
	Mode      api.Mode
	Instance  string
	LockJSON  string
	LANSocks  func() string
	RawConfig string
}

func New(cfg *api.Config, p api.Paths, log api.Logger, tr api.Traces, pr api.Procs, o Options) (api.Singbox, error) {
	panic("not implemented")
}

// stub for future render parts
func renderVPN(rc api.RenderContext) (api.Part, error) { return api.Part{}, nil }
func renderLAN(rc api.RenderContext) (api.Part, error) { return api.Part{}, nil }

// suppress unused import
var _ time.Duration
