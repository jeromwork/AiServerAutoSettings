package main

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"

	"remoteagents/internal/api"
	"remoteagents/internal/api/fake"
	"remoteagents/internal/platform"
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

	sh := platform.Current().NewShell(&fake.Logger{}, nil, "")
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
