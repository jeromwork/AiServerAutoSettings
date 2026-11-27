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

// testFault — только для проверки обновления/отката на тестовых сборках (-X main.testFault=…); в выпуске пусто.
// crash: ядро падает сразу; hang: ядро живёт, но не шлёт good; reject-config: `config check --current` отказывает.
var testFault = ""

func main() {
	cmdName := ""
	if len(os.Args) > 1 {
		cmdName = os.Args[1]
	}
	prepareConsole(cmdName)
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
