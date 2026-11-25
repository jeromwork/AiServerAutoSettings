package api

import (
	"context"
	"time"
)

type ExecReq struct {
	Cmd   string `json:"cmd"`
	Shell string `json:"shell"` // powershell | cmd | sh; "" → powershell на Windows, sh иначе
	Cwd   string `json:"cwd,omitempty"`
	Wait  bool   `json:"wait,omitempty"`
}

// Chunk — ответ чтения вывода (семантика v2 agent.py 20–49, 227–240).
// Буфер каждого потока ≤1 МиБ; лишнее отрезается спереди, Base растёт. off < Base → читать с Base.
type Chunk struct {
	Data    []byte
	NextOff int // off' + len(Data), где off' = max(off, Base)
	Base    int
}

type ExecProc interface {
	ID() string
	Read(stream string, off int) Chunk // stream: "out" | "err"
	// WaitNew: ждёт, пока процесс завершится ИЛИ появятся байты за outOff/errOff; max — верхний предел (v3: 25 с, v2 ждёт без предела).
	WaitNew(ctx context.Context, outOff, errOff int, max time.Duration)
	Exited() bool                    // процесс завершён
	Drained(outOff, errOff int) bool // завершён и оба смещения дошли до конца — это v2 "exited"
	Code() int
	Truncated() bool
	Kill() error
}

type Shell interface {
	Start(ctx context.Context, r ExecReq) (ExecProc, error) // ошибка "shell: shell-unavailable: <имя>"
	Get(id string) (ExecProc, bool)
	List() []ExecProc
	KillAll() error
}
