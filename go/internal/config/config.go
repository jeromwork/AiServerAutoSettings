package config

import (
	"errors"
	"time"

	"remoteagents/internal/api"
)

var (
	ErrNoConfig = errors.New("config: no-config")
	ErrPending  = errors.New("config: pending")
	ErrStale    = errors.New("config: stale")
)

type Problem struct {
	Stage, Code, Field, Msg string
}

type CheckError struct{ Problems []Problem }

func (e *CheckError) Error() string { return "config: check failed" }

func Parse(data []byte) (*api.Config, []Problem) {
	return nil, []Problem{{Stage: "schema", Code: "not-implemented", Msg: "config: not-implemented"}}
}
func Open(data []byte, password string) (*api.Config, []byte, error) {
	return nil, nil, errors.New("config: not-implemented")
}
func OpenWithKey(data []byte, key []byte) (*api.Config, error) {
	return nil, errors.New("config: not-implemented")
}
func Load(p api.Paths, log api.Logger) (*api.Config, string, error) {
	return nil, "", errors.New("config: not-implemented")
}
func LoadFile(path, passwordFile string, log api.Logger) (*api.Config, error) {
	return nil, errors.New("config: not-implemented")
}

type Pointers struct {
	Current, LastGood string
	Switch            *Switch
}

type Switch struct {
	Op, From, To      string
	Started, Deadline time.Time
}

func ReadPointers(p api.Paths) (Pointers, error) {
	return Pointers{}, errors.New("config: not-implemented")
}
func Apply(p api.Paths, data []byte, password string, log api.Logger) (string, error) {
	return "", errors.New("config: not-implemented")
}
func Commit(p api.Paths, gen string, sessionStarted time.Time) error {
	return errors.New("config: not-implemented")
}
func Revert(p api.Paths, log api.Logger) error {
	return errors.New("config: not-implemented")
}
func Expire(p api.Paths, now time.Time, log api.Logger) (bool, error) {
	return false, errors.New("config: not-implemented")
}
func SaveKey(p api.Paths, gen string, key []byte) error {
	return errors.New("config: not-implemented")
}
