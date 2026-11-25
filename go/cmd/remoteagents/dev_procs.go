package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"time"

	"remoteagents/internal/api"
	"remoteagents/internal/procs"
)

func init() {
	api.RegisterDev(api.DevCmd{
		Name: "procs",
		Help: "procs dev commands: orphan",
		Run:  runDevProcs,
	})
}

func runDevProcs(ctx context.Context, args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: remoteagents dev procs orphan")
		return 1
	}
	switch args[0] {
	case "orphan":
		pr := procs.New(nil, nil)
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
