package singbox

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"time"

	"remoteagents/internal/api"
)

// FindBinary follows settings.find_singbox, without downloading/installing anything.
func FindBinary(cfg *api.Config, p api.Paths) (string, error) {
	name := "sing-box"
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	var raw object
	_ = json.Unmarshal(cfg.Raw, &raw)
	candidates := []string{str(obj(raw["transport"])["singBoxPath"]), filepath.Join(p.Bin, name), filepath.Join(p.Home, "transport-bin", name)}
	bundle, _ := filepath.Glob(filepath.Join(p.Home, "bundle", "*", "transport", name))
	sort.Sort(sort.Reverse(sort.StringSlice(bundle)))
	candidates = append(candidates, bundle...)
	for _, path := range candidates {
		if st, err := os.Stat(path); err == nil && st.Mode().IsRegular() {
			return path, nil
		}
	}
	if path, err := exec.LookPath(name); err == nil {
		return path, nil
	}
	return "", fmt.Errorf("singbox: бинарник не найден")
}
func ownCopy(exe string, p api.Paths, log api.Logger) string {
	name := "ralab-core"
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	dst := filepath.Join(p.Home, "runtime", name)
	err := func() error {
		src, err := os.Open(exe)
		if err != nil {
			return err
		}
		defer src.Close()
		st, err := src.Stat()
		if err != nil {
			return err
		}
		if old, e := os.Stat(dst); e == nil && old.Size() == st.Size() {
			return nil
		}
		if err = os.MkdirAll(filepath.Dir(dst), 0700); err != nil {
			return err
		}
		f, err := os.OpenFile(dst+".tmp", os.O_CREATE|os.O_TRUNC|os.O_WRONLY, st.Mode().Perm()|0700)
		if err != nil {
			return err
		}
		_, err = io.Copy(f, src)
		closeErr := f.Close()
		if err != nil {
			return err
		}
		if closeErr != nil {
			return closeErr
		}
		return os.Rename(dst+".tmp", dst)
	}()
	if err != nil {
		if log != nil {
			log.Warn("copy.failed", "error", err)
		}
		return exe
	}
	return dst
}

// freePorts holds every socket until allocation is complete, including TCP-only fallbacks (v2).
func freePorts(n int) ([]int, error) {
	held := []io.Closer{}
	defer func() {
		for _, c := range held {
			c.Close()
		}
	}()
	ports, tcpOnly := []int{}, []int{}
	for i := 0; i < max(64, n*20) && len(ports) < n; i++ {
		t, err := net.Listen("tcp4", "127.0.0.1:0")
		if err != nil {
			continue
		}
		held = append(held, t)
		port := t.Addr().(*net.TCPAddr).Port
		u, err := net.ListenPacket("udp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
		if err != nil {
			tcpOnly = append(tcpOnly, port)
			continue
		}
		held = append(held, u)
		ports = append(ports, port)
	}
	for _, p := range tcpOnly {
		if len(ports) < n {
			ports = append(ports, p)
		}
	}
	if len(ports) != n {
		return nil, fmt.Errorf("singbox: свободных портов %d из %d", len(ports), n)
	}
	return ports, nil
}
func localProxies(ctx context.Context, cfg *api.Config) []int {
	var raw object
	_ = json.Unmarshal(cfg.Raw, &raw)
	ports := []int{10808, 7890, 7891}
	for _, v := range arr(obj(raw["transport"])["localProxies"]) {
		if p := num(v); p > 0 {
			ports = append(ports, p)
		}
	}
	found := []int{}
	seen := map[int]bool{}
	for _, p := range ports {
		if seen[p] {
			continue
		}
		seen[p] = true
		d := net.Dialer{Timeout: time.Second}
		c, err := d.DialContext(ctx, "tcp4", fmt.Sprintf("127.0.0.1:%d", p))
		if err == nil {
			c.Close()
			found = append(found, p)
		}
	}
	return found
}
