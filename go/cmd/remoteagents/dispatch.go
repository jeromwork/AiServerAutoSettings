package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"runtime"
	"strings"

	"remoteagents/internal/api"
	"remoteagents/internal/config"
	"remoteagents/internal/core"
)

func dispatch(ctx context.Context, args []string) int {
	if len(args) == 0 {
		return launch(ctx, nil)
	}
	switch args[0] {
	case "version":
		if len(args) > 1 && args[1] == "--json" {
			b, _ := json.Marshal(map[string]any{
				"version": version,
				"build":   build,
				"os":      runtime.GOOS,
				"arch":    runtime.GOARCH,
				"schema":  config.SchemaVersion,
			})
			fmt.Println(string(b))
		} else {
			fmt.Println(version)
		}
		return 0

	case "run":
		f, err := parseRunFlags(args[1:], false)
		if err != nil {
			return 2
		}
		switch testFault {
		case "crash":
			fmt.Fprintln(os.Stderr, "testFault: crash")
			return 1
		case "hang":
			<-ctx.Done()
			return api.ExitOK
		}
		return core.Run(ctx, withBuildInfo(f))

	case "launch":
		return launch(ctx, args[1:])

	case "supervise":
		f, err := parseRunFlags(args[1:], true)
		if err != nil {
			return 2
		}
		p := api.NewPaths(f.Home)
		return runSupervised(ctx, p, f.Mode, args[1:])

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

	case "open", "status", "config", "update", "leftovers", "rollback", "pause", "resume":
		return runCLI(ctx, args[0], args[1:])

	case "install", "uninstall":
		return runInstall(args[0], args[1:])

	case "enable", "singbox":
		fmt.Fprintf(os.Stderr, "%s: not-implemented\n", args[0])
		return 1
	default:
		fmt.Fprintf(os.Stderr, "unknown command: %s\n", args[0])
		return 1
	}
}

func parseRunFlags(args []string, supervised bool) (core.Flags, error) {
	var f core.Flags
	var reset bool
	flags := flag.NewFlagSet("remoteagents", flag.ContinueOnError)
	flags.StringVar(&f.Home, "home", "", "application data directory")
	flags.StringVar(&f.Config, "config", "", "configuration file")
	flags.StringVar(&f.PasswordFile, "password-file", "", "configuration password file")
	flags.StringVar(&f.PC, "pc", "", "computer name")
	flags.BoolVar(&f.Mode.Safe, "safe", false, "start without system changes")
	flags.BoolVar(&f.Mode.NoTun, "no-tun", false, "disable TUN")
	flags.BoolVar(&f.Mode.NoChannel, "no-channel", false, "disable the channel")
	flags.BoolVar(&f.Mode.NoSingbox, "no-singbox", false, "disable sing-box")
	flags.StringVar(&f.DevAssets, "dev-assets", "", "development web assets")
	flags.StringVar(&f.Pprof, "pprof", "", "pprof address")
	flags.DurationVar(&f.ExitAfter, "exit-after", 0, "exit delay")
	flags.StringVar(&f.RollbackReason, "rollback-reason", "", "reason for rollback")
	flags.StringVar(&f.ReleaseBase, "release-base", "", "release base URL")
	if supervised {
		flags.BoolVar(&reset, "reset", false, "clear supervisor stopped state")
	}
	for i, arg := range args {
		switch strings.TrimLeft(arg, "-") {
		case "home", "config", "password-file", "pc", "dev-assets", "pprof", "exit-after", "rollback-reason", "release-base":
			if strings.HasPrefix(arg, "-") && (i+1 >= len(args) || strings.HasPrefix(args[i+1], "-")) {
				err := fmt.Errorf("missing value for %s", arg)
				_, _ = fmt.Fprintln(flags.Output(), err) // Best-effort diagnostic; return the parse error below.
				return f, err
			}
		}
	}
	if err := flags.Parse(args); err != nil {
		return f, err
	}
	if flags.NArg() != 0 {
		err := fmt.Errorf("unexpected argument: %s", flags.Arg(0))
		_, _ = fmt.Fprintln(flags.Output(), err) // Best-effort diagnostic; return the parse error below.
		return f, err
	}
	return f, nil
}
