package api

import "context"

// Ручные драйверы пакетной приёмки: `remoteagents dev <ID задачи> …`, имя = ID задачи в нижнем регистре (p6a, p13…).
// Регистрация — в cmd/remoteagents/dev_<id>.go владельца задачи через init(); повтор имени — panic при старте (ловится сразу).
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
