package supervise

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
	"time"

	"remoteagents/internal/api"
	"remoteagents/internal/cleanup"
	"remoteagents/internal/config"
	"remoteagents/internal/journal"

	"remoteagents/internal/platform"
)

type execProcess struct {
	cmd          *exec.Cmd
	tree         *commandTree
	started      time.Time
	done         chan struct{}
	exitCode     int
	stdoutWriter *io.PipeWriter
	stderrWriter *io.PipeWriter
	mu           sync.Mutex
}

func (p *execProcess) PID() int {
	if p.cmd != nil && p.cmd.Process != nil {
		return p.cmd.Process.Pid
	}
	return 0
}

func (p *execProcess) Started() time.Time {
	return p.started
}

func (p *execProcess) Done() <-chan struct{} {
	return p.done
}

func (p *execProcess) ExitCode() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.exitCode
}

func (p *execProcess) Stop(ctx context.Context) error {
	select {
	case <-p.done:
		return nil
	default:
	}
	if p.cmd == nil || p.cmd.Process == nil {
		return nil
	}
	stopProcessGroup(p.cmd)
	timer := time.NewTimer(5 * time.Second)
	defer timer.Stop()

	select {
	case <-p.done:
		return nil
	case <-timer.C:
	case <-ctx.Done():
	}

	p.tree.kill(p.cmd)
	_ = p.cmd.Process.Kill()
	_ = p.stdoutWriter.Close()
	_ = p.stderrWriter.Close()
	select {
	case <-p.done:
		return nil
	case <-time.After(2 * time.Second):
		return fmt.Errorf("supervise: stop-timeout: process did not exit")
	}
}

func startProcess(ctx context.Context, pr api.Procs, log api.Logger, exe string, args []string, dir string) (api.Process, io.ReadCloser, io.ReadCloser, error) {
	stdoutR, stdoutW := io.Pipe()
	stderrR, stderrW := io.Pipe()

	if pr != nil {
		spec := api.ProcSpec{
			Name:   "core",
			Path:   exe,
			Args:   args,
			Dir:    dir,
			Stdout: stdoutW,
			Stderr: stderrW,
		}
		p, err := pr.Start(ctx, spec)
		if err == nil {
			go func() {
				select {
				case <-p.Done():
				case <-ctx.Done():
				}
				_ = stdoutW.Close()
				_ = stderrW.Close()
			}()
			return p, stdoutR, stderrR, nil
		}
		_ = stdoutW.Close()
		_ = stderrW.Close()
		_ = stdoutR.Close()
		_ = stderrR.Close()
		return nil, nil, nil, err
	}

	tr, err := cleanup.New(api.NewPaths(dir), log, platform.Current())
	if err != nil {
		_ = stdoutR.Close()
		_ = stdoutW.Close()
		_ = stderrR.Close()
		_ = stderrW.Close()
		return nil, nil, nil, err
	}
	id := fmt.Sprintf("core-%d", time.Now().UnixNano())
	if err := tr.Intent(api.Trace{Kind: "process", ID: id, Instance: tr.Instance(), Owner: "supervise", Data: map[string]string{"exe": exe, "home": dir}}); err != nil {
		_ = stdoutR.Close()
		_ = stdoutW.Close()
		_ = stderrR.Close()
		_ = stderrW.Close()
		return nil, nil, nil, err
	}

	cmd := exec.CommandContext(ctx, exe, args...)
	tree := prepareCommand(cmd)
	cmd.Cancel = func() error {
		tree.kill(cmd)
		_ = stdoutW.Close()
		_ = stderrW.Close()
		return cmd.Process.Kill()
	}
	cmd.Dir = dir
	cmd.Stdout = stdoutW
	cmd.Stderr = stderrW

	if err := cmd.Start(); err != nil {
		_ = tr.Done("process", id)
		_ = stdoutR.Close()
		_ = stderrR.Close()
		_ = stdoutW.Close()
		_ = stderrW.Close()
		return nil, nil, nil, err
	}

	started, traceErr := processStarted(cmd)
	if traceErr == nil {
		traceErr = tr.Applied("process", id, map[string]string{"pid": strconv.Itoa(cmd.Process.Pid), "start": started.UTC().Format(time.RFC3339Nano)}, nil)
	}
	err = tree.attach(cmd)
	if traceErr != nil {
		err = traceErr
	}
	if err != nil {
		tree.kill(cmd)
		_ = cmd.Process.Kill()
		_ = stdoutR.Close()
		_ = stderrR.Close()
		_ = cmd.Wait()
		_ = tr.Done("process", id)
		_ = stdoutW.Close()
		_ = stderrW.Close()
		return nil, nil, nil, err
	}

	ep := &execProcess{
		cmd:          cmd,
		tree:         tree,
		started:      started,
		done:         make(chan struct{}),
		stdoutWriter: stdoutW,
		stderrWriter: stderrW,
	}

	go func() {
		err := cmd.Wait()
		tree.kill(cmd)
		_ = stdoutW.Close()
		_ = stderrW.Close()
		ep.mu.Lock()
		if err != nil {
			var exitErr *exec.ExitError
			if errors.As(err, &exitErr) {
				ep.exitCode = exitErr.ExitCode()
			} else {
				ep.exitCode = 1
			}
		} else {
			ep.exitCode = 0
		}
		ep.mu.Unlock()
		_ = tr.Done("process", id)
		close(ep.done)
	}()

	return ep, stdoutR, stderrR, nil
}

