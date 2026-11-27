package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"remoteagents/internal/api"
	"remoteagents/internal/install"
	"remoteagents/internal/journal"
	"remoteagents/internal/platform"
)

// runInstall — `install` (постоянный путь + ярлык на рабочем столе) и `uninstall` (убрать ярлык и задачу автозапуска).
func runInstall(cmd string, args []string) int {
	f, err := parseRunFlags(args, false)
	if err != nil {
		return 2
	}
	home := f.Home
	if home == "" {
		home = platform.Current().DefaultHome()
	}
	p := api.NewPaths(home)
	if err := os.MkdirAll(p.State, 0700); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	j, err := journal.New(p, api.StreamSup, journal.Options{MaxBytes: 5 << 20, Keep: 4})
	if err != nil {
		fmt.Fprintln(os.Stderr, "journal:", err)
		return 1
	}
	defer func() { _ = j.Close() }()
	if cmd == "uninstall" {
		_ = install.Uninstall(p, j)
		fmt.Println("Ярлык и автозапуск убраны")
		return 0
	}
	self, err := exec.LookPath(os.Args[0])
	if err == nil {
		self, err = filepath.Abs(self)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	install.Ensure(p, j, self, version)
	fmt.Println("Готово: постоянный путь и ярлык на рабочем столе")
	return 0
}
