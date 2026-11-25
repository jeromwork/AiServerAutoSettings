package main

import (
	"context"
	"fmt"
	"os"

	"remoteagents/internal/api"
	"remoteagents/internal/cleanup"
)

func init() {
	api.RegisterDev(api.DevCmd{Name: "cleanup", Help: "cleanup check <home> | run <home> startup|exit", Run: runDevCleanup})
}

func runDevCleanup(ctx context.Context, args []string) int {
	if len(args) < 2 || (args[0] == "run" && len(args) < 3) || (args[0] != "check" && args[0] != "run") {
		fmt.Fprintln(os.Stderr, "usage: remoteagents dev cleanup check <home> | run <home> startup|exit")
		return 1
	}
	c, err := cleanup.New(api.NewPaths(args[1]), nil)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	var issues []string
	if args[0] == "check" {
		issues = c.Check(ctx)
	} else {
		issues = c.Run(ctx, args[2])
	}
	for _, s := range issues {
		fmt.Println(s)
	}
	return 0
}
