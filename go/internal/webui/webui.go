package webui

import "remoteagents/internal/api"

type UI struct{}

func (u *UI) Name() string                { return "webui" }
func (u *UI) Start(ctx interface{}) error { panic("not implemented") }
func (u *UI) Stop(ctx interface{}) error  { panic("not implemented") }
func (u *UI) Status() map[string]any      { return nil }
func (u *UI) URL() string                 { return "" }

func New(act api.Actions, log api.Logger, devAssets string) (*UI, error) { panic("not implemented") }
