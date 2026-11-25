package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"time"

	"remoteagents/internal/api"
	"remoteagents/internal/api/fake"
	"remoteagents/internal/webui"
)

func init() {
	api.RegisterDev(api.DevCmd{
		Name: "webui",
		Help: "webui dev driver",
		Run:  runDevWebUI,
	})
	api.RegisterDev(api.DevCmd{
		Name: "p7",
		Help: "alias for dev webui",
		Run:  runDevWebUI,
	})
}

type devActions struct {
	fake.Actions
}

func (d *devActions) UpdateNow(ctx context.Context) error {
	fmt.Fprintln(os.Stderr, "fake: UpdateNow")
	return d.Actions.UpdateNow(ctx)
}

func runDevWebUI(ctx context.Context, args []string) int {
	ctx, cancel := signal.NotifyContext(ctx, os.Interrupt)
	defer cancel()
	var devAssets string

	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--dev-assets":
			if i+1 >= len(args) {
				fmt.Fprintln(os.Stderr, "webui: missing --dev-assets directory")
				return 2
			}
			devAssets = args[i+1]
			i++
		default:
			fmt.Fprintln(os.Stderr, "webui: unknown argument:", args[i])
			return 2
		}
	}

	act := &devActions{}
	log := &fake.Logger{}

	ui, err := webui.New(act, log, devAssets)
	if err != nil {
		fmt.Fprintf(os.Stderr, "webui: init failed: %v\n", err)
		return 1
	}

	defer func() {
		stopCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 3*time.Second)
		defer cancel()
		_ = ui.Stop(stopCtx)
	}()
	if err := ui.Start(ctx); err != nil {
		fmt.Fprintf(os.Stderr, "webui: start failed: %v\n", err)
		return 1
	}

	fmt.Println(ui.URL())

	<-ctx.Done()
	return 0
}
