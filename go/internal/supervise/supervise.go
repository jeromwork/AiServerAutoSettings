package supervise

import (
	"context"
	"fmt"
	"os"

	"remoteagents/internal/api"
)

func Run(ctx context.Context, p api.Paths, log api.Logger, pr api.Procs, self string, mode api.Mode, args []string) int {
	fmt.Fprintln(os.Stderr, "supervise: not-implemented")
	return 1
}
