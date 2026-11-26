package main

import (
	"remoteagents/internal/api"
	"remoteagents/internal/platform"
)

func init() {
	api.RegisterDev(api.DevCmd{Name: "autostart", Help: "<os>: verify an autostart specification", Run: platform.RunAutostartDev})
}