func rotateSelfUpdate(ctx context.Context, p api.Paths) error {
	target := filepath.Join(p.Bin, executableName())
	candidate := target + ".new"
	if st, err := os.Lstat(candidate); errors.Is(err, os.ErrNotExist) {
		return nil
	} else if err != nil {
		return err
	} else if !st.Mode().IsRegular() {
		return fmt.Errorf("supervise: self-update-invalid: candidate is not a regular file")
	}
	if _, err := binaryVersion(ctx, candidate); err != nil {
		return fmt.Errorf("supervise: self-update-version: %w", err)
	}
	// Preserve the old embedded under its version before .prev can be replaced.
	source := target
	previous := target + ".prev"
	if _, err := os.Lstat(target); errors.Is(err, os.ErrNotExist) {
		// Resume a rotation interrupted between target -> .prev and .new -> target.
		source = previous
	} else if err != nil {
		return err
	}
	if _, err := os.Lstat(source); errors.Is(err, os.ErrNotExist) {
		// Постоянного exe ещё нет (первый запуск со старого пути): просто ставим кандидата.
		return replaceFile(candidate, target)
	}
	version, err := binaryVersion(ctx, source)
	if err != nil {
		return fmt.Errorf("supervise: archive-version: %w", err)
	}
	archive := &slots{p: p}
	if err := archive.archive(version, source); err != nil {
		return err
	}
	// Free the installed name: Windows cannot replace a running executable,
	// but can rename it. Keep that executable as the fallback until promotion.
	if source == target {
		if err := replaceFile(target, previous); err != nil {
			return err
		}
	}
	if err := replaceFile(candidate, target); err != nil {
		if restoreErr := replaceFile(previous, target); restoreErr != nil {
			return errors.Join(err, fmt.Errorf("supervise: self-update-restore: %w", restoreErr))
		}
		return err
	}
	return nil
}

func binaryVersion(parent context.Context, self string) (string, error) {
	v, err := binaryOutput(parent, self, "version")
	if err != nil {
		return "", err
	}
	v = strings.TrimSpace(v)
	if !versionName.MatchString(v) {
		return "", fmt.Errorf("supervise: version: invalid version")
	}
	return v, nil
}

// binarySchema — формат конфига, который читает версия (`version --json`, поле schema). Старые сборки поля
// не знают: для них 1 (поколения конфига до появления схемы).
func binarySchema(parent context.Context, self string) int {
	out, err := binaryOutput(parent, self, "version", "--json")
	if err != nil {
		return 1
	}
	var v struct {
		Schema int `json:"schema"`
	}
	if json.Unmarshal([]byte(out), &v) != nil || v.Schema < 1 {
		return 1
	}
	return v.Schema
}

