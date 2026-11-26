// Package config implements the remoteagents-2 config: validation, decryption and generations
// (config/gen-N, current, lastgood, switch.json; plan §5.2, api C7).
//
// Locking: Apply, Commit, Revert and Expire change files under Paths.Config. They do NOT take
// api.LockOp themselves; the caller (core actions, supervisor) holds it (api C6).
package config

import (
	"errors"
	"strings"
	"time"
)

var (
	ErrNoConfig = errors.New("config: no-config")
	ErrPending  = errors.New("config: pending")
	ErrStale    = errors.New("config: stale")
	// ErrNoPrevious: Revert has no earlier good generation to return to.
	ErrNoPrevious = errors.New("config: no-previous")
)

// Problem.Stage: json|schema|semantic|password|decrypt.
type Problem struct {
	Stage, Code, Field, Msg string
}

type CheckError struct{ Problems []Problem }

func (e *CheckError) Error() string {
	if e == nil || len(e.Problems) == 0 {
		return "config: check failed"
	}
	parts := make([]string, 0, len(e.Problems))
	for _, p := range e.Problems {
		parts = append(parts, p.Stage+"/"+p.Code+":"+p.Field)
	}
	return "config: check failed: " + strings.Join(parts, ", ")
}

type Pointers struct {
	Current, LastGood string
	Switch            *Switch
}

type Switch struct {
	Op, From, To      string
	Started, Deadline time.Time
}
