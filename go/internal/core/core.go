package core

import (
	"context"
	"time"

	"remoteagents/internal/api"
)

type Flags struct {
	Home, Config, PasswordFile, PC, DevAssets, Pprof, RollbackReason, ReleaseBase string
	Mode                                                                          api.Mode
	ExitAfter                                                                     time.Duration
}

func Run(ctx context.Context, f Flags) int { panic("not implemented") }

func startVPNGuard() {}
func startLANGuard() {}
