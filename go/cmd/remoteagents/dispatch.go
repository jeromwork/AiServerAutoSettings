package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"remoteagents/internal/api"
	"remoteagents/internal/bus"
	"remoteagents/internal/core"
	"remoteagents/internal/journal"
	"remoteagents/internal/procs"
	"remoteagents/internal/supervise"
	"remoteagents/internal/tray"
)

func dispatch(ctx context.Context, args []string) int {
	if len(args) == 0 {
		args = []string{"supervise"}
	}
	if strings.HasPrefix(args[0], "-") && args[0] != "--help" && args[0] != "-h" {
		args = append([]string{"supervise"}, args...)
	}
	switch args[0] {
	case "--help", "-h", "help":
		fmt.Println("usage: remoteagents [supervise|run] [--home DIR] [--config FILE] [--safe]\n       remoteagents version [--json]\n       remoteagents dev <id> [args...]")
		return 0
	case "version":
		if len(args) > 1 && args[1] == "--json" {
			b, _ := json.Marshal(map[string]string{
				"version": version,
				"build":   build,
				"os":      runtime.GOOS,
				"arch":    runtime.GOARCH,
			})
			fmt.Println(string(b))
		} else {
			fmt.Println(version)
		}
		return 0

	case "run":
		f, err := parseRunFlags(args[1:], false)
		if err != nil {
			if errors.Is(err, flag.ErrHelp) {
				return 0
			}
			return 2
		}
		return core.Run(ctx, f)

	case "supervise":
		f, err := parseRunFlags(args[1:], true)
		if err != nil {
			if errors.Is(err, flag.ErrHelp) {
				return 0
			}
			return 2
		}
		p := api.NewPaths(f.Home)
		log, err := journal.New(p, api.StreamSup)
		if err != nil {
			return 1
		}
		defer log.Close()
		b := bus.New(log)
		defer b.Close()
		pr := procs.New(log, b)
		ctx, cancel := context.WithCancel(ctx)
		defer cancel()
		done := make(chan int, 1)
		supervisorArgs := append([]string(nil), args[1:]...)
		supervisorArgs = append(supervisorArgs, "--home", f.Home)
		start := func() {
			go func() {
				done <- supervise.Run(ctx, p, log, pr, os.Args[0], f.Mode, supervisorArgs, supervise.Options{Bus: b, Signers: f.Signers, Repo: f.ReleaseRepo})
				cancel()
			}()
		}
		if err := tray.New(tray.Options{Bus: b, Log: log, Procs: pr, Ready: start}).Run(ctx); err != nil {
			log.Warn("tray.failed", "err", err)
		}
		code := <-done
		_ = pr.KillAll(context.Background())
		return code

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

func parseRunFlags(args []string, supervised bool) (core.Flags, error) {
	var f core.Flags
	var reset, autostart bool
	var signers string
	f.Version = version
	f.ReleaseRepo = releaseRepo
	f.Signers = []string{pubKeys}
	flags := flag.NewFlagSet("remoteagents", flag.ContinueOnError)
	flags.BoolVar(&autostart, "autostart", false, "start the supervisor at login")
	flags.StringVar(&f.Home, "home", "", "application data directory")
	flags.StringVar(&f.Launcher, "launcher", "", "supervisor executable")
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
	flags.StringVar(&signers, "update-signers", pubKeys, "release verification public keys")
	flags.StringVar(&f.ReleaseRepo, "release-repo", releaseRepo, "release repository")
	if supervised {
		flags.BoolVar(&reset, "reset", false, "clear supervisor stopped state")
	}
	for i, arg := range args {
		switch strings.TrimLeft(arg, "-") {
		case "launcher", "home", "config", "password-file", "pc", "dev-assets", "pprof", "exit-after", "rollback-reason", "release-base", "update-signers", "release-repo":
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
	f.Signers = []string{signers}
	if f.Home == "" {
		base, err := os.UserConfigDir()
		if err != nil {
			return f, err
		}
		f.Home = filepath.Join(base, "RemoteAgents-lab")
	}
	home, err := filepath.Abs(f.Home)
	if err != nil {
		return f, err
	}
	f.Home = home
	if f.PC == "" {
		f.PC, _ = os.Hostname()
	}
	return f, nil
}
