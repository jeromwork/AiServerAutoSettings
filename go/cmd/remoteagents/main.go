package main

import (
	"context"
	"os"

	"remoteagents/internal/api"
	"remoteagents/internal/core"
)

var version = "dev"
var build = "0"

// pubKeys and releaseRepo are set via -ldflags.
var pubKeys = ""
var releaseRepo = ""

func main() {
	os.Exit(dispatch(context.Background(), os.Args[1:]))
}

// suppress unused
var _ = api.ExitOK
var _ = core.Flags{}
var _ = pubKeys
var _ = releaseRepo
