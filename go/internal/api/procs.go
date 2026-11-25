package api

import (
	"context"
	"io"
	"time"
)

type ProcSpec struct {
	Name   string
	Path   string
	Args   []string
	Dir    string
	Env    []string
	RunAs  string
	Stream string    // поток журнала, если Stdout/Stderr == nil
	Stdin  io.Reader // nil — пусто
	Stdout io.Writer // nil — в журнал Stream
	Stderr io.Writer
}

type Process interface {
	PID() int
	Started() time.Time
	Done() <-chan struct{}
	ExitCode() int
	Stop(ctx context.Context) error // мягко 5 с (CTRL_BREAK / SIGTERM группе), затем kill всего дерева (Job / группа)
}

// Procs: все дети ядра — в одном Job Object (Windows, KILL_ON_JOB_CLOSE) / одной группе процессов (Unix),
// Linux дополнительно Pdeathsig. Trace: Intent{kind:process,id:<name>-<nonce>,data:{exe,home}} до запуска,
// Applied{pid,start} сразу после; Done после выхода.
type Procs interface {
	Start(ctx context.Context, s ProcSpec) (Process, error)
	KillAll(ctx context.Context) error
}
