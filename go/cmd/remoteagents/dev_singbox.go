package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"time"

	"remoteagents/internal/api"
	"remoteagents/internal/cleanup"
	"remoteagents/internal/config"
	"remoteagents/internal/journal"
	"remoteagents/internal/platform"
	"remoteagents/internal/procs"
	"remoteagents/internal/singbox"
)

func init() {
	api.RegisterDev(api.DevCmd{Name: "singbox", Help: "up <home> <config> <password> --no-tun", Run: devSingbox})
}
func devSingbox(ctx context.Context, args []string) int {
	err := runDevSingbox(ctx, args)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	return 0
}
func runDevSingbox(ctx context.Context, args []string) error {
	if len(args) != 5 || args[0] != "up" || args[4] != "--no-tun" {
		return fmt.Errorf("singbox: usage: dev singbox up <home> <config> <password> --no-tun")
	}
	p := api.NewPaths(args[1])
	log := journal.Boot(p.Home)
	// The positional password is registered before opening the configuration.
	log.Secret(args[3])
	data, err := os.ReadFile(args[2])
	if err != nil {
		return fmt.Errorf("singbox: dev-config: %w", err)
	}
	cfg, _, err := config.Open(data, args[3])
	if err != nil {
		return err
	}
	tr, err := cleanup.New(p, log, platform.Current())
	if err != nil {
		return err
	}
	pr, err := procs.New(log, tr)
	if err != nil {
		return err
	}
	sb, err := singbox.New(cfg, p, log, tr, pr, singbox.Options{Mode: api.Mode{NoTun: true}, LockJSON: filepath.Join("third_party", "singbox.lock.json")})
	if err != nil {
		return err
	}
	ctx, cancel := signal.NotifyContext(ctx, os.Interrupt)
	defer cancel()
	defer func() {
		stop, done := context.WithTimeout(context.Background(), 10*time.Second)
		defer done()
		if err := sb.Stop(stop); err != nil {
			fmt.Fprintln(os.Stderr, err)
		}
	}()
	if err = sb.Start(ctx); err != nil {
		return err
	}
	fmt.Printf("ready chan=%s\n", sb.ChanAddr())
	var version map[string]any
	if err = sb.Clash(ctx, "GET", "/version", nil, &version); err != nil {
		return err
	}
	fmt.Println("GET /version ok")
	<-ctx.Done()
	return nil
}
