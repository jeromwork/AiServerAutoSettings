package main

import (
	"context"
	"os"
	"os/signal"
	"syscall"

	"remoteagents/internal/api"
	"remoteagents/internal/core"
)

var version = "dev"
var build = "0"

// pubKeys and releaseRepo are set via -ldflags.
var pubKeys = ""
var releaseRepo = ""

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	code := dispatch(ctx, os.Args[1:])
	stop()
	os.Exit(code)
}

// suppress unused
var _ = api.ExitOK
var _ = core.Flags{}
var _ = pubKeys
var _ = releaseRepo
