package supervise

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"

	"remoteagents/internal/api"
)

var versionName = regexp.MustCompile(api.VersionRe)

type slotState struct {
	Current        string `json:"current"`
	LastGood       string `json:"lastGood"`
	PrevGood       string `json:"prevGood"`
	EmbeddedSeen   string `json:"embeddedSeen"`
	FailsGood      int    `json:"failsGood"`
	FailsBoot      int    `json:"failsBoot"`
	MemRestarts    int    `json:"memRestarts"`
	RollbackReason string `json:"rollbackReason"`
	Stopped        string `json:"stopped"`
}

type slots struct {
	slotState
	p               api.Paths
	embedded        string
	embeddedVersion string
	self            string
}

func executableName() string {
	if runtime.GOOS == "windows" {
		return "remoteagents.exe"
	}
	return "remoteagents"
}

func (s *slots) path(v string) string {
	if v == s.embedded {
		return s.self
	}
	return filepath.Join(s.p.Versions, v, executableName())
}

func (s *slots) exists(v string) bool {
	if v == "" || !versionName.MatchString(v) {
		return false
	}
	// Refuse symlink slots; pruning and execution must stay within Versions.
	if v != s.embedded {
		st, err := os.Lstat(filepath.Join(s.p.Versions, v))
		if err != nil || !st.IsDir() || st.Mode()&os.ModeSymlink != 0 {
			return false
		}
	}
	st, err := os.Lstat(s.path(v))
	return err == nil && st.Mode().IsRegular() && (runtime.GOOS == "windows" || st.Mode()&0111 != 0)
}

func loadSlots(p api.Paths, self, embeddedVersion string, reset bool) (*slots, error) {
	if embeddedVersion == "" {
		embeddedVersion = "embedded"
	}
	s := &slots{
		p:               p,
		embedded:        "embedded",
		embeddedVersion: embeddedVersion,
		self:            self,
	}
	if err := os.MkdirAll(p.Versions, 0700); err != nil {
		return nil, err
	}
	b, err := os.ReadFile(filepath.Join(p.Versions, "state.json"))
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	if len(b) > 0 {
		if err := json.Unmarshal(b, &s.slotState); err != nil {
			s.slotState = slotState{}
		}
	}
	if s.EmbeddedSeen != embeddedVersion || s.Current == "" || !s.exists(s.Current) {
		s.Current = s.embedded
		s.EmbeddedSeen = embeddedVersion
		s.FailsGood = 0
		s.FailsBoot = 0
		s.MemRestarts = 0
		s.Stopped = ""
		s.RollbackReason = ""
	}
	if !s.exists(s.LastGood) {
		s.LastGood = ""
	}
	if !s.exists(s.PrevGood) {
		s.PrevGood = ""
	}
	if reset {
		s.Stopped = ""
		s.FailsGood = 0
		s.FailsBoot = 0
		s.MemRestarts = 0
	}
	return s, s.save()
}

func (s *slots) save() error {
	return writeJSON(filepath.Join(s.p.Versions, "state.json"), s.slotState)
}

func (s *slots) markGood() {
	if s.Current != s.LastGood {
		if s.LastGood != "" {
			s.PrevGood = s.LastGood
		}
		s.LastGood = s.Current
		s.MemRestarts = 0
	}
	s.FailsBoot = 0
	s.RollbackReason = ""
}

func (s *slots) pending() (string, error) {
	path := filepath.Join(s.p.Versions, "pending.json")
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	var v struct {
		Dir string `json:"dir"`
	}
	if err := json.Unmarshal(b, &v); err != nil || !s.exists(v.Dir) {
		return "", fmt.Errorf("supervise: pending-invalid: invalid candidate")
	}
	return v.Dir, nil
}

func (s *slots) transition(code int, silence, rollback bool, reason string) error {
	if !silence && code == api.ExitRestart {
		if rollback {
			next := s.LastGood
			if s.Current == s.LastGood {
				next = s.PrevGood
			}
			if next == "" || !s.exists(next) {
				next = s.embedded
			}
			s.Current = next
			s.RollbackReason = reason
			s.FailsGood = 0
			s.FailsBoot = 0
			s.MemRestarts = 0
			return s.save()
		}
		next, err := s.pending()
		if err == nil && next != "" && next != s.Current {
			s.Current = next
			s.FailsGood = 0
			s.FailsBoot = 0
			s.MemRestarts = 0
			s.RollbackReason = ""
			if err := s.save(); err != nil {
				return err
			}
			_ = os.Remove(filepath.Join(s.p.Versions, "pending.json"))
			return nil
		}
		if s.Current == s.LastGood {
			return s.save()
		}
	}
	if !silence && code == api.ExitMemory {
		s.MemRestarts++
		if s.MemRestarts > api.MaxMemRestarts {
			s.Stopped = "memory-limit"
		}
		return s.save()
	}
	s.RollbackReason = reason
	if s.Current != s.LastGood {
		switch {
		case s.LastGood != "" && s.exists(s.LastGood):
			s.Current = s.LastGood
			s.FailsGood = 0
			s.FailsBoot = 0
			s.MemRestarts = 0
		case s.Current != s.embedded && s.exists(s.embedded):
			s.Current = s.embedded
			s.FailsGood = 0
			s.FailsBoot = 0
			s.MemRestarts = 0
		default:
			s.FailsBoot++
			if s.FailsBoot >= api.MaxFailsBoot {
				s.Stopped = "boot-failures"
			}
		}
	} else {
		s.FailsGood++
		if s.FailsGood >= api.MaxFailsGood {
			s.Stopped = "good-failures"
		}
	}
	return s.save()
}

func (s *slots) prune() error {
	pending, err := s.pending()
	if err != nil {
		return err
	}
	entries, err := os.ReadDir(s.p.Versions)
	if err != nil {
		return err
	}
	var names []string
	for _, e := range entries {
		if e.IsDir() && versionName.MatchString(e.Name()) {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	count := len(names)
	for _, n := range names {
		if count <= api.MaxSlots {
			break
		}
		if n == s.Current || n == s.LastGood || n == s.PrevGood || n == pending {
			continue
		}
		if err := os.RemoveAll(filepath.Join(s.p.Versions, n)); err != nil {
			return err
		}
		count--
	}
	return nil
}

func writeJSON(path string, v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	return atomicWrite(path, b, 0600)
}

func atomicWrite(path string, b []byte, mode os.FileMode) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	f, err := os.CreateTemp(dir, ".supervise-*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	defer func() { _ = os.Remove(tmp) }()
	if err = f.Chmod(mode); err == nil {
		_, err = f.Write(b)
	}
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return replaceFile(tmp, path)
}

func copyBinary(src, dst string) error {
	f, err := os.Open(src)
	if err != nil {
		return err
	}
	defer func() { _ = f.Close() }()
	// Bounded copy; executable candidates have the same 100 MiB limit as Stage.
	b, err := io.ReadAll(io.LimitReader(f, (100<<20)+1))
	if err != nil {
		return err
	}
	if len(b) > 100<<20 {
		return fmt.Errorf("supervise: size: executable too large")
	}
	return atomicWrite(dst, b, 0700)
}
