//go:build windows

package main

import "remoteagents/internal/wincon"

// prepareConsole: exe собран как GUI (-H windowsgui), чёрного окна нет.
// CLI-команды из cmd пишут в консоль родителя; ядро (run) заводит скрытую консоль — в неё сторож шлёт Ctrl+Break;
// сторож (supervise, запуск без аргументов) консоли не имеет.
func prepareConsole(cmd string) {
	switch cmd {
	case "supervise", "launch", "":
	case "run":
		wincon.HiddenConsole()
	default:
		wincon.AttachParent()
	}
}
