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

// Procs: у каждого процесса своя корзина — Job Object (Windows, KILL_ON_JOB_CLOSE) / группа процессов (Unix),
// Linux дополнительно Pdeathsig.
type Procs interface {
	Start(ctx context.Context, s ProcSpec) (Process, error)
	KillAll(ctx context.Context) error
}
