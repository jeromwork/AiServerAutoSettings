package api

import "path/filepath"

// Paths — раскладка домашнего каталога. Личные данные: Config, Logs. Программа: Bin, Versions, State, Tmp.
type Paths struct {
	Home, Config, State, Logs, Tmp, Bin, Versions string
}

func NewPaths(home string) Paths {
	j := func(s string) string { return filepath.Join(home, s) }
	return Paths{Home: home, Config: j("config"), State: j("state"), Logs: j("logs"),
		Tmp: j("tmp"), Bin: j("bin"), Versions: j("versions")}
}

// Файлы блокировок (flock / LockFileEx), все в State:
const (
	LockRun     = "run.lock"     // держит сторож всё время жизни: второй supervise/run на тот же home → отказ "already-running"
	LockCore    = "core.lock"    // держит ядро
	LockOp      = "op.lock"      // одна операция записи: обновление, push, apply/revert конфига, откат, uninstall
	LockCleanup = "cleanup.lock" // одна уборка одновременно
)

// PauseFile — файл в State: пауза включена. Переживает падение ядра; сторож удаляет его при своём старте.
const PauseFile = "paused"
