package cleanup

import (
	"context"

	"remoteagents/internal/api"
)

type Cleaner struct{}

func New(p api.Paths, log api.Logger, plat api.Platform) (*Cleaner, error) { panic("not implemented") }
func (c *Cleaner) Run(ctx context.Context, reason string) []string         { panic("not implemented") }
func (c *Cleaner) Check(ctx context.Context) []string                      { panic("not implemented") }

// Cleaner implements api.Traces
func (c *Cleaner) Intent(t api.Trace) error { panic("not implemented") }
func (c *Cleaner) Applied(kind, id string, data, set map[string]string) error {
	panic("not implemented")
}
func (c *Cleaner) Done(kind, id string) error { panic("not implemented") }
func (c *Cleaner) Instance() string           { panic("not implemented") }
