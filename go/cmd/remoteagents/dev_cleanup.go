package main

import (
	"context"
	"fmt"
	"net"
	"os"
	"path/filepath"

	"remoteagents/internal/api"
	"remoteagents/internal/api/fake"
	"remoteagents/internal/cleanup"
	"remoteagents/internal/platform"
)

func init() {
	cmd := api.DevCmd{
		Name: "cleanup",
		Help: "cleanup driver: demo <home> | run <home> [reason] | check <home>",
		Run:  runDevCleanup,
	}
	api.RegisterDev(cmd)
	api.RegisterDev(api.DevCmd{
		Name: "p10",
		Help: "cleanup driver (alias for cleanup)",
		Run:  runDevCleanup,
	})
}

func runDevCleanup(ctx context.Context, args []string) int {
	if len(args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: remoteagents dev cleanup <demo|run|check> <home> [reason]")
		return 1
	}
	subcmd := args[0]
	home := args[1]
	absHome, err := filepath.Abs(home)
	if err != nil {
		fmt.Fprintf(os.Stderr, "invalid home: %v\n", err)
		return 1
	}
	p := api.NewPaths(absHome)
	plat := platform.Current()
	logger := &fake.Logger{}

	switch subcmd {
	case "demo":
		if err := os.MkdirAll(p.Tmp, 0700); err != nil {
			fmt.Fprintf(os.Stderr, "mkdir tmp: %v\n", err)
			return 1
		}
		if err := os.MkdirAll(p.State, 0700); err != nil {
			fmt.Fprintf(os.Stderr, "mkdir state: %v\n", err)
			return 1
		}
		c, err := cleanup.New(p, logger, plat)
		if err != nil {
			fmt.Fprintf(os.Stderr, "cleanup.New: %v\n", err)
			return 1
		}

		var lc net.ListenConfig
		l, err := lc.Listen(ctx, "tcp", "127.0.0.1:0")
		if err != nil {
			fmt.Fprintf(os.Stderr, "listen: %v\n", err)
			return 1
		}
		addr := l.Addr().String()

		if err := c.Intent(api.Trace{
			Kind:  "listener",
			ID:    "demo-listener",
			Owner: "dev",
			Data:  map[string]string{"addr": addr},
		}); err != nil {
			_ = l.Close()
			fmt.Fprintf(os.Stderr, "intent listener: %v\n", err)
			return 1
		}
		if err := c.Applied("listener", "demo-listener", map[string]string{"addr": addr}, nil); err != nil {
			_ = l.Close()
			fmt.Fprintf(os.Stderr, "applied listener: %v\n", err)
			return 1
		}

		tmpFile := filepath.Join(p.Tmp, "demo.txt")
		if err := c.Intent(api.Trace{
			Kind:  "tmp",
			ID:    "demo-tmp",
			Owner: "dev",
			Data:  map[string]string{"path": tmpFile},
		}); err != nil {
			_ = l.Close()
			fmt.Fprintf(os.Stderr, "intent tmp: %v\n", err)
			return 1
		}
		if err := os.WriteFile(tmpFile, []byte("demo-data"), 0600); err != nil {
			_ = l.Close()
			fmt.Fprintf(os.Stderr, "write tmp: %v\n", err)
			return 1
		}
		if err := c.Applied("tmp", "demo-tmp", map[string]string{"path": tmpFile}, nil); err != nil {
			_ = l.Close()
			fmt.Fprintf(os.Stderr, "applied tmp: %v\n", err)
			return 1
		}

		fmt.Printf("demo: listening on %s, tmp at %s, killing self with SIGKILL\n", addr, tmpFile)
		self, err := os.FindProcess(os.Getpid())
		if err != nil {
			return 1
		}
		_ = self.Kill()
		return 0

	case "run":
		reason := "crash"
		if len(args) > 2 {
			reason = args[2]
		}
		c, err := cleanup.New(p, logger, plat)
		if err != nil {
			fmt.Fprintf(os.Stderr, "cleanup.New: %v\n", err)
			return 1
		}
		issues := c.Run(ctx, reason)
		if len(issues) > 0 {
			fmt.Fprintf(os.Stderr, "cleanup run issues: %v\n", issues)
			return 1
		}
		checkIssues := c.Check(ctx)
		if len(checkIssues) > 0 {
			fmt.Fprintf(os.Stderr, "cleanup check after run issues: %v\n", checkIssues)
			return 1
		}
		fmt.Println("cleanup run ok, check empty")
		return 0

	case "check":
		c, err := cleanup.New(p, logger, plat)
		if err != nil {
			fmt.Fprintf(os.Stderr, "cleanup.New: %v\n", err)
			return 1
		}
		issues := c.Check(ctx)
		if len(issues) > 0 {
			fmt.Fprintf(os.Stderr, "cleanup check issues: %v\n", issues)
			return 1
		}
		fmt.Println("cleanup check empty")
		return 0

	default:
		fmt.Fprintf(os.Stderr, "unknown dev cleanup subcommand: %s\n", subcmd)
		return 1
	}
}
