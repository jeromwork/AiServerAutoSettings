package webui

import (
	"context"
	"errors"

	"remoteagents/internal/api"
)

type UI struct{}

func (u *UI) Name() string                    { return "webui" }
func (u *UI) Start(ctx context.Context) error { return errors.New("webui: not-implemented") }
func (u *UI) Stop(ctx context.Context) error  { return errors.New("webui: not-implemented") }
func (u *UI) Status() map[string]any          { return nil }
func (u *UI) URL() string                     { return "" }

func New(act api.Actions, log api.Logger, devAssets string) (*UI, error) {
	return nil, errors.New("webui: not-implemented")
}
