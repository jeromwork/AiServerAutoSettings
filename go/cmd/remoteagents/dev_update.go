package main

import (
	"context"
	"fmt"
	"os"
	"strings"

	"remoteagents/internal/api"
	"remoteagents/internal/update"
)

func init() {
	api.RegisterDev(api.DevCmd{
		Name: "update",
		Help: "update dev commands: check <home> (env RA_REPO, RA_SIGNERS, RA_RELEASE_BASE; read-only network)",
		Run:  runDevUpdate,
	})
}

func runDevUpdate(ctx context.Context, args []string) int {
	if len(args) != 2 || args[0] != "check" {
		fmt.Fprintln(os.Stderr, "usage: remoteagents dev update check <home>")
		return 1
	}
	u, err := update.New(api.NewPaths(args[1]), nil, update.Options{
		Repo: os.Getenv("RA_REPO"), Signers: strings.Split(os.Getenv("RA_SIGNERS"), "\n"), BaseURL: os.Getenv("RA_RELEASE_BASE")})
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	r, err := u.Check(ctx)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	fmt.Printf("version=%s build=%d os=%s arch=%s sha256=%s\n", r.Version, r.Build, r.OS, r.Arch, r.SHA256)
	return 0
}
