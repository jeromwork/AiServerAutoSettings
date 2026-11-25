package core

import (
	"context"
	"fmt"
	"os"
	"time"

	"remoteagents/internal/api"
)

type Flags struct {
	Home, Config, PasswordFile, PC, DevAssets, Pprof, RollbackReason, ReleaseBase string
	Mode                                                                          api.Mode
	ExitAfter                                                                     time.Duration
}

func Run(ctx context.Context, f Flags) int {
	fmt.Fprintln(os.Stderr, "core: not-implemented")
	return 1
}
