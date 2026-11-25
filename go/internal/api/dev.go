package api

import "context"

type DevCmd struct {
	Name string
	Help string
	Run  func(ctx context.Context, args []string) int
}

var devCmds = map[string]DevCmd{}

func RegisterDev(c DevCmd) {
	if _, dup := devCmds[c.Name]; dup {
		panic("dev command registered twice: " + c.Name)
	}
	devCmds[c.Name] = c
}

func DevCmds() map[string]DevCmd { return devCmds }
