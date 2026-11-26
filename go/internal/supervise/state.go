package supervise

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"time"

	"remoteagents/internal/api"
)

var versionName = regexp.MustCompile(api.VersionRe)
var errPendingInvalid = errors.New("supervise: pending-invalid: invalid candidate")

// StateSchema — формат versions/state.json. Поля только добавляются (старая сборка лишние игнорирует), поэтому
// откат версии читает состояние, записанное новой; Schema нужен, чтобы увидеть, кто писал файл.
const StateSchema = 1

type slotState struct {
	Schema         int    `json:"schema"`
	Current        string `json:"current"`
	LastGood       string `json:"lastGood"`
	PrevGood       string `json:"prevGood"`
	EmbeddedSeen   string `json:"embeddedSeen"`
	FailsGood      int    `json:"failsGood"`
	FailsBoot      int    `json:"failsBoot"`
	MemRestarts    int    `json:"memRestarts"`
	RollbackReason string `json:"rollbackReason"`
	Stopped        string `json:"stopped"`
	// Bad — версия, с которой последний раз откатились (авто- или ручной откат): автообновление её не ставит
	// повторно (иначе цикл «обновился — откатился»); ручное «Обновить» разрешено. Сбрасывается, когда она стала good.
	Bad string `json:"bad,omitempty"`
}

type slots struct {
	slotState
	p        api.Paths
	embedded string
	self     string
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
	if v == s.embedded && s.self == "" {
		return true
	}
	if v != s.embedded {
		st, err := os.Lstat(filepath.Join(s.p.Versions, v))
		if err != nil || !st.IsDir() || st.Mode()&os.ModeSymlink != 0 {
			return false
		}
	}
	st, err := os.Lstat(s.path(v))
	return err == nil && st.Mode().IsRegular() && (runtime.GOOS == "windows" || st.Mode()&0111 != 0)
}

