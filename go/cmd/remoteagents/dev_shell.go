package main

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"

	"remoteagents/internal/api"
	"remoteagents/internal/api/fake"
	"remoteagents/internal/cleanup"
	"remoteagents/internal/platform"
	"remoteagents/internal/procs"
)

func init() {
	api.RegisterDev(api.DevCmd{
		Name: "shell",
		Help: "shell run <shell> <command>",
		Run:  runDevShell,
	})
	api.RegisterDev(api.DevCmd{
		Name: "p5a",
		Help: "p5a run <shell> <command>",
		Run:  runDevShell,
	})
}

func runDevShell(ctx context.Context, args []string) int {
	if len(args) < 3 || args[0] != "run" {
		fmt.Fprintln(os.Stderr, "usage: remoteagents dev shell run <shell> <cmd>")
		return 1
	}

	shellType := args[1]
	cmdStr := args[2]
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	log := &fake.Logger{}
	// Do not substitute a fake trace journal for a live process manager.
	home, err := os.MkdirTemp("", "ra-shell-")
	if err != nil {
		fmt.Fprintln(os.Stderr, "shell: temporary-home-failed")
		return 1
	}
	defer func() {
		if err := os.RemoveAll(home); err != nil {
			fmt.Fprintln(os.Stderr, "shell: temporary-home-cleanup-failed")
		}
	}()
	traces, err := cleanup.New(api.NewPaths(home), log, platform.Current())
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	manager, err := procs.New(log, traces)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	sh := platform.Current().NewShell(log, manager, "")
	defer func() { _ = sh.KillAll() }()
	req := api.ExecReq{
		Shell: shellType,
		Cmd:   cmdStr,
		Wait:  true,
	}

	proc, err := sh.Start(ctx, req)
	if err != nil {
		fmt.Println(err.Error())
		return 1
	}

	out := string(proc.Read("out", 0).Data)
	if out != "" {
		fmt.Print(out)
		if !strings.HasSuffix(out, "\n") {
			fmt.Println()
		}
	}

	errOut := string(proc.Read("err", 0).Data)
	if errOut != "" {
		fmt.Fprint(os.Stderr, errOut)
		if !strings.HasSuffix(errOut, "\n") {
			fmt.Fprintln(os.Stderr)
		}
	}

	fmt.Printf("код %d\n", proc.Code())
	return proc.Code()
}
