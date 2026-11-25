package cleanup

import (
	"bytes"
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"remoteagents/internal/api"
)

type platformSteps interface {
	lock(path string) (func(), error)
	removeProcess(ctx context.Context, t api.Trace) error
	checkProcess(ctx context.Context, t api.Trace) bool

	removeAdapter(ctx context.Context, name string) error
	checkAdapter(ctx context.Context, name string) bool

	removeRoute(ctx context.Context, dest, iface string) error
	checkRoute(ctx context.Context, dest, iface string) bool

	removeRule(ctx context.Context, prio, table string) error
	checkRule(ctx context.Context, prio, table string) bool

	removeFirewall(ctx context.Context, name string) error
	checkFirewall(ctx context.Context, name string) bool
}

var currentPlatformSteps platformSteps = &defaultPlatformSteps{}

func (c *Cleaner) activeTraces() ([]api.Trace, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	traces, err := c.read()
	if err != nil {
		return nil, err
	}
	type key struct {
		kind string
		id   string
	}
	var order []key
	latest := map[key]api.Trace{}

	for _, t := range traces {
		k := key{kind: t.Kind, id: t.ID}
		if _, exists := latest[k]; !exists {
			order = append(order, k)
		}
		latest[k] = t
	}

	var active []api.Trace
	for _, k := range order {
		t := latest[k]
		if t.Phase != "done" {
			active = append(active, t)
		}
	}
	return active, nil
}

func (c *Cleaner) Run(ctx context.Context, reason string) []string {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	var issues []string
	if reason != "startup" && reason != "exit" && reason != "crash" && reason != "uninstall" {
		return []string{"cleanup: reason: invalid reason"}
	}
	unlock, err := currentPlatformSteps.lock(filepath.Join(c.p.State, api.LockCleanup))
	if err != nil {
		return []string{fmt.Sprintf("cleanup: busy: %v", err)}
	}
	defer unlock()

	active, err := c.activeTraces()
	if err != nil {
		return []string{fmt.Sprintf("cleanup: read: %v", err)}
	}

	// 1. Stop ra-core process first if active
	for _, t := range active {
		if t.Kind == "process" && (t.Owner == "singbox" || strings.Contains(t.ID, "ra-core") || strings.Contains(t.Data["exe"], "ra-core")) {
			if err := currentPlatformSteps.removeProcess(ctx, t); err != nil {
				issues = append(issues, fmt.Sprintf("cleanup: stop ra-core: %v", err))
			} else {
				if err := c.Done(t.Kind, t.ID); err != nil {
					issues = append(issues, err.Error())
				}
			}
			time.Sleep(100 * time.Millisecond)
		}
	}

	active, err = c.activeTraces()
	if err != nil {
		return append(issues, fmt.Sprintf("cleanup: read: %v", err))
	}

	// 2. Remove traces in reverse order
	for i := len(active) - 1; i >= 0; i-- {
		t := active[i]
		if err := ctx.Err(); err != nil {
			issues = append(issues, err.Error())
			break
		}
		if err := c.validate(t); err != nil {
			issues = append(issues, err.Error())
			continue
		}
		if t.Keep && reason != "uninstall" {
			continue
		}

		var removeErr error
		switch t.Kind {
		case "process":
			removeErr = currentPlatformSteps.removeProcess(ctx, t)
		case "listener":
			addr := t.Data["addr"]
			deadline := time.Now().Add(500 * time.Millisecond)
			for isPortListening(ctx, addr) && time.Now().Before(deadline) {
				time.Sleep(50 * time.Millisecond)
			}
			if isPortListening(ctx, addr) {
				removeErr = fmt.Errorf("listener %s still open", addr)
			}
		case "tmp":
			path := t.Data["path"]
			if c.isSafeTmpPath(path) {
				removeErr = os.RemoveAll(path)
			} else {
				removeErr = fmt.Errorf("unsafe tmp path: %s", path)
			}
		case "adapter":
			name := t.Data["name"]
			removeErr = currentPlatformSteps.removeAdapter(ctx, name)
		case "route":
			dest := t.Data["dest"]
			iface := t.Data["iface"]
			removeErr = currentPlatformSteps.removeRoute(ctx, dest, iface)
		case "rule":
			prio := t.Data["prio"]
			table := t.Data["table"]
			removeErr = currentPlatformSteps.removeRule(ctx, prio, table)
		case "hosts":
			marker := t.Data["marker"]
			removeErr = c.removeHostsBlock(marker)
		case "firewall":
			name := t.Data["name"]
			removeErr = currentPlatformSteps.removeFirewall(ctx, name)
		case "autostart":
			if reason == "uninstall" {
				removeErr = c.removeAutostart(ctx, t)
			}
		case "proxy":
			removeErr = c.removeProxy(t)
		case "dns":
			if currentPlatformSteps.checkAdapter(ctx, t.Data["iface"]) {
				removeErr = fmt.Errorf("dns: adapter still exists")
			}
		case "nrpt":
			removeErr = fmt.Errorf("nrpt: unsupported on %s", runtime.GOOS)
		default:
			removeErr = fmt.Errorf("unsupported trace kind")
		}

		if removeErr == nil {
			switch t.Kind {
			case "process":
				if currentPlatformSteps.checkProcess(ctx, t) {
					removeErr = fmt.Errorf("process still present or identity unverifiable")
				}
			case "adapter":
				if currentPlatformSteps.checkAdapter(ctx, t.Data["name"]) {
					removeErr = fmt.Errorf("adapter still present")
				}
			case "route":
				if currentPlatformSteps.checkRoute(ctx, t.Data["dest"], t.Data["iface"]) {
					removeErr = fmt.Errorf("route still present or query failed")
				}
			case "rule":
				if currentPlatformSteps.checkRule(ctx, t.Data["prio"], t.Data["table"]) {
					removeErr = fmt.Errorf("rule still present or query failed")
				}
			case "firewall":
				if currentPlatformSteps.checkFirewall(ctx, t.Data["name"]) {
					removeErr = fmt.Errorf("firewall still present or query failed")
				}
			}
		}
		if removeErr == nil {
			if err := c.Done(t.Kind, t.ID); err != nil {
				issues = append(issues, err.Error())
			}
		} else {
			issues = append(issues, fmt.Sprintf("cleanup: %s/%s: %v", t.Kind, t.ID, removeErr))
		}
	}

	// 4. Check actual physical state
	checkIssues := c.Check(ctx)
	issues = append(issues, checkIssues...)

	return issues
}

