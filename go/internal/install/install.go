// Package install — постоянный путь запуска сторожа (home/bin/remoteagents) и ярлык на рабочем столе.
// Автозапуска и меню «Пуск» нет (решение владельца 27.11): только путь и один ярлык.
package install

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"remoteagents/internal/api"
	"remoteagents/internal/supervise"
)

// ShortcutName — имя ярлыка на рабочем столе.
const ShortcutName = "RemoteAgents 3"

// Skip — установку отключает REMOTEAGENTS_NO_INSTALL=1 или сборка «dev».
func Skip(version string) bool {
	return version == "dev" || os.Getenv("REMOTEAGENTS_NO_INSTALL") == "1"
}

// Newer — a строго новее b (числовое сравнение по точкам; нечисловое — не новее).
func Newer(a, b string) bool {
	pa, pb := strings.Split(a, "."), strings.Split(b, ".")
	for i := 0; i < len(pa) || i < len(pb); i++ {
		var x, y int
		var e1, e2 error
		if i < len(pa) {
			x, e1 = strconv.Atoi(pa[i])
		}
		if i < len(pb) {
			y, e2 = strconv.Atoi(pb[i])
		}
		if e1 != nil || e2 != nil {
			return false
		}
		if x != y {
			return x > y
		}
	}
	return false
}

func samePath(a, b string) bool {
	ra, err1 := filepath.EvalSymlinks(a)
	rb, err2 := filepath.EvalSymlinks(b)
	if err1 != nil || err2 != nil {
		return strings.EqualFold(filepath.Clean(a), filepath.Clean(b))
	}
	return strings.EqualFold(ra, rb)
}

// RedirectTarget — путь постоянного exe, если он новее запущенного (self) и запускаться нужно с него; иначе "".
func RedirectTarget(p api.Paths, self, version string) string {
	perm := supervise.InstalledPath(p)
	if samePath(self, perm) {
		return ""
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	pv, err := supervise.BinaryVersion(ctx, perm)
	if err != nil || !Newer(pv, version) {
		return ""
	}
	return perm
}

// Ensure ставит self на постоянный путь (если там нет или старее) и приводит ярлык на рабочем столе.
// Все шаги — события в журнал; сбой не фатален.
func Ensure(p api.Paths, log api.Logger, self, version string) {
	perm := supervise.InstalledPath(p)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if !samePath(self, perm) {
		pv, err := supervise.BinaryVersion(ctx, perm)
		if err != nil || Newer(version, pv) {
			if err := copyExe(self, perm); err != nil {
				log.Warn("install: не удалось записать постоянный путь", "path", perm, "err", err)
			} else {
				log.Info("install: постоянный путь обновлён", "path", perm, "version", version, "was", pv)
			}
		} else {
			log.Info("install: постоянный путь уже не старее", "path", perm, "have", pv)
		}
	}
	if _, err := os.Stat(perm); err != nil {
		log.Warn("install: постоянного exe нет, ярлык не трогаю", "path", perm)
		return
	}
	for _, line := range syncShortcut(perm, p.Home) {
		log.Info("install: ярлык", "event", line)
	}
}

// Uninstall убирает ярлык на рабочем столе (и задачу автозапуска, если она когда-либо была создана).
func Uninstall(p api.Paths, log api.Logger) error {
	for _, line := range removeShortcuts(supervise.InstalledPath(p)) {
		log.Info("install: ярлык", "event", line)
	}
	return nil
}

func copyExe(src, dst string) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0700); err != nil {
		return err
	}
	b, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	tmp := dst + ".tmp"
	if err := os.WriteFile(tmp, b, 0700); err != nil { // #nosec G306 -- исполняемый файл владельца.
		return err
	}
	if err := os.Rename(tmp, dst); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("замена: %w", err)
	}
	return nil
}
