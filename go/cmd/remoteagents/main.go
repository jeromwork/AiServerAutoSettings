package main

import (
	"context"
	"fmt"
	"os"

	"remoteagents/internal/api"
	"remoteagents/internal/core"
)

var Version = "dev"
var Build = "0"

func main() {
	os.Exit(dispatch(context.Background(), os.Args[1:]))
}

// silence unused
var _ = api.ExitOK
var _ = core.Flags{}
var _ = fmt.Sprintf