func (c *Cleaner) Check(ctx context.Context) []string {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	if err := ctx.Err(); err != nil {
		return []string{fmt.Sprintf("cleanup: context: %v", err)}
	}

	active, err := c.activeTraces()
	if err != nil {
		return []string{fmt.Sprintf("cleanup: read: %v", err)}
	}

	var issues []string
	for _, t := range active {
		if t.Keep {
			continue
		}
		switch t.Kind {
		case "process":
			if currentPlatformSteps.checkProcess(ctx, t) {
				issues = append(issues, fmt.Sprintf("cleanup: process %s still running (%s)", t.Data["pid"], t.Data["exe"]))
			}
		case "listener":
			if isPortListening(ctx, t.Data["addr"]) {
				issues = append(issues, fmt.Sprintf("cleanup: listener %s still open", t.Data["addr"]))
			}
		case "tmp":
			if pathExists(t.Data["path"]) {
				issues = append(issues, fmt.Sprintf("cleanup: tmp exists: %s", t.Data["path"]))
			}
		case "adapter":
			if currentPlatformSteps.checkAdapter(ctx, t.Data["name"]) {
				issues = append(issues, fmt.Sprintf("cleanup: adapter exists: %s", t.Data["name"]))
			}
		case "route":
			if currentPlatformSteps.checkRoute(ctx, t.Data["dest"], t.Data["iface"]) {
				issues = append(issues, fmt.Sprintf("cleanup: route exists: %s dev %s", t.Data["dest"], t.Data["iface"]))
			}
		case "rule":
			if currentPlatformSteps.checkRule(ctx, t.Data["prio"], t.Data["table"]) {
				issues = append(issues, fmt.Sprintf("cleanup: rule exists: %s %s", t.Data["prio"], t.Data["table"]))
			}
		case "hosts":
			if checkHostsMarker(t.Data["marker"]) {
				issues = append(issues, fmt.Sprintf("cleanup: hosts marker exists: %s", t.Data["marker"]))
			}
		case "proxy", "nrpt", "autostart":
			issues = append(issues, fmt.Sprintf("cleanup: %s: requires reconciliation", t.Kind))
		case "dns":
			if currentPlatformSteps.checkAdapter(ctx, t.Data["iface"]) {
				issues = append(issues, "cleanup: dns adapter exists")
			}
		case "firewall":
			if currentPlatformSteps.checkFirewall(ctx, t.Data["name"]) {
				issues = append(issues, fmt.Sprintf("cleanup: firewall exists: %s", t.Data["name"]))
			}
		}
	}
	return issues
}

