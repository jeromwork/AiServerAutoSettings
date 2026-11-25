//go:build darwin || linux

package cleanup

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

func shellQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

// Не включаем вывод команд: ps и системные ошибки могут содержать секреты.
func (c *Cleaner) unixCommand(name string, args ...string) ([]byte, error) {
	out, err := exec.CommandContext(c.ctx, name, args...).Output()
	if err != nil {
		return nil, fmt.Errorf("%s: %w", name, err)
	}
	return out, nil
}

func (c *Cleaner) change(left, manual string, fn func() error) {
	if c.reading {
		c.note(left)
		return
	}
	if err := fn(); err != nil {
		c.note(left + "; вручную: " + manual)
	}
}

func (c *Cleaner) removeExternal(path string) {
	if _, err := os.Lstat(path); os.IsNotExist(err) {
		return
	} else if err != nil {
		c.note("Не удалось проверить " + path)
		return
	}
	c.change("Остался файл "+path, "rm -f -- "+shellQuote(path), func() error { return os.Remove(path) })
}

func (c *Cleaner) processes() error {
	processes, err := c.ownedProcesses()
	if err != nil {
		return err
	}
	for pid, path := range processes {
		// Граница каталога не допускает соседнюю установку с похожим именем.
		rel, err := filepath.Rel(c.home, path)
		if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) || filepath.IsAbs(rel) {
			continue
		}
		name := strings.ToLower(filepath.Base(path))
		if !(strings.HasPrefix(name, "sing-box") || name == "ra2-vpn" || name == "ra2-lan" || name == "syncthing") {
			continue
		}
		if pid == os.Getpid() || pid == os.Getppid() {
			continue
		}
		id := strconv.Itoa(pid)
		c.change("Процессы: остался "+name+" (PID "+id+")", "sudo kill -KILL "+id, func() error {
			// Остановка по PID освобождает utun и его маршруты; чужие utun не трогаем.
			err := syscall.Kill(pid, syscall.SIGKILL)
			if errors.Is(err, syscall.ESRCH) {
				return nil
			}
			if errors.Is(err, syscall.EPERM) {
				return c.privileged("kill -KILL " + id)
			}
			return err
		})
	}
	return nil
}
