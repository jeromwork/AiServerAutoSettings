package supervise

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"remoteagents/internal/api"
	"remoteagents/internal/cleanup"

	"remoteagents/internal/platform"
)

type defaultLogger struct{}

func (d *defaultLogger) Info(event string, kv ...any)  {}
func (d *defaultLogger) Warn(event string, kv ...any)  {}
func (d *defaultLogger) Error(event string, kv ...any) {}
func (d *defaultLogger) With(component string) api.Logger {
	return d
}
func (d *defaultLogger) Secret(value string) {}
func (d *defaultLogger) Writer(stream, source string) io.WriteCloser {
	return discardCloser{}
}
func (d *defaultLogger) Drops() int64 { return 0 }

type discardCloser struct{}

func (discardCloser) Write(p []byte) (int, error) { return len(p), nil }
func (discardCloser) Close() error                { return nil }

type execProcess struct {
	cmd          *exec.Cmd
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

	killProcessGroup(p.cmd)
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

func startProcess(ctx context.Context, pr api.Procs, exe string, args []string, dir string) (api.Process, io.ReadCloser, io.ReadCloser, error) {
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
				<-p.Done()
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

	tr, err := cleanup.New(api.NewPaths(dir), &defaultLogger{}, platform.Current())
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
	cmd.WaitDelay = time.Second
	cmd.Dir = dir
	cmd.Stdout = stdoutW
	cmd.Stderr = stderrW
	setSysProcAttr(cmd)

	if err := cmd.Start(); err != nil {
		_ = tr.Done("process", id)
		_ = stdoutR.Close()
		_ = stderrR.Close()
		_ = stdoutW.Close()
		_ = stderrW.Close()
		return nil, nil, nil, err
	}

	started := time.Now()
	traceErr := tr.Applied("process", id, map[string]string{"pid": strconv.Itoa(cmd.Process.Pid), "start": started.UTC().Format(time.RFC3339Nano)}, nil)
	release, err := attachProcess(cmd)
	if traceErr != nil {
		if release != nil {
			release()
		}
		err = traceErr
	}
	if err != nil {
		killProcessGroup(cmd)
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
		started:      started,
		done:         make(chan struct{}),
		stdoutWriter: stdoutW,
		stderrWriter: stderrW,
	}

	go func() {
		err := cmd.Wait()
		release()
		killProcessGroup(cmd)
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

func rotateSelfUpdate(p api.Paths) error {
	target := filepath.Join(p.Bin, executableName())
	candidate := target + ".new"
	if _, err := os.Stat(candidate); errors.Is(err, os.ErrNotExist) {
		return nil
	} else if err != nil {
		return err
	}
	// Free the installed name: Windows cannot replace a running executable,
	// but can rename it. Keep that executable as the fallback until promotion.
	previous := target + ".prev"
	if err := replaceFile(target, previous); err != nil {
		return err
	}
	if err := replaceFile(candidate, target); err != nil {
		if restoreErr := replaceFile(previous, target); restoreErr != nil {
			return errors.Join(err, fmt.Errorf("supervise: self-update-restore: %w", restoreErr))
		}
		return err
	}
	return nil
}

func getEmbeddedVersion(parent context.Context, self string) string {
	ctx, cancel := context.WithTimeout(parent, 2*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, self, "version")
	if out, err := cmd.Output(); err == nil {
		v := strings.TrimSpace(string(out))
		if versionName.MatchString(v) {
			return v
		}
	}
	if fi, err := os.Stat(self); err == nil {
		return fmt.Sprintf("build-%d", fi.ModTime().Unix())
	}
	return "embedded"
}

func runCleanup(ctx context.Context, p api.Paths, log api.Logger, reason string) {
	cl, err := cleanup.New(p, log, platform.Current())
	if err == nil && cl != nil {
		_ = cl.Run(ctx, reason)
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
	// Commit writes lastgood before removing switch.json. Finish an interrupted
	// commit before considering expiry, so a confirmed generation is not reverted.
	lastGood, err := os.ReadFile(filepath.Join(p.Config, "lastgood"))
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return false, err
	}
	if sw.To != "" && sw.To == strings.TrimSpace(string(lastGood)) {
		if err := os.Remove(path); err != nil {
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
	if sw.From != "" && !versionName.MatchString(sw.From) {
		return false, fmt.Errorf("supervise: switch-invalid: invalid generation")
	}
	if sw.From == "" {
		err = os.Remove(filepath.Join(p.Config, "current"))
		if errors.Is(err, os.ErrNotExist) {
			err = nil
		}
	} else {
		err = atomicWrite(filepath.Join(p.Config, "current"), []byte(sw.From), 0600)
	}
	if err != nil {
		return false, err
	}
	if err = os.Remove(path); err != nil {
		return false, err
	}
	log.Warn("supervise: config switch expired")
	return true, nil
}

func Run(ctx context.Context, p api.Paths, log api.Logger, pr api.Procs, self string, mode api.Mode, args []string) int {
	if log == nil {
		log = &defaultLogger{}
	}

	if err := os.MkdirAll(p.State, 0700); err != nil {
		log.Error("supervise: cannot create state directory", "err", err)
		return 1
	}

	lockPath := filepath.Join(p.State, api.LockRun)
	unlock, err := lockFile(lockPath)
	if err != nil {
		log.Error("supervise: already-running", "path", lockPath, "err", err)
		return api.SupExitRunning
	}
	defer unlock()

	if err := rotateSelfUpdate(p); err != nil {
		log.Error("supervise: self-update", "err", err)
		return 1
	}

	reset := false
	fast := false
	var coreArgs []string
	for _, arg := range args {
		switch arg {
		case "--reset":
			reset = true
		case "--fast":
			fast = true
		default:
			coreArgs = append(coreArgs, arg)
		}
	}

	silenceTimeout := time.Duration(api.SilenceUnverifiedSec) * time.Second
	if fast {
		silenceTimeout = 3 * time.Second
	}

	embeddedVersion := getEmbeddedVersion(ctx, self)
	s, err := loadSlots(p, self, embeddedVersion, reset)
	if err != nil {
		log.Error("supervise: load slots failed", "err", err)
		return 1
	}

	_ = s.prune()

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
			log.Warn("supervise: switch-check", "err", err)
		}

		if !s.exists(s.Current) {
			log.Warn(fmt.Sprintf("supervise: slot %s missing from disk, resetting to embedded", s.Current))
			s.Current = s.embedded
			_ = s.save()
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
		for i := 0; i < len(coreArgs); i++ {
			arg := coreArgs[i]
			if arg == "--rollback-reason" {
				i++
				continue
			}
			if strings.HasPrefix(arg, "--rollback-reason=") {
				continue
			}
			cmdArgs = append(cmdArgs, arg)
		}
		if s.RollbackReason != "" {
			cmdArgs = append(cmdArgs, "--rollback-reason", s.RollbackReason)
		}

		proc, stdoutReader, stderrReader, err := startProcess(ctx, pr, exe, cmdArgs, p.Home)
		if err != nil {
			log.Error("supervise: failed to start core process", "err", err, "exe", exe)
			if err := s.transition(1, false, false, "core start failed"); err != nil {
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

		type message struct {
			T       string `json:"t"`
			Version string `json:"version"`
			Final   bool   `json:"final"`
			Reason  string `json:"reason"`
		}
		messages := make(chan message, 64)
		readCtx, readCancel := context.WithCancel(ctx)
		stdoutDone := make(chan struct{})
		go func() {
			defer close(stdoutDone)
			defer close(messages)
			defer func() { _ = stdoutReader.Close() }()
			scanner := bufio.NewScanner(stdoutReader)
			for scanner.Scan() {
				var msg message
				if json.Unmarshal(scanner.Bytes(), &msg) != nil {
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
		var protocolErr error
		handle := func(msg message) {
			switch msg.T {
			case api.MsgGood:
				if !goodSeen {
					goodSeen = true
					startTime = time.Now()
					s.markGood()
					protocolErr = s.save()
					if s.Current != s.embedded && protocolErr == nil {
						protocolErr = copyBinary(s.path(s.Current), filepath.Join(p.Bin, executableName()+".new"))
					}
					log.Info("supervise: good", "version", msg.Version)
				}
				lastSignalTime = time.Now()
			case api.MsgAlive:
				lastSignalTime = time.Now()
			case api.MsgExit:
				exitFinal = msg.Final
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
			for scanner.Scan() {
				line := scanner.Text()
				log.Info("core stderr: " + line)
			}
			if err := scanner.Err(); err != nil && !errors.Is(err, io.ErrClosedPipe) {
				log.Error("supervise: stderr-read", "err", err)
			}
		}()
		// Readers are closed after every child, including descendants retaining pipes.
		go func() {
			select {
			case <-proc.Done():
			case <-ctx.Done():
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
				} else {
					messages = nil
				}
			case <-procDone:
				break processLoop
			case <-ctx.Done():
				ticker.Stop()
				_ = proc.Stop(ctx)
				readCancel()
				_ = stdoutReader.Close()
				_ = stderrReader.Close()
				<-stdoutDone
				<-stderrDone
				runCleanup(context.WithoutCancel(ctx), p, log, "exit")
				return api.SupExitDone
			case <-ticker.C:
				now := time.Now()
				if !goodSeen {
					if now.Sub(startTime) > silenceTimeout {
						silenceFired = true
						log.Warn(fmt.Sprintf("тишина %d с: версия %s не прислала good за %d с", int(silenceTimeout.Seconds()), s.Current, int(silenceTimeout.Seconds())))
						_ = proc.Stop(ctx)
						break processLoop
					}
				} else {
					if now.Sub(lastSignalTime) > silenceTimeout {
						silenceFired = true
						log.Warn(fmt.Sprintf("тишина %d с: версия %s не прислала alive за %d с", int(silenceTimeout.Seconds()), s.Current, int(silenceTimeout.Seconds())))
						_ = proc.Stop(ctx)
						break processLoop
					}
				}

				if goodSeen && !ranLong && now.Sub(startTime) >= time.Duration(api.LongRunSec)*time.Second {
					ranLong = true
					s.FailsGood = 0
					_ = s.save()
				}

				switchTick++
				if fast || switchTick%5 == 0 {
					if expired, _ := checkSwitchExpire(p, log); expired {
						configRestart = true
						log.Warn("supervise: config switch deadline expired, stopping core for restart")
						_ = proc.Stop(ctx)
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
		if protocolErr != nil {
			runCleanup(context.WithoutCancel(ctx), p, log, "crash")
			log.Error("supervise: state-write", "err", protocolErr)
			return 1
		}
		exitCode := proc.ExitCode()

		if exitFinal && exitCode == api.ExitOK {
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
			reason = fmt.Sprintf("version %s did not bring the channel up in %d s", s.Current, int(silenceTimeout.Seconds()))
		} else if rollbackMsg {
			reason = rollbackReasonStr
		} else if exitCode == api.ExitOK {
			reason = fmt.Sprintf("version %s exited with code 0 unrequested", s.Current)
		} else {
			reason = fmt.Sprintf("version %s crashed, exit code %d", s.Current, exitCode)
		}

		prevCurrent := s.Current
		prevLastGood := s.LastGood
		unverifiedBefore := (s.Current != s.LastGood)

		if err := s.transition(exitCode, silenceFired, rollbackMsg, reason); err != nil {
			log.Error("supervise: transition error", "err", err)
			return 1
		}

		if unverifiedBefore && s.Current == prevLastGood && prevLastGood != "" {
			log.Info(fmt.Sprintf("непроверенная → lastGood: откат с %s на %s (%s)", prevCurrent, s.Current, reason))
		}
		if s.Stopped != "" {
			log.Warn(fmt.Sprintf("3 падения → stopped (%s)", s.Stopped))
			return api.SupExitDone
		}

		_ = s.prune()
	}
}