func (c *Cleaner) isSafeTmpPath(p string) bool {
	if p == "" {
		return false
	}
	if p == c.hostsTempPath() {
		return true
	}
	resolved, err := filepath.EvalSymlinks(filepath.Dir(p))
	if err != nil {
		return os.IsNotExist(err) && !pathExists(p) && filepath.IsAbs(p) && strings.HasPrefix(filepath.Clean(p), c.p.Tmp+string(os.PathSeparator))
	}
	p = filepath.Join(resolved, filepath.Base(p))
	cleanP := filepath.Clean(p)
	cleanTmp := filepath.Clean(c.p.Tmp)
	cleanHome, err := filepath.EvalSymlinks(c.p.Home)
	if err != nil {
		return false
	}
	if rel, err := filepath.Rel(cleanP, cleanHome); err == nil && (rel == "." || (rel != ".." && !strings.HasPrefix(rel, ".."+string(os.PathSeparator)))) {
		return false
	}
	if cleanP == cleanHome || cleanP == "/" || cleanP == "." {
		return false
	}
	if filepath.VolumeName(cleanP) != "" && cleanP == filepath.VolumeName(cleanP)+"\\" {
		return false
	}
	relTmp, err := filepath.Rel(cleanTmp, cleanP)
	if err == nil && !strings.HasPrefix(relTmp, "..") && relTmp != "." {
		return true
	}
	tempDir := filepath.Clean(os.TempDir())
	relTemp, err := filepath.Rel(tempDir, cleanP)
	if err == nil && !strings.HasPrefix(relTemp, "..") {
		first := strings.SplitN(relTemp, string(os.PathSeparator), 2)[0]
		if strings.HasPrefix(first, "ra3-") {
			return true
		}
	}
	return false
}

func isPortListening(ctx context.Context, addr string) bool {
	if addr == "" {
		return false
	}
	target := addr
	if strings.HasPrefix(target, ":") {
		target = "127.0.0.1" + target
	}
	var lc net.ListenConfig
	listener, err := lc.Listen(ctx, "tcp", target)
	if err != nil {
		return true
	}
	_ = listener.Close()
	return false
}

func pathExists(path string) bool {
	if path == "" {
		return false
	}
	_, err := os.Stat(path)
	return err == nil || !os.IsNotExist(err)
}

func hostsPath() string {
	if runtime.GOOS == "windows" {
		sysRoot := os.Getenv("SystemRoot")
		if sysRoot == "" {
			sysRoot = `C:\Windows`
		}
		return filepath.Join(sysRoot, "System32", "drivers", "etc", "hosts")
	}
	return "/etc/hosts"
}

func checkHostsMarker(marker string) bool {
	if marker == "" {
		return false
	}
	content, err := os.ReadFile(hostsPath())
	if err != nil {
		return true
	}
	trimmedMarker := strings.TrimSpace(strings.TrimPrefix(marker, "#"))
	return bytes.Contains(content, []byte(trimmedMarker))
}

func (c *Cleaner) hostsTempPath() string {
	return hostsPath() + ".ra3-" + c.instance + ".tmp"
}

func (c *Cleaner) removeHostsBlock(marker string) error {
	if marker == "" {
		return nil
	}
	path := hostsPath()
	content, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	trimmedMarker := strings.TrimSpace(strings.TrimPrefix(marker, "#"))
	if !bytes.Contains(content, []byte(trimmedMarker)) {
		return nil
	}
	lines := strings.Split(string(content), "\n")
	var newLines []string
	inBlock := false

	for _, line := range lines {
		trimmedLine := strings.TrimSpace(line)
		if trimmedLine == "# "+trimmedMarker+" begin" {
			inBlock = true
			continue
		}
		if inBlock {
			if trimmedLine == "# "+trimmedMarker+" end" {
				inBlock = false
				continue
			}
			continue
		}
		newLines = append(newLines, line)
	}

	if inBlock {
		return fmt.Errorf("hosts: unterminated block")
	}
	newContent := []byte(strings.Join(newLines, "\n"))
	if bytes.Contains(newContent, []byte(trimmedMarker)) {
		return fmt.Errorf("hosts: marker remains in malformed block")
	}
	tmpFile := c.hostsTempPath()
	const tmpID = "hosts-rewrite"
	if err := c.Intent(api.Trace{Kind: "tmp", ID: tmpID, Owner: "cleanup", Data: map[string]string{"path": tmpFile}}); err != nil {
		return err
	}
	// The intent survives a crash; normal failures remove the staging file now.
	defer func() {
		if err := os.Remove(tmpFile); err == nil || os.IsNotExist(err) {
			_ = c.Done("tmp", tmpID)
		}
	}()
	f, err := os.OpenFile(tmpFile, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0644) //nolint:gosec // hosts is public
	if err != nil {
		return err
	}
	if err := c.Applied("tmp", tmpID, nil, nil); err != nil {
		_ = f.Close()
		return err
	}
	_, err = f.Write(newContent)
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
	if err := os.Rename(tmpFile, path); err != nil {
		return err
	}
	if checkHostsMarker(marker) {
		return fmt.Errorf("hosts: marker remains after replacement")
	}
	return nil
}