func binaryOutput(parent context.Context, self string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(parent, 2*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, self, args...)
	tree := prepareCommand(cmd)
	// A broken executable must not consume unlimited memory or keep inherited
	// pipes open beyond the command deadline and WaitDelay.
	var out versionOutput
	cmd.Stdout = &out
	cmd.Stderr = io.Discard
	if err := cmd.Start(); err != nil {
		return "", err
	}
	err := tree.attach(cmd)
	if err != nil {
		tree.kill(cmd)
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		return "", err
	}
	err = cmd.Wait()
	tree.kill(cmd)
	if err != nil {
		return "", err
	}
	return out.String(), nil
}

type versionOutput struct{ buf bytes.Buffer }

func (b *versionOutput) String() string { return b.buf.String() }

func (b *versionOutput) Write(p []byte) (int, error) {
	if len(p) > 512-b.buf.Len() {
		return 0, fmt.Errorf("supervise: version-size: excessive output")
	}
	return b.buf.Write(p)
}

// commandTree also closes the Windows Job on cancellation, rather than waiting
// for inherited stdout/stderr handles to close before terminating descendants.
type commandTree struct {
	mu      sync.Mutex
	release func()
	killed  bool
}

func prepareCommand(cmd *exec.Cmd) *commandTree {
	tree := &commandTree{}
	setSysProcAttr(cmd)
	cmd.WaitDelay = time.Second
	cmd.Cancel = func() error { tree.kill(cmd); return cmd.Process.Kill() }
	return tree
}

func (t *commandTree) attach(cmd *exec.Cmd) error {
	release, err := attachProcess(cmd)
	if err != nil {
		return err
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	t.release = sync.OnceFunc(release)
	if t.killed {
		t.release()
	}
	return nil
}

func (t *commandTree) kill(cmd *exec.Cmd) {
	t.mu.Lock()
	t.killed = true
	if t.release != nil {
		t.release()
	}
	t.mu.Unlock()
	killProcessGroup(cmd)
}

func runCleanup(ctx context.Context, p api.Paths, log api.Logger, reason string) {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 30*time.Second)
	defer cancel()
	// pf-якорь галочки (macOS): смерть/убийство/выход ядра никогда не оставляют блок (ГЛАВНОЕ ТРЕБОВАНИЕ: выключение всегда работает)
	if err := platform.ReleasePF(ctx, p.State); err != nil {
		log.Warn("supervise: pf-release", "err", err.Error())
	}
	cl, err := cleanup.New(p, log, platform.Current())
	if err == nil && cl != nil {
		if issues := cl.Run(ctx, reason); len(issues) != 0 {
			log.Warn("supervise: cleanup-incomplete", "issues", issues)
		}
	} else if err != nil {
		log.Warn("supervise: cleanup-unavailable", "err", err)
	}
}

func checkSwitchExpire(p api.Paths, log api.Logger) (bool, error) {
	unlock, err := lockFile(filepath.Join(p.State, api.LockOp))
	if err != nil {
		return false, err
	}
	defer unlock()
	path := filepath.Join(p.Config, "switch.json")
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	var sw struct {
		From, To string
		Deadline time.Time
	}
	if err := json.Unmarshal(b, &sw); err != nil {
		return false, err
	}
	if !versionName.MatchString(sw.To) || (sw.From != "" && !versionName.MatchString(sw.From)) {
		return false, fmt.Errorf("supervise: switch-invalid: invalid generation")
	}
	// Commit writes lastgood before removing switch.json. Finish an interrupted
	// commit before considering expiry, so a confirmed generation is not reverted.
	lastGood, err := os.ReadFile(filepath.Join(p.Config, "lastgood"))
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return false, err
	}
	if sw.To != "" && sw.To == strings.TrimSpace(string(lastGood)) {
		if err := removeFile(path); err != nil {
			return false, err
		}
		return false, nil
	}
	if sw.Deadline.IsZero() {
		return false, fmt.Errorf("supervise: switch-invalid: missing deadline")
	}
	if time.Now().Before(sw.Deadline) {
		return false, nil
	}
	if sw.From == "" {
		err = removeFile(filepath.Join(p.Config, "current"))
	} else {
		err = atomicWrite(filepath.Join(p.Config, "current"), []byte(sw.From), 0600)
	}
	if err != nil {
		return false, err
	}
	if err = removeFile(path); err != nil {
		return false, err
	}
	reason := config.RecordRollback(p, sw.From, sw.To, "expire")
	log.Warn("config.expire", "from", sw.To, "to", sw.From, "reason", reason)
	return true, nil
}

