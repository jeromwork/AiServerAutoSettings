package main

import (
	"context"
	"fmt"
	"os"

	"remoteagents/internal/api"
	"remoteagents/internal/platform"
)

func init() {
	cmd := api.DevCmd{
		Name: "platform",
		Help: "platform diagnostics: info",
		Run:  runPlatformDev,
	}
	api.RegisterDev(cmd)
}

func runPlatformDev(_ context.Context, args []string) int {
	p := platform.Current()
	if len(args) == 0 || args[0] == "info" {
		fmt.Printf("os=%s arch=%s admin=%t home=%s\n", p.OS(), p.Arch(), p.IsAdmin(), p.DefaultHome())
		return 0
	}
	fmt.Fprintf(os.Stderr, "unknown platform command: %s\n", args[0])
	return 1
}
