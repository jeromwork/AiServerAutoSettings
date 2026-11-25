// Package autostart: запуск программы при входе пользователя, БЕЗ прав администратора.
// Enable(exe) включает, Disable() выключает, Enabled() — включён ли автозапуск.
package autostart

import (
	"fmt"
	"os/exec"
	"strings"
)

const id = "ru.remoteagents.app" // имя службы/задачи/метка

func run(name string, args ...string) error {
	if out, err := exec.Command(name, args...).CombinedOutput(); err != nil {
		return fmt.Errorf("%s: %w: %s", name, err, strings.TrimSpace(string(out)))
	}
	return nil
}