// alignConfig: после отката версии конфиг должен быть таким, какой откатываемая версия читает. Версия-цель сама
// сообщает свою схему (`version --json`); если current записан более новой схемой — возврат на совместимое поколение.
func (s *slots) alignConfig(ctx context.Context, log api.Logger) {
	unlock, err := lockOperation(ctx, s.p)
	if err != nil {
		log.Warn("supervise: config-align-lock", "err", err)
		return
	}
	defer unlock()
	s.alignConfigLocked(ctx, log)
}

func (s *slots) alignConfigLocked(ctx context.Context, log api.Logger) {
	schema := binarySchema(ctx, s.path(s.Current))
	gen, err := config.CompatRollback(s.p, schema, log)
	if err != nil {
		log.Warn("supervise: config-align", "err", err)
	} else if gen != "" {
		log.Warn(fmt.Sprintf("откат версии на %s: конфиг возвращён на %s (схема не новее %d)", s.Current, gen, schema))
	}
}

// forceVPNOff — запрос «выключить VPN любой ценой» к циклу сторожа.
var forceVPNOff = make(chan struct{}, 1)

const vpnOffMarker = "vpn-off.once"

// ForceVPNOff — выключить VPN, даже если ядро не отвечает: маркер на следующий запуск + немедленное убийство ядра сторожем
// (cleanup снимает sing-box, адаптеры и фильтры). Ничего постоянного не остаётся: маркер читается и стирается ядром при старте.
func ForceVPNOff(p api.Paths) error {
	if err := os.MkdirAll(p.State, 0700); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(p.State, vpnOffMarker), []byte("1"), 0600); err != nil {
		return err
	}
	select {
	case forceVPNOff <- struct{}{}:
	default:
	}
	return nil
}

// TakeVPNOff — ядро при старте: был ли маркер принудительного выключения (маркер стирается).
func TakeVPNOff(p api.Paths) bool {
	return os.Remove(filepath.Join(p.State, vpnOffMarker)) == nil
}

// OnUI вызывается, когда ядро сообщило адрес страницы (сообщение "ui"); nil — не нужно.
var OnUI func(url string)

// OnLocked вызывается один раз, когда сторож взял блокировку единственного экземпляра (значок в трее и т. п.).
var OnLocked func()

// OnStart вызывается после взятия блокировки, когда журнал сторожа открыт (установка на постоянный путь, ярлык).
var OnStart func(log api.Logger)

// Handover включает самообновление сторожа: когда новая версия признана хорошей, сторож записывает её на постоянный
// путь (bin/remoteagents) и выходит с кодом SupExitHandover; запускающий код стартует новый сторож с этого пути.
var Handover bool

// BinaryVersion — версия исполняемого файла (`<exe> version`).
func BinaryVersion(ctx context.Context, exe string) (string, error) { return binaryVersion(ctx, exe) }

// InstalledPath — постоянный путь сторожа.
func InstalledPath(p api.Paths) string { return filepath.Join(p.Bin, executableName()) }

// prepareHandover переносит staged-копию хорошей версии на постоянный путь и проверяет, что там именно она.
func prepareHandover(ctx context.Context, p api.Paths, want string) error {
	unlock, err := lockOperation(ctx, p)
	if err != nil {
		return err
	}
	defer unlock()
	if err := rotateSelfUpdate(ctx, p); err != nil {
		return err
	}
	got, err := binaryVersion(ctx, InstalledPath(p))
	if err != nil {
		return err
	}
	if got != want {
		return fmt.Errorf("на постоянном пути версия %s, ожидалась %s", got, want)
	}
	return nil
}

