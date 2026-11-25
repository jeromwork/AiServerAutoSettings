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
	api.RegisterDev(api.DevCmd{
		Name: "p5b",
		Help: "alias for platform",
		Run:  runPlatformDev,
	})
}

func runPlatformDev(_ context.Context, args []string) int {
	p := platform.Current()
	if len(args) == 0 || args[0] == "info" {
		fmt.Printf("os=%s arch=%s admin=%t home=%s\n", p.OS(), p.Arch(), p.IsAdmin(), p.DefaultHome())
		return 0
	}
	switch args[0] {
	case "runas":
		u, err := p.RunAsUser(api.ControlCfg{})
		if err != nil {
			fmt.Fprintf(os.Stderr, "runas error: %v\n", err)
			return 1
		}
		fmt.Printf("runas=%s\n", u)
		return 0
	default:
		fmt.Fprintf(os.Stderr, "unknown platform command: %s\n", args[0])
		return 1
	}
}
