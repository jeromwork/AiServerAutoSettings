package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"runtime"
	"strconv"
	"time"

	"remoteagents/internal/api"
	"remoteagents/internal/core"
)

func dispatch(ctx context.Context, args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: remoteagents <command>")
		return 1
	}
	switch args[0] {
	case "version":
		if len(args) > 1 && args[1] == "--json" {
			b, _ := json.Marshal(map[string]string{
				"version": Version,
				"build":   Build,
				"os":      runtime.GOOS,
				"arch":    runtime.GOARCH,
			})
			fmt.Println(string(b))
		} else {
			fmt.Println(Version)
		}
		return 0
	case "run":
		f := parseRunFlags(args[1:])
		return core.Run(ctx, f)
	case "supervise":
		f := parseRunFlags(args[1:])
		return core.Run(ctx, f)
	case "dev":
		if len(args) < 2 {
			fmt.Fprintln(os.Stderr, "usage: remoteagents dev <id> [args...]")
			return 1
		}
		cmds := api.DevCmds()
		c, ok := cmds[args[1]]
		if !ok {
			fmt.Fprintf(os.Stderr, "unknown dev command: %s\n", args[1])
			return 1
		}
		return c.Run(ctx, args[2:])
	default:
		fmt.Fprintf(os.Stderr, "unknown command: %s\n", args[0])
		return 1
	}
}

func parseRunFlags(args []string) core.Flags {
	f := core.Flags{}
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--home":
			i++; if i < len(args) { f.Home = args[i] }
		case "--config":
			i++; if i < len(args) { f.Config = args[i] }
		case "--password-file":
			i++; if i < len(args) { f.PasswordFile = args[i] }
		case "--pc":
			i++; if i < len(args) { f.PC = args[i] }
		case "--safe":
			f.Mode.Safe = true
		case "--no-tun":
			f.Mode.NoTun = true
		case "--no-channel":
			f.Mode.NoChannel = true
		case "--no-singbox":
			f.Mode.NoSingbox = true
		case "--dev-assets":
			i++; if i < len(args) { f.DevAssets = args[i] }
		case "--pprof":
			i++; if i < len(args) { f.Pprof = args[i] }
		case "--exit-after":
			i++
			if i < len(args) {
				if d, err := time.ParseDuration(args[i]); err == nil {
					f.ExitAfter = d
				}
			}
		case "--rollback-reason":
			i++; if i < len(args) { f.RollbackReason = args[i] }
		case "--release-base":
			i++; if i < len(args) { f.ReleaseBase = args[i] }
		}
	}
	return f
}

// suppress unused
var _ = strconv.Itoa