func loadSlots(ctx context.Context, p api.Paths, self, embeddedVersion string, reset bool) (*slots, error) {
	resolved, err := exec.LookPath(self)
	if err != nil {
		return nil, err
	}
	self, err = filepath.Abs(resolved)
	if err != nil {
		return nil, err
	}
	if !versionName.MatchString(embeddedVersion) {
		return nil, fmt.Errorf("supervise: embedded-version: invalid version")
	}
	s := &slots{
		p:        p,
		embedded: embeddedVersion,
		self:     self,
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
	// Older state used a literal alias. Resolve it using the version recorded
	// at that time, never the newly installed binary's version.
	for _, slot := range []*string{&s.Current, &s.LastGood, &s.PrevGood} {
		if *slot == "embedded" {
			*slot = s.EmbeddedSeen
		}
	}
	// Recover older installations which kept the previous embedded only in .prev.
	if old := s.EmbeddedSeen; old != "" && old != embeddedVersion && !s.exists(old) &&
		(old == s.Current || old == s.LastGood || old == s.PrevGood) {
		previous := filepath.Join(p.Bin, executableName()+".prev")
		if version, err := binaryVersion(ctx, previous); err == nil && version == old {
			if err := s.archive(old, previous); err != nil {
				return nil, err
			}
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
	// Damaged counters must not overflow or bypass the finite restart limits.
	for _, n := range []*int{&s.FailsGood, &s.FailsBoot, &s.MemRestarts} {
		if *n < 0 {
			*n = 0
		} else if *n > 1000 {
			*n = 1000
		}
	}
	return s, s.save()
}

func initialize(ctx context.Context, p api.Paths, self string, mode api.Mode, reset bool) (*slots, error) {
	unlock, err := lockOperation(ctx, p)
	if err != nil {
		return nil, err
	}
	defer unlock()
	// Resolve argv[0] before moving any executable. The installed pathname then
	// refers to the promoted embedded binary; .prev retains its own identity.
	self, err = exec.LookPath(self)
	if err != nil {
		return nil, err
	}
	self, err = filepath.Abs(self)
	if err != nil {
		return nil, err
	}
	if err := rotateSelfUpdate(ctx, p); err != nil {
		return nil, err
	}
	embeddedVersion, err := binaryVersion(ctx, self)
	if err != nil {
		return nil, fmt.Errorf("supervise: embedded-version: %w", err)
	}
	s, err := loadSlots(ctx, p, self, embeddedVersion, reset)
	if err != nil {
		return nil, err
	}
	// Only a new supervisor invocation can change mode. Slot/config transitions
	// use the in-memory value and never read mode from a candidate.
	if err := writeJSON(filepath.Join(p.State, "mode.json"), mode); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *slots) resetMissing(ctx context.Context) error {
	unlock, err := lockOperation(ctx, s.p)
	if err != nil {
		return err
	}
	defer unlock()
	if !s.exists(s.embedded) {
		return fmt.Errorf("supervise: embedded-missing: no executable")
	}
	s.Current = s.embedded
	s.FailsGood, s.FailsBoot, s.MemRestarts = 0, 0, 0
	s.RollbackReason = ""
	if !s.exists(s.LastGood) {
		s.LastGood = ""
	}
	if !s.exists(s.PrevGood) {
		s.PrevGood = ""
	}
	return s.save()
}

func (s *slots) confirmGood(ctx context.Context) error {
	unlock, err := lockOperation(ctx, s.p)
	if err != nil {
		return err
	}
	defer unlock()
	s.markGood()
	if err := s.save(); err != nil {
		return err
	}
	if s.Current != s.embedded {
		return copyBinary(s.path(s.Current), filepath.Join(s.p.Bin, executableName()+".new"))
	}
	return nil
}

func (s *slots) clearFailures(ctx context.Context) error {
	unlock, err := lockOperation(ctx, s.p)
	if err != nil {
		return err
	}
	defer unlock()
	s.FailsGood = 0
	return s.save()
}

func lockOperation(ctx context.Context, p api.Paths) (func(), error) {
	// A core may still hold LockOp while finishing Stage/Apply. Do not lose a
	// death or good event merely because it raced with that operation.
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		unlock, err := lockFile(filepath.Join(p.State, api.LockOp))
		if !errors.Is(err, api.ErrBusy) {
			return unlock, err
		}
		select {
		case <-ctx.Done():
			return nil, fmt.Errorf("supervise: op-lock-timeout: %w", ctx.Err())
		case <-time.After(100 * time.Millisecond):
		}
	}
}

// archive preserves an embedded binary as a regular slot before its name is reused.
func (s *slots) archive(version, src string) error {
	if !versionName.MatchString(version) {
		return fmt.Errorf("supervise: archive-version: invalid version")
	}
	if s.exists(version) {
		return nil
	}
	dir := filepath.Join(s.p.Versions, version)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	st, err := os.Lstat(dir)
	if err != nil {
		return err
	}
	if !st.IsDir() || st.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("supervise: archive-slot: invalid directory")
	}
	return copyBinary(src, filepath.Join(dir, executableName()))
}

func (s *slots) discardSelfUpdate() error {
	return removeFile(filepath.Join(s.p.Bin, executableName()+".new"))
}

func (s *slots) save() error {
	if s.Schema < StateSchema {
		s.Schema = StateSchema
	}
	return writeJSON(filepath.Join(s.p.Versions, "state.json"), s.slotState)
}

func (s *slots) markGood() {
	if s.Current != s.LastGood {
		if s.LastGood != "" {
			s.PrevGood = s.LastGood
		}
		s.LastGood = s.Current
		s.MemRestarts = 0
		s.RollbackReason = ""
	}
	if s.Bad == s.Current {
		s.Bad = ""
	}
	s.RollbackReason = "" // версия подтверждена: причина прошлого отката больше не передаётся
	s.FailsBoot = 0
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
	if err := json.Unmarshal(b, &v); err != nil || !versionName.MatchString(v.Dir) {
		return "", errPendingInvalid
	}
	return v.Dir, nil
}

func (s *slots) transition(ctx context.Context, code int, silence, rollback bool, reason string) error {
	// Serialize manual/automatic rollback and pending-slot promotion with Stage
	// and uninstall. A failed lock must leave both memory and disk unchanged.
	unlock, err := lockOperation(ctx, s.p)
	if err != nil {
		return fmt.Errorf("supervise: op-lock: %w", err)
	}
	defer unlock()

	if !silence && code == api.ExitRestart {
		if rollback {
			next := s.LastGood
			if s.Current == s.LastGood {
				next = s.PrevGood
			}
			if next == "" || !s.exists(next) {
				next = s.embedded
			}
			// Cancel promotion before persisting the rollback; failure must stop it.
			if err := s.discardSelfUpdate(); err != nil {
				return err
			}
			if err := s.removePending(); err != nil {
				return err
			}
			if next != s.Current {
				s.Bad = s.Current
			}
			s.Current = next
			s.RollbackReason = reason
			s.FailsGood = 0
			s.FailsBoot = 0
			s.MemRestarts = 0
			return s.save()
		}
		next, err := s.pending()
		if err != nil && !errors.Is(err, errPendingInvalid) {
			return err
		}
		if err == nil && next != "" && next != s.Current && s.exists(next) {
			s.Current = next
			s.FailsGood = 0
			s.FailsBoot = 0
			s.MemRestarts = 0
			s.RollbackReason = ""
			if err := s.save(); err != nil {
				return err
			}
			return s.removePending()
		}
		if err := s.removePending(); err != nil {
			return err
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
	if s.Current != s.LastGood {
		if err := s.discardSelfUpdate(); err != nil {
			return err
		}
	}
	s.RollbackReason = reason
	if s.Current != s.LastGood {
		switch {
		case s.LastGood != "" && s.exists(s.LastGood):
			s.Bad = s.Current
			s.Current = s.LastGood
			s.FailsGood = 0
			s.FailsBoot = 0
			s.MemRestarts = 0
		case s.Current != s.embedded && s.exists(s.embedded):
			s.Bad = s.Current
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

// previous — версия, на которую вернёт ручной откат: lastGood, а если уже на ней — prevGood.
func (s *slots) previous() string {
	next := s.LastGood
	if s.Current == s.LastGood {
		next = s.PrevGood
	}
	if next == "" || next == s.Current || !s.exists(next) {
		return ""
	}
	return next
}

// Info — то, что нужно странице и ядру о версиях (читается из versions/state.json без блокировок).
type Info struct{ Current, LastGood, PrevGood, Bad, Previous string }

// ReadInfo читает состояние версий; Previous — куда вернёт откат ("" — некуда).
func ReadInfo(p api.Paths) Info {
	s := &slots{p: p}
	if b, err := os.ReadFile(filepath.Join(p.Versions, "state.json")); err == nil {
		_ = json.Unmarshal(b, &s.slotState)
	}
	s.embedded = s.EmbeddedSeen // её двоичный файл — установленный exe, не слот; считаем существующей
	return Info{Current: s.Current, LastGood: s.LastGood, PrevGood: s.PrevGood, Bad: s.Bad, Previous: s.previous()}
}

// RollbackOffline — `remoteagents rollback`, когда ядро не запущено: тот же результат, что у отката по запросу ядра
// (current = предыдущая версия, конфиг возвращается на поколение, которое она читает). Возвращает версию-цель.
func RollbackOffline(ctx context.Context, p api.Paths, self, embeddedVersion string, log api.Logger) (string, error) {
	run, err := lockFile(filepath.Join(p.State, api.LockRun))
	if err != nil {
		return "", fmt.Errorf("supervise: running: сторож запущен, но ядро не отвечает; откат через страницу или после остановки (%w)", err)
	}
	defer run()
	unlock, err := lockOperation(ctx, p)
	if err != nil {
		return "", err
	}
	defer unlock()
	s, err := loadSlots(ctx, p, self, embeddedVersion, false)
	if err != nil {
		return "", err
	}
	next := s.previous()
	if next == "" {
		return "", ErrNoPrevious
	}
	if err := s.discardSelfUpdate(); err != nil {
		return "", err
	}
	if err := s.removePending(); err != nil {
		return "", err
	}
	s.Bad = s.Current
	s.Current = next
	s.RollbackReason = "manual rollback"
	s.FailsGood, s.FailsBoot, s.MemRestarts, s.Stopped = 0, 0, 0, ""
	if err := s.save(); err != nil {
		return "", err
	}
	s.alignConfigLocked(ctx, log)
	return next, nil
}

// ErrNoPrevious: откатываться некуда (сравнивать через errors.Is).
var ErrNoPrevious = errors.New("supervise: no-previous: предыдущей версии нет")

func (s *slots) removePending() error {
	return removeFile(filepath.Join(s.p.Versions, "pending.json"))
}

func (s *slots) prune() error {
	// Keep the pending snapshot valid until deletion finishes: Stage and
	// pending-slot promotion use the same operation lock.
	unlock, err := lockFile(filepath.Join(s.p.State, api.LockOp))
	if err != nil {
		return fmt.Errorf("supervise: op-lock: %w", err)
	}
	defer unlock()

	pending, err := s.pending()
	if err != nil && !errors.Is(err, errPendingInvalid) {
		return err
	}
	entries, err := os.ReadDir(s.p.Versions)
	if err != nil {
		return err
	}
	var names []string
	for _, e := range entries {
		if e.IsDir() && versionName.MatchString(e.Name()) && !strings.HasSuffix(e.Name(), ".tmp") {
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