func (c *Cleaner) removeAutostart(ctx context.Context, t api.Trace) error {
	if c.plat == nil {
		return fmt.Errorf("autostart: platform unavailable")
	}
	spec := c.plat.Autostart(filepath.Join(c.p.Bin, "remoteagents"), c.p.Home, c.instance[:8])
	if spec.Path == "" || spec.Path != t.Data["path"] || spec.Kind != t.Data["kind"] {
		return fmt.Errorf("autostart: ownership mismatch")
	}
	if len(spec.Remove) > 0 {
		if err := exec.CommandContext(ctx, spec.Remove[0], spec.Remove[1:]...).Run(); err != nil {
			return err
		}
	}
	err := os.Remove(spec.Path)
	if os.IsNotExist(err) {
		return nil
	}
	return err
}
func (c *Cleaner) removeProxy(t api.Trace) error {
	return fmt.Errorf("proxy: unsupported on %s; settings preserved", runtime.GOOS)
}

func (c *Cleaner) validate(t api.Trace) error {
	tag := "ra3-" + c.instance[:8]
	owned := func(s string) bool {
		return s == tag || strings.HasPrefix(s, tag+"-") || strings.HasPrefix(s, "ra3_"+c.instance[:8])
	}
	// macOS assigns utun numbers itself. Only an applied trace belonging to
	// this instance authorizes the otherwise untagged interface name.
	ownedInterface := func(name string) bool {
		if owned(name) {
			return true
		}
		if runtime.GOOS != "darwin" || t.Instance != c.instance || t.Phase != "applied" || !strings.HasPrefix(name, "utun") {
			return false
		}
		number := strings.TrimPrefix(name, "utun")
		n, err := strconv.ParseUint(number, 10, 32)
		if err != nil || strconv.FormatUint(n, 10) != number {
			return false
		}
		iface, err := net.InterfaceByName(name)
		if err != nil {
			// An already removed interface needs no system mutation.
			interfaces, queryErr := net.Interfaces()
			if queryErr != nil {
				return false
			}
			for _, candidate := range interfaces {
				if candidate.Name == name {
					return false
				}
			}
			return true
		}
		return t.Data["ifindex"] == strconv.Itoa(iface.Index)
	}
	switch t.Kind {
	case "adapter":
		if !ownedInterface(t.Data["name"]) {
			return fmt.Errorf("cleanup: ownership: adapter")
		}
	case "route":
		if !owned(t.Data["iface"]) {
			return fmt.Errorf("cleanup: ownership: route")
		}
	case "dns":
		if !ownedInterface(t.Data["iface"]) {
			return fmt.Errorf("cleanup: ownership: dns")
		}
	case "rule":
		if t.Data["table"] != "ra3_"+c.instance[:8] || t.Data["prio"] == "" {
			return fmt.Errorf("cleanup: ownership: rule")
		}
	case "firewall":
		if !owned(t.Data["name"]) {
			return fmt.Errorf("cleanup: ownership: firewall")
		}
	case "hosts":
		if t.Data["marker"] != "# "+tag {
			return fmt.Errorf("cleanup: ownership: hosts")
		}
	}
	return nil
}

type defaultPlatformSteps struct{}

func (d *defaultPlatformSteps) removeProcess(ctx context.Context, t api.Trace) error {
	return fmt.Errorf("cleanup: unsupported: removeProcess")
}

func (d *defaultPlatformSteps) checkProcess(ctx context.Context, t api.Trace) bool {
	return false
}

func (d *defaultPlatformSteps) removeAdapter(ctx context.Context, name string) error {
	return fmt.Errorf("cleanup: unsupported: removeAdapter")
}

func (d *defaultPlatformSteps) checkAdapter(ctx context.Context, name string) bool {
	if name == "" {
		return false
	}
	_, err := net.InterfaceByName(name)
	return err == nil
}

func (d *defaultPlatformSteps) removeRoute(ctx context.Context, dest, iface string) error {
	return fmt.Errorf("cleanup: unsupported: removeRoute")
}

func (d *defaultPlatformSteps) checkRoute(ctx context.Context, dest, iface string) bool {
	return false
}

func (d *defaultPlatformSteps) removeRule(ctx context.Context, prio, table string) error {
	return fmt.Errorf("cleanup: unsupported: removeRule")
}

func (d *defaultPlatformSteps) checkRule(ctx context.Context, prio, table string) bool {
	return false
}

func (d *defaultPlatformSteps) removeFirewall(ctx context.Context, name string) error {
	return fmt.Errorf("cleanup: unsupported: removeFirewall")
}

func (d *defaultPlatformSteps) checkFirewall(ctx context.Context, name string) bool {
	return false
}

func (d *defaultPlatformSteps) lock(path string) (func(), error) {
	return nil, fmt.Errorf("cleanup: unsupported: locking")
}
