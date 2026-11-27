//go:build darwin

package platform

import (
	"context"
	"os/exec"
	"time"
)

func readRoutes() ([]Route, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "netstat", "-rn", "-f", "inet").Output()
	if err != nil {
		return nil, err
	}
	return parseDarwinNetstat(string(out)), nil
}
