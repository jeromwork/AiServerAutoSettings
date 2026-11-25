package config

import (
	"errors"
	"io"
	"time"

	"remoteagents/internal/api"
)

var (
	ErrNoConfig = errors.New("no-config")
	ErrPending  = errors.New("pending")
	ErrStale    = errors.New("stale")
)

type Problem struct {
	Stage, Code, Field, Msg string
}

type CheckError struct{ Problems []Problem }

func (e *CheckError) Error() string { return "config check failed" }

func Parse(data []byte) (*api.Config, []Problem)                     { panic("not implemented") }
func Open(data []byte, password string) (*api.Config, []byte, error) { panic("not implemented") }
func OpenWithKey(data []byte, key []byte) (*api.Config, error)       { panic("not implemented") }
func Load(p api.Paths, log api.Logger) (*api.Config, string, error)  { panic("not implemented") }
func LoadFile(path, passwordFile string, log api.Logger) (*api.Config, error) {
	panic("not implemented")
}

type Pointers struct {
	Current, LastGood string
	Switch            *Switch
}

type Switch struct {
	Op, From, To      string
	Started, Deadline time.Time
}

func ReadPointers(p api.Paths) (Pointers, error) { panic("not implemented") }
func Apply(p api.Paths, data []byte, password string, log api.Logger) (string, error) {
	panic("not implemented")
}
func Commit(p api.Paths, gen string, sessionStarted time.Time) error  { panic("not implemented") }
func Revert(p api.Paths, log api.Logger) error                        { panic("not implemented") }
func Expire(p api.Paths, now time.Time, log api.Logger) (bool, error) { panic("not implemented") }
func SaveKey(p api.Paths, gen string, key []byte) error               { panic("not implemented") }

// ensure io is used
var _ io.Writer
