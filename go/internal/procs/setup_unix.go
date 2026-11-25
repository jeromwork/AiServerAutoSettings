//go:build linux || darwin

package procs

import (
	"os/exec"
	"sync"
	"syscall"
)

type platformState struct {
	releases *sync.Map
	pgid     int
	leader   *exec.Cmd
	reap     chan struct{}
	reaped   chan struct{}
	closed   bool
}

func newPlatformState() (platformState, error) {
	return platformState{releases: &sync.Map{}, reap: make(chan struct{}), reaped: make(chan struct{})}, nil
}

// Start holds m.mu: the first successful child is the single group leader.
func (m *manager) publishCmd(cmd *exec.Cmd) {
	if m.platform.pgid == 0 {
		m.platform.pgid = cmd.Process.Pid
		m.platform.leader = cmd
	}
}

func (m *manager) terminatePlatform() {
	m.mu.Lock()
	if !m.platform.closed {
		m.platform.closed = true
		if m.platform.pgid > 0 {
			// The unreaped leader reserves this PID/PGID, even after its exit.
			_ = syscall.Kill(-m.platform.pgid, syscall.SIGKILL)
		}
		close(m.platform.reap)
	}
	leader := m.platform.leader
	m.mu.Unlock()
	if leader != nil {
		<-m.platform.reaped
	}
}

// Report the leader's exit without reaping it. Otherwise a short-lived first
// child could lose the group's ID before the next Start, or allow PGID reuse.
func (m *manager) collectCmd(cmd *exec.Cmd) int {
	if cmd.SysProcAttr.Pgid == 0 {
		identity, err := inspectProcess(cmd.Process.Pid)
		if err != nil {
			return -1
		}
		return syscall.WaitStatus(identity.status).ExitStatus()
	}
	_ = cmd.Wait()
	m.releaseCmd(cmd)
	if cmd.ProcessState != nil {
		return cmd.ProcessState.ExitCode()
	}
	return -1
}

func (m *manager) reapLeader(cmd *exec.Cmd) {
	if cmd.SysProcAttr.Pgid == 0 {
		<-m.platform.reap
		_ = cmd.Wait()
		m.releaseCmd(cmd)
		close(m.platform.reaped)
	}
}

func sameLiveProcess(want processIdentity) bool {
	got, err := inspectProcess(want.pid)
	return err == nil && got.live && got.started.Equal(want.started)
}

// Never signal a shared PGID from Process.Stop. Snapshot only this still-live
// process's descendants, and recheck every PID's kernel birth time before use.
func (p *proc) rememberTree() {
	root := processIdentity{pid: p.pid, started: p.started}
	if !sameLiveProcess(root) {
		return
	}
	all := processTable()
	if !sameLiveProcess(root) {
		return
	}
	seen := make(map[int]bool)
	for _, old := range p.targets {
		seen[old.pid] = true
	}
	queue := []processIdentity{root}
	for len(queue) > 0 {
		next := queue[0]
		queue = queue[1:]
		if !seen[next.pid] {
			p.targets = append(p.targets, next)
			seen[next.pid] = true
		}
		if !sameLiveProcess(next) {
			continue
		}
		for _, candidate := range all {
			if candidate.ppid == next.pid && candidate.started.Compare(next.started) >= 0 {
				queue = append(queue, candidate)
			}
		}
	}
}

func (p *proc) signalTargets(sig syscall.Signal) {
	// Children first, so a dying parent cannot hide them by reparenting.
	for i := len(p.targets) - 1; i >= 0; i-- {
		target := p.targets[i]
		if sameLiveProcess(target) {
			_ = syscall.Kill(target.pid, sig)
		}
	}
}

func (p *proc) softStop() {
	p.rememberTree()
	p.signalTargets(syscall.SIGTERM)
}

func (p *proc) hardKill() {
	p.rememberTree()
	p.signalTargets(syscall.SIGKILL)
}

func (p *proc) cleanupExited() {
	// Only descendants captured by an earlier Stop/ctx are ours to finish.
	// A naturally completed process is never signaled, nor is its shared group.
	p.signalTargets(syscall.SIGKILL)
}
