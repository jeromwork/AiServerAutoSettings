package supervise

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"runtime"

	"remoteagents/internal/api"
)

var nameRule = regexp.MustCompile(api.VersionRe)

type action int

const (
	actRestart action = iota
	actStop
)

// slots mirrors v2 CodeSlots: which version runs (Current), which one was proven (LastGood), what to do when the core exits.
// State is Versions/state.json (written atomically). The embedded version is the supervisor's own binary.
type slots struct {
	Current        string `json:"current"`
	LastGood       string `json:"lastGood"`
	Previous       string `json:"previous,omitempty"`
	EmbeddedSeen   string `json:"embeddedSeen"`
	FailsGood      int    `json:"failsGood"`
	MemRestarts    int    `json:"memRestarts"`
	RollbackReason string `json:"rollbackReason"`

	dir, home, embedded, self string
	reason                    string // reason of the last decision, for the journal
}

func exeName() string {
	if runtime.GOOS == "windows" {
		return "remoteagents.exe"
	}
	return "remoteagents"
}

func (s *slots) statePath() string   { return filepath.Join(s.dir, "state.json") }
func (s *slots) pendingPath() string { return filepath.Join(s.dir, "pending.json") }
func (s *slots) unverified() bool    { return s.Current != s.LastGood }

func (s *slots) exePath(name string) string {
	if name == s.embedded {
		return s.self
	}
	return filepath.Join(s.dir, name, exeName())
}

func (s *slots) exists(name string) bool {
	if name != s.embedded && !nameRule.MatchString(name) {
		return false
	}
	st, err := os.Stat(s.exePath(name))
	return err == nil && st.Mode().IsRegular()
}

func loadSlots(p api.Paths, self, embedded string, reset bool, log api.Logger) *slots {
	s := &slots{dir: p.Versions, home: p.Home, embedded: embedded, self: self}
	if b, err := os.ReadFile(s.statePath()); err == nil {
		if json.Unmarshal(b, s) != nil {
			log.Warn("state.broken", "why", "state.json повреждён, беру встроенную версию")
			*s = slots{dir: p.Versions, home: p.Home, embedded: embedded, self: self}
		}
	}
	// New build of the supervisor, or broken/empty state: the embedded version becomes current.
	if s.EmbeddedSeen != embedded || s.Current == "" || !s.exists(s.Current) {
		s.Current, s.EmbeddedSeen, s.FailsGood, s.MemRestarts = embedded, embedded, 0, 0
	}
	if s.LastGood != "" && !s.exists(s.LastGood) {
		s.LastGood = ""
	}
	if reset {
		s.FailsGood, s.MemRestarts = 0, 0
	}
	s.save(log)
	return s
}

func (s *slots) save(log api.Logger) {
	b, _ := json.Marshal(s)
	tmp := s.statePath() + ".tmp"
	err := os.WriteFile(tmp, b, 0o600)
	if err == nil {
		err = os.Rename(tmp, s.statePath())
	}
	if err != nil {
		log.Error("state.save", "err", err.Error())
	}
}

// markGood: the core said good, the current version is proven.
func (s *slots) markGood(log api.Logger) {
	if s.LastGood != "" && s.LastGood != s.Current {
		s.Previous = s.LastGood
	}
	s.LastGood, s.FailsGood, s.MemRestarts, s.RollbackReason = s.Current, 0, 0, ""
	s.save(log)
}

// takePending returns the version named by pending.json (and deletes the file) if it is usable, otherwise "".
func (s *slots) takePending(log api.Logger) string {
	b, err := os.ReadFile(s.pendingPath())
	if err != nil {
		return ""
	}
	_ = os.Remove(s.pendingPath())
	var j struct {
		Dir string `json:"dir"`
	}
	if json.Unmarshal(b, &j) != nil || !s.exists(j.Dir) {
		log.Warn("pending.bad", "why", "pending.json указывает на негодную папку, перезапускаю прежнюю версию")
		return ""
	}
	return j.Dir
}

// onExit is v2 CodeSlots.OnExit. fuse = the silence timer fired. The decision is stored in s.reason.
func (s *slots) onExit(code int, fuse bool, ranSec float64, goodSeen bool, log api.Logger) action {
	done := func(a action, reason string) action { s.reason = reason; s.save(log); return a }
	if !fuse && code == api.ExitRestart {
		if next := s.takePending(log); next != "" && next != s.Current {
			s.Current, s.FailsGood, s.MemRestarts = next, 0, 0
			return done(actRestart, "новая версия "+next)
		}
		// An unverified version that restarts itself without new code is a loop without pauses: counted as a crash.
		if !s.unverified() {
			return done(actRestart, "перезапуск по просьбе ядра (код 3)")
		}
	}
	if !fuse && code == api.ExitMemory {
		s.MemRestarts++
		if s.MemRestarts > api.MaxMemRestarts {
			return done(actStop, fmt.Sprintf("память ядра превышена %d раз подряд", s.MemRestarts))
		}
		return done(actRestart, fmt.Sprintf("перезапуск из-за памяти (%d из %d)", s.MemRestarts, api.MaxMemRestarts))
	}
	why, whyEn := fmt.Sprintf("версия %s упала с кодом %d", s.Current, code), fmt.Sprintf("version %s crashed, exit code %d", s.Current, code)
	switch {
	case fuse:
		why, whyEn = fmt.Sprintf("версия %s не подняла канал за %d с", s.Current, api.SilenceUnverifiedSec), fmt.Sprintf("version %s did not bring the channel up in %d s", s.Current, api.SilenceUnverifiedSec)
	case code == 0:
		why, whyEn = fmt.Sprintf("версия %s вышла с кодом 0 без просьбы", s.Current), fmt.Sprintf("version %s exited with code 0 unrequested", s.Current)
	}
	if s.unverified() {
		if s.LastGood != "" {
			s.Current, s.RollbackReason, s.FailsGood, s.MemRestarts = s.LastGood, whyEn, 0, 0
			return done(actRestart, "откат на "+s.LastGood+": "+why)
		}
		if s.Current != s.embedded && s.exists(s.embedded) {
			s.Current, s.RollbackReason, s.FailsGood, s.MemRestarts = s.embedded, whyEn, 0, 0
			return done(actRestart, "откат на встроенную версию: "+why)
		}
	} else if goodSeen && ranSec >= api.LongRunSec {
		s.FailsGood = 0 // ran long: this is not a chain of crashes
	}
	s.FailsGood++
	if s.FailsGood >= api.MaxFailsGood {
		return done(actStop, fmt.Sprintf("%s; подряд падений: %d", why, s.FailsGood))
	}
	return done(actRestart, fmt.Sprintf("%s; перезапуск (%d из %d)", why, s.FailsGood, api.MaxFailsGood))
}
