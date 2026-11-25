package api

import (
	"context"
	"errors"
	"io"
)

var (
	ErrNotSupported = errors.New("not-supported")
	ErrBusy         = errors.New("busy")
	ErrSafe         = errors.New("safe-mode")
)

type Actions interface {
	Status() map[string]any
	UpdateCheck(ctx context.Context) (*Release, error)
	UpdateNow(ctx context.Context) error
	InstallDev(ctx context.Context, body io.Reader, sha256, version string) error
	ConfigCheck(data []byte, password string) error
	ConfigApply(ctx context.Context, data []byte, password string) error
	ConfigRevert(ctx context.Context) error
	SetControl(on bool) error
	SwitchPath(name string) error
	VPN(mode string) error
	HappierURL() (string, error)
	LogTail(n int) []string
	LogZip(w io.Writer) error
	LogSend(ctx context.Context) error
	Leftovers(ctx context.Context) ([]string, error)
	Restart(ctx context.Context) error
	Rollback(ctx context.Context, reason string) error
	Exit(ctx context.Context) error
}

type AgentDeps struct {
	Log     Logger
	Shell   Shell
	Fwd     func() Forwarder
	Act     Actions
	Paths   Paths
	Control func() bool
	Status  func() map[string]any
	MaxBody int64
	MaxDev  int64
}
