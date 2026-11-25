package cleanup

import (
	"errors"
	"remoteagents/internal/api"
)

// Cleaner implements api.Traces
func (c *Cleaner) Intent(t api.Trace) error { return errors.New("cleanup: not-implemented") }
func (c *Cleaner) Applied(kind, id string, data, set map[string]string) error {
	return errors.New("cleanup: not-implemented")
}
func (c *Cleaner) Done(kind, id string) error { return errors.New("cleanup: not-implemented") }
func (c *Cleaner) Instance() string           { return "" }