func Run(ctx context.Context, p api.Paths, log api.Logger, pr api.Procs, self string, mode api.Mode, args []string) (code int) {
	if log == nil {
		j, err := journal.New(p, api.StreamSup, journal.Options{MaxBytes: 5 << 20, Keep: 4})
		if err != nil {
			_, _ = fmt.Fprintln(os.Stderr, "supervise: journal-open: cannot open supervisor journal")
			return 1
		}
		defer func() {
			if err := j.Close(); err != nil {
				_, _ = fmt.Fprintln(os.Stderr, "supervise: journal-close: cannot close supervisor journal")
			}
		}()
		log = j
	}

	if err := os.MkdirAll(p.State, 0700); err != nil {
		log.Error("supervise: cannot create state directory", "err", err)
		return 1
	}

	lockPath := filepath.Join(p.State, api.LockRun)
	unlock, err := lockFile(lockPath)
	if err != nil {
		if errors.Is(err, api.ErrBusy) {
			log.Error("supervise: already-running", "path", lockPath)
			return api.SupExitRunning
		}
		log.Error("supervise: run-lock", "err", err)
		return 1
	}
	defer unlock()
	if OnLocked != nil {
		OnLocked()
	}
	if OnStart != nil {
		OnStart(log)
	}
	_ = os.Remove(filepath.Join(p.State, api.PauseFile)) // новый запуск программы: пауза снята

	// Любой выход сторожа (в том числе остановка по boot-failures и паника) —
	// сразу уборка: на ПК не остаются процессы, порты, lock/url-файлы.
	var sl *slots
	defer func() {
		reason := "exit"
		if r := recover(); r != nil {
			log.Error(fmt.Sprintf("supervise: panic: %v", r), "stack", string(debug.Stack()))
			code = 1
		}
		if (code != 0 && code != api.SupExitHandover) || (sl != nil && sl.Stopped != "") {
			reason = "crash"
		}
		runCleanup(ctx, p, log, reason)
		_ = os.Remove(filepath.Join(p.State, "webui.url")) // адрес страницы мёртвого ядра
	}()

	reset := false
	fast := false
	var coreArgs []string
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if !strings.HasPrefix(arg, "-") {
			coreArgs = append(coreArgs, arg)
			continue
		}
		name, value, assigned := strings.Cut(strings.TrimLeft(arg, "-"), "=")
		switch name {
		case "reset", "fast":
			on := !assigned || value == "true"
			if name == "reset" {
				reset = on
			} else {
				fast = on
			}
		case "safe", "no-tun", "no-channel", "no-singbox":
			// The Mode argument is authoritative for every child, including rollback.
		case "home", "rollback-reason":
			if !assigned {
				i++
			}
		default:
			coreArgs = append(coreArgs, arg)
		}
	}

	silenceTimeout := time.Duration(api.SilenceUnverifiedSec) * time.Second
	aliveTimeout := time.Duration(api.SilenceVerifiedSec) * time.Second
	if fast {
		silenceTimeout = 3 * time.Second
		aliveTimeout = 3 * time.Second
	}

	// Serialize every startup write with Stage, rollback and uninstall, including
	// executable rotation and the mode fixed for this supervisor's lifetime.
	s, err := initialize(ctx, p, self, mode, reset)
	sl = s
	if err != nil {
		if ctx.Err() != nil {
			return api.SupExitDone
		}
		log.Error("supervise: load slots failed", "err", err)
		return 1
	}

	if err := s.prune(); err != nil {
		log.Warn("supervise: prune", "err", err)
	}

	if s.Stopped != "" {
		log.Warn(fmt.Sprintf("supervise: stopped: %s", s.Stopped))
		return api.SupExitDone
	}

	for {
		select {
		case <-ctx.Done():
			return api.SupExitDone
		default:
		}

		if s.Stopped != "" {
			log.Warn(fmt.Sprintf("supervise: stopped: %s", s.Stopped))
			return api.SupExitDone
		}

		if _, err := checkSwitchExpire(p, log); err != nil {
			if errors.Is(err, api.ErrBusy) {
				select {
				case <-ctx.Done():
					return api.SupExitDone
				case <-time.After(100 * time.Millisecond):
					continue
				}
			}
			log.Error("supervise: switch-check", "err", err)
			return 1
		}

		if !s.exists(s.Current) {
			log.Warn(fmt.Sprintf("supervise: slot %s missing from disk, resetting to embedded", s.Current))
			if err := s.resetMissing(ctx); err != nil {
				log.Error("supervise: slot-reset", "err", err)
				return 1
			}
		}

		exe := s.path(s.Current)

		var cmdArgs []string
		cmdArgs = append(cmdArgs, "run", "--home", p.Home)
		if mode.Safe {
			cmdArgs = append(cmdArgs, "--safe")
		}
		if mode.NoTun {
			cmdArgs = append(cmdArgs, "--no-tun")
		}
		if mode.NoChannel {
			cmdArgs = append(cmdArgs, "--no-channel")
		}
		if mode.NoSingbox {
			cmdArgs = append(cmdArgs, "--no-singbox")
		}
		cmdArgs = append(cmdArgs, coreArgs...)
		if s.RollbackReason != "" {
			cmdArgs = append(cmdArgs, "--rollback-reason", s.RollbackReason)
		}

		childCtx, childCancel := context.WithCancel(ctx)
		proc, stdoutReader, stderrReader, err := startProcess(childCtx, pr, log, exe, cmdArgs, p.Home)
		if err != nil {
			childCancel()
			if ctx.Err() != nil {
				runCleanup(ctx, p, log, "exit")
				return api.SupExitDone
			}
			log.Error("supervise: failed to start core process", "err", err, "exe", exe)
			runCleanup(ctx, p, log, "crash")
			if err := s.transition(ctx, 1, false, false, "core start failed"); err != nil {
				log.Error("supervise: state-write", "err", err)
				return 1
			}
			if s.Stopped != "" {
				log.Warn(fmt.Sprintf("3 падения → stopped (%s)", s.Stopped))
				return api.SupExitDone
			}
			select {
			case <-ctx.Done():
				return api.SupExitDone
			case <-time.After(500 * time.Millisecond):
			}
			continue
		}

		startTime := time.Now()
		lastSignalTime := startTime
		goodSeen := false
		silenceFired := false
		exitFinal := false
		rollbackMsg := false
		rollbackReasonStr := ""
		ranLong := false
		configRestart := false
		handoverReq := false

		type message struct {
			T       string `json:"t"`
			Version string `json:"version"`
			Final   bool   `json:"final"`
			Reason  string `json:"reason"`
			URL     string `json:"url"`
		}
		messages := make(chan message, 64)
		readCtx, readCancel := context.WithCancel(ctx)
		var protocolErr error
		stop := func() {
			stopCtx, stopCancel := context.WithTimeout(ctx, 7*time.Second)
			defer stopCancel()
			if err := proc.Stop(stopCtx); err != nil {
				protocolErr = fmt.Errorf("supervise: core-stop: %w", err)
				childCancel()
				readCancel()
				_ = stdoutReader.Close()
				_ = stderrReader.Close()
			}
		}
		stdoutDone := make(chan struct{})
		go func() {
			defer close(stdoutDone)
			defer close(messages)
			defer func() { _ = stdoutReader.Close() }()
			scanner := bufio.NewScanner(stdoutReader)
			for scanner.Scan() {
				var msg message
				if json.Unmarshal(scanner.Bytes(), &msg) != nil {
					log.Info("core stdout: " + scanner.Text())
					continue
				}
				select {
				case messages <- msg:
				case <-readCtx.Done():
					return
				}
			}
			if err := scanner.Err(); err != nil && !errors.Is(err, io.ErrClosedPipe) {
				log.Error("supervise: stdout-read", "err", err)
			}
		}()
		handle := func(msg message) {
			if silenceFired || configRestart || protocolErr != nil {
				return
			}
			switch msg.T {
			case "ui":
				if OnUI != nil && msg.URL != "" {
					OnUI(msg.URL)
				}
			case api.MsgGood:
				if msg.Version != s.Current {
					log.Warn("supervise: good-version-mismatch")
					return
				}
				if !goodSeen {
					goodSeen = true
					startTime = time.Now()
					protocolErr = s.confirmGood(ctx)
					log.Info("supervise: good", "version", msg.Version)
					lastSignalTime = time.Now()
					if protocolErr == nil && Handover && s.Current != s.embedded {
						if err := prepareHandover(ctx, p, s.Current); err != nil {
							log.Warn("supervise: handover отложен", "err", err)
						} else {
							log.Info("supervise: handover: сторож переходит на версию "+s.Current, "version", s.Current)
							handoverReq = true
						}
					}
				}
			case api.MsgAlive:
				lastSignalTime = time.Now()
			case api.MsgExit:
				exitFinal = exitFinal || msg.Final
			case api.MsgRollback:
				rollbackMsg = true
				rollbackReasonStr = msg.Reason
			}
		}

		stderrDone := make(chan struct{})
		go func() {
			defer close(stderrDone)
			defer func() { _ = stderrReader.Close() }()
			scanner := bufio.NewScanner(stderrReader)
			scanner.Buffer(make([]byte, 0, 64<<10), 1<<20)
			var tail []string
			defer func() {
				select {
				case <-proc.Done():
				case <-time.After(2 * time.Second):
					return
				}
				if c := proc.ExitCode(); c != 0 && len(tail) > 0 {
					log.Error(fmt.Sprintf("supervise: core crashed (код %d); хвост stderr:\n%s", c, strings.Join(tail, "\n")))
				}
			}()
			for scanner.Scan() {
				line := scanner.Text()
				log.Info("core stderr: " + line)
				if tail = append(tail, line); len(tail) > 40 {
					tail = tail[1:]
				}
			}
			if err := scanner.Err(); err != nil && !errors.Is(err, io.ErrClosedPipe) {
				log.Error("supervise: stderr-read", "err", err)
			}
		}()
		// Allow EOF and buffered protocol messages to drain after exit. A producer
		// retaining pipes cannot keep these readers alive indefinitely.
		readersDone := make(chan struct{})
		go func() {
			defer close(readersDone)
			select {
			case <-proc.Done():
				timer := time.NewTimer(time.Second)
				defer timer.Stop()
				select {
				case <-stdoutDone:
					select {
					case <-stderrDone:
					case <-timer.C:
					case <-readCtx.Done():
					}
				case <-timer.C:
				case <-readCtx.Done():
				}
			case <-ctx.Done():
			case <-readCtx.Done():
			}
			_ = stderrReader.Close()
			_ = stdoutReader.Close()
		}()
		procDone := proc.Done()
		tickInterval := 1000 * time.Millisecond
		if fast {
			tickInterval = 100 * time.Millisecond
		}
		ticker := time.NewTicker(tickInterval)
		switchTick := 0

	processLoop:
		for {
			select {
			case msg, ok := <-messages:
				if ok {
					handle(msg)
					if protocolErr != nil || handoverReq {
						stop()
						break processLoop
					}
				} else {
					messages = nil
				}
			case <-procDone:
				break processLoop
			case <-forceVPNOff:
				// Принудительное выключение VPN (трей, ядро не отвечает): убиваем ядро сразу, без ожидания (отменённый контекст),
				// cleanup снимает sing-box и адаптеры, новое ядро стартует с выключенным VPN (маркер). Падением не считается.
				log.Warn("supervise: vpn-force-off, killing core")
				configRestart = true
				dead, deadCancel := context.WithCancel(ctx)
				deadCancel()
				if err := proc.Stop(dead); err != nil {
					log.Warn("supervise: vpn-force-off: core did not exit", "err", err.Error())
				}
				break processLoop
			case <-ctx.Done():
				ticker.Stop()
				stop()
				childCancel()
				readCancel()
				_ = stdoutReader.Close()
				_ = stderrReader.Close()
				<-stdoutDone
				<-stderrDone
				<-readersDone
				runCleanup(ctx, p, log, "exit")
				return api.SupExitDone
			case <-ticker.C:
				now := time.Now()
				if s.Current != s.LastGood {
					if now.Sub(startTime) > silenceTimeout {
						silenceFired = true
						log.Warn(fmt.Sprintf("тишина %d с: версия %s не прислала good за %d с", int(silenceTimeout.Seconds()), s.Current, int(silenceTimeout.Seconds())))
						stop()
						break processLoop
					}
				} else {
					if now.Sub(lastSignalTime) > aliveTimeout {
						silenceFired = true
						log.Warn(fmt.Sprintf("тишина %d с: версия %s не прислала alive за %d с", int(aliveTimeout.Seconds()), s.Current, int(aliveTimeout.Seconds())))
						stop()
						break processLoop
					}
				}

				if goodSeen && !ranLong && now.Sub(startTime) >= time.Duration(api.LongRunSec)*time.Second {
					ranLong = true
					protocolErr = s.clearFailures(ctx)
					if protocolErr != nil {
						stop()
						break processLoop
					}
				}

				switchTick++
				if fast || switchTick%5 == 0 {
					expired, err := checkSwitchExpire(p, log)
					if err != nil && !errors.Is(err, api.ErrBusy) {
						protocolErr = err
						stop()
						break processLoop
					}
					if expired {
						configRestart = true
						log.Warn("supervise: config switch deadline expired, stopping core for restart")
						stop()
						break processLoop
					}
				}
			}
		}

		ticker.Stop()
		if messages != nil {
			for msg := range messages {
				handle(msg)
			}
		}
		<-stdoutDone
		readCancel()
		_ = stdoutReader.Close()
		<-stderrDone
		<-readersDone
		childCancel()
		if ctx.Err() != nil {
			runCleanup(ctx, p, log, "exit")
			return api.SupExitDone
		}
		if handoverReq && protocolErr == nil {
			runCleanup(ctx, p, log, "exit")
			return api.SupExitHandover
		}
		if goodSeen && !ranLong && time.Since(startTime) >= time.Duration(api.LongRunSec)*time.Second && protocolErr == nil {
			protocolErr = s.clearFailures(ctx)
		}
		if protocolErr != nil {
			runCleanup(ctx, p, log, "crash")
			log.Error("supervise: state-write", "err", protocolErr)
			return 1
		}
		exitCode := proc.ExitCode()

		if !silenceFired && !configRestart && exitFinal && exitCode == api.ExitOK {
			runCleanup(ctx, p, log, "exit")
			log.Info("supervise: final exit requested by core")
			return api.SupExitDone
		}

		runCleanup(ctx, p, log, "crash")
		if configRestart {
			continue
		}

		var reason string
		if silenceFired {
			if s.Current == s.LastGood {
				reason = fmt.Sprintf("version %s did not send alive in %d s", s.Current, int(aliveTimeout.Seconds()))
			} else {
				reason = fmt.Sprintf("version %s did not bring the channel up in %d s", s.Current, int(silenceTimeout.Seconds()))
			}
		} else if rollbackMsg && exitCode == api.ExitRestart {
			reason = rollbackReasonStr
		} else if exitCode == api.ExitOK {
			reason = fmt.Sprintf("version %s exited with code 0 unrequested", s.Current)
		} else {
			reason = fmt.Sprintf("version %s crashed, exit code %d", s.Current, exitCode)
		}

		prevCurrent := s.Current
		prevLastGood := s.LastGood
		unverifiedBefore := (s.Current != s.LastGood)

		if err := s.transition(ctx, exitCode, silenceFired, rollbackMsg, reason); err != nil {
			log.Error("supervise: transition error", "err", err)
			return 1
		}

		if s.Current != prevCurrent {
			s.alignConfig(ctx, log)
		}
		if unverifiedBefore && s.Current == prevLastGood && prevLastGood != "" {
			log.Info(fmt.Sprintf("непроверенная → lastGood: откат с %s на %s (%s)", prevCurrent, s.Current, reason))
		}
		if s.Stopped != "" {
			log.Warn(fmt.Sprintf("3 падения → stopped (%s)", s.Stopped))
			return api.SupExitDone
		}

		if err := s.prune(); err != nil {
			log.Warn("supervise: prune", "err", err)
		}
	}
}
