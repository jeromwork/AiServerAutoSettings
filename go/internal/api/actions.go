package api

import (
	"context"
	"errors"
	"io"
)

var (
	ErrNotSupported = errors.New("not-supported")
	ErrBusy         = errors.New("busy") // LockOp занят другой операцией
	ErrSafe         = errors.New("safe-mode")
)

// Actions — реализует internal/core. Все операции записи берут LockOp (блок C, C6).
type Actions interface {
	Status() map[string]any
	UpdateCheck(ctx context.Context) (*Release, error)
	UpdateNow(ctx context.Context) error
	InstallDev(ctx context.Context, body io.Reader, sha256, version string) error // /update агента (ra3 push)
	ConfigCheck(data []byte, password string) error
	ConfigApply(ctx context.Context, data []byte, password string) error
	ConfigRevert(ctx context.Context) error
	ConfigExport() ([]byte, error)                         // сохранённый конфиг как есть (с ключами, без пароля)
	ConfigSetVPN(ctx context.Context, mode string) error   // vpn.mode в сохранённом конфиге + применение как ConfigApply
	ConfigSetVPNLock(ctx context.Context, on bool) error   // vpn.lockExit («выход только через наш адрес») в сохранённом конфиге + применение
	CheckExit(ctx context.Context) (map[string]any, error) // проверка внешнего адреса выхода по кнопке; итог = статус VPN
	SetControl(on bool) error
	SwitchPath(name string) error // → Channel.ForcePath
	VPN(mode string) error        // до N1b → ErrNotSupported; в Safe → ErrSafe
	HappierURL() (string, error)
	LogTail(n int) []string
	LogZip(w io.Writer) error
	LogSend(ctx context.Context) error
	Leftovers(ctx context.Context) ([]string, error)
	Restart(ctx context.Context) error
	Rollback(ctx context.Context, reason string) error
	Exit(ctx context.Context) error
	Pause(ctx context.Context) error  // остановить всё сетевое, программа остаётся
	Resume(ctx context.Context) error // поднять сеть обратно по текущему конфигу
}

// AgentDeps. Fwd — ленивый: агент создаётся раньше forward (порядок — блок C, C4); nil → /expose 503 "forward-not-ready".
type AgentDeps struct {
	Log     Logger
	Traces  Traces
	Shell   Shell
	Fwd     func() Forwarder
	Act     Actions
	Paths   Paths
	Control func() bool
	Status  func() map[string]any
	MaxBody int64 // 8 МиБ
	MaxDev  int64 // 100 МиБ
}
