package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"time"

	"remoteagents/internal/api"
	"remoteagents/internal/cleanup"
	"remoteagents/internal/platform"
	"remoteagents/internal/procs"
)

func init() {
	api.RegisterDev(api.DevCmd{
		Name: "procs",
		Help: "procs <orphan|sweep> <home>",
		Run:  runDevProcs,
	})
}

func runDevProcs(ctx context.Context, args []string) int {
	if len(args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: remoteagents dev procs <orphan|sweep> <home>")
		return 1
	}
	switch args[0] {
	case "sweep": // как при следующем старте: убрать остатки прошлых запусков по следам
		tr, err := cleanup.New(api.NewPaths(args[1]), nil, platform.Current())
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		for _, is := range tr.Run(ctx, "startup") {
			fmt.Fprintln(os.Stderr, is)
		}
		return 0
	case "orphan":
		tr, err := cleanup.New(api.NewPaths(args[1]), nil, platform.Current())
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		pr, _ := procs.New(nil, tr)
		sleepPath, err := exec.LookPath("sleep")
		if err != nil {
			sleepPath = "/bin/sleep"
		}
		proc, err := pr.Start(ctx, api.ProcSpec{
			Name: "sleep",
			Path: sleepPath,
			Args: []string{"600"},
		})
		if err != nil {
			fmt.Fprintf(os.Stderr, "procs: start-failed: %v\n", err)
			return 1
		}
		fmt.Printf("started sleep 600 pid=%d\n", proc.PID())
		time.Sleep(100 * time.Millisecond)
		p, _ := os.FindProcess(os.Getpid())
		_ = p.Kill()
		return 0
	default:
		fmt.Fprintf(os.Stderr, "unknown dev procs command: %s\n", args[0])
		return 1
	}
}
