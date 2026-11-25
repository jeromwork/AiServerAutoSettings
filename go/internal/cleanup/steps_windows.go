//go:build windows

package cleanup

import (
	"context"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf16"

	"golang.org/x/sys/windows"
	"remoteagents/internal/api"
)

// Only traced objects reach these steps. A failed query is never evidence that
// an object has disappeared: Check must retain the trace for reconciliation.
// NRPT, proxy and scheduled tasks need dispatch hooks in run.go; platformSteps
// currently exposes neither their traces nor a reason/context for restoration.
type windowsSteps struct{}

var _ platformSteps = (*windowsSteps)(nil)

func init() { currentPlatformSteps = &windowsSteps{} }

func (s *windowsSteps) lock(path string) (func(), error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	overlap := new(windows.Overlapped)
	h := windows.Handle(f.Fd())
	if err := windows.LockFileEx(h, windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, overlap); err != nil {
		_ = f.Close()
		return nil, err
	}
	return func() {
		_ = windows.UnlockFileEx(h, 0, 1, 0, overlap)
		_ = f.Close()
	}, nil
}

// Keep the handle open through termination so PID reuse cannot redirect a kill.
func windowsProcess(t api.Trace, terminate bool) (windows.Handle, error) {
	pid, err := strconv.ParseUint(t.Data["pid"], 10, 32)
	if err != nil || pid <= 4 || pid == uint64(os.Getpid()) {
		return 0, fmt.Errorf("cleanup: process: invalid or unsafe pid")
	}
	access := uint32(windows.PROCESS_QUERY_LIMITED_INFORMATION | windows.SYNCHRONIZE)
	if terminate {
		access |= windows.PROCESS_TERMINATE
	}
	h, err := windows.OpenProcess(access, false, uint32(pid))
	if errors.Is(err, windows.ERROR_INVALID_PARAMETER) {
		return 0, nil // No such PID.
	}
	if err != nil {
		return 0, fmt.Errorf("cleanup: process-query: %w", err)
	}
	matched, err := windowsProcessMatches(h, t)
	if err != nil || !matched {
		_ = windows.CloseHandle(h)
		return 0, err
	}
	return h, nil
}

func windowsProcessMatches(h windows.Handle, t api.Trace) (bool, error) {
	state, err := windows.WaitForSingleObject(h, 0)
	if err != nil {
		return false, err
	}
	if state == windows.WAIT_OBJECT_0 {
		return false, nil
	}
	buf := make([]uint16, 32768)
	n := uint32(len(buf))
	if err := windows.QueryFullProcessImageName(h, 0, &buf[0], &n); err != nil {
		return false, err
	}
	exe := windows.UTF16ToString(buf[:n])
	if !filepath.IsAbs(t.Data["exe"]) || !filepath.IsAbs(t.Data["home"]) {
		return false, fmt.Errorf("cleanup: process: missing absolute exe/home")
	}
	// Traced children may use system executables outside Home (ssh, shells).
	// Ownership here comes from the trace and exact exe/start identity.
	if !strings.EqualFold(filepath.Clean(exe), filepath.Clean(t.Data["exe"])) {
		return false, nil
	}
	var created, exited, kernel, user windows.Filetime
	if err := windows.GetProcessTimes(h, &created, &exited, &kernel, &user); err != nil {
		return false, err
	}
	started, err := time.Parse(time.RFC3339Nano, t.Data["start"])
	if err != nil {
		return false, fmt.Errorf("cleanup: process: invalid start identity")
	}
	return started.Equal(time.Unix(0, created.Nanoseconds())), nil
}

func (s *windowsSteps) checkProcess(ctx context.Context, t api.Trace) bool {
	if ctx.Err() != nil {
		return true
	}
	h, err := windowsProcess(t, false)
	if h != 0 {
		_ = windows.CloseHandle(h)
	}
	return err != nil || h != 0
}

func (s *windowsSteps) removeProcess(ctx context.Context, t api.Trace) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	h, err := windowsProcess(t, true)
	if err != nil || h == 0 {
		return err
	}
	defer func() { _ = windows.CloseHandle(h) }()
	pid, _ := strconv.ParseUint(t.Data["pid"], 10, 32)
	// A console-less caller may be unable to send CTRL_BREAK. In that case
	// continue to the bounded hard-stop path, rather than assuming success.
	_ = windows.GenerateConsoleCtrlEvent(windows.CTRL_BREAK_EVENT, uint32(pid))
	timer := time.NewTimer(500 * time.Millisecond)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		// Terminate by the already verified handle even after the deadline.
		_ = windows.TerminateProcess(h, 1)
		return ctx.Err()
	case <-timer.C:
	}
	matched, err := windowsProcessMatches(h, t)
	if err != nil || !matched {
		return err
	}
	// taskkill also terminates descendants; never select processes by name.
	err = exec.CommandContext(ctx, "taskkill.exe", "/F", "/T", "/PID", strconv.FormatUint(pid, 10)).Run()
	if err != nil {
		state, queryErr := windows.WaitForSingleObject(h, 0)
		if queryErr == nil && state == windows.WAIT_OBJECT_0 {
			return nil
		}
		_ = windows.TerminateProcess(h, 1)
		return fmt.Errorf("cleanup: process-tree: %w", err)
	}
	return nil
}

// Pass Unicode scripts as UTF-16LE, and quote every literal separately. No
// trace value is ever interpolated as PowerShell syntax or wildcard pattern.
func windowsPS(ctx context.Context, script string) (string, error) {
	units := utf16.Encode([]rune("$ErrorActionPreference='Stop'; " + script))
	buf := make([]byte, 2*len(units))
	for i, unit := range units {
		binary.LittleEndian.PutUint16(buf[2*i:], unit)
	}
	out, err := exec.CommandContext(ctx, "powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand", base64.StdEncoding.EncodeToString(buf)).Output()
	if err != nil {
		return "", fmt.Errorf("cleanup: powershell: %w", err)
	}
	return strings.TrimSpace(strings.TrimPrefix(string(out), "\xef\xbb\xbf")), nil
}

func windowsQuote(value string) string { return "'" + strings.ReplaceAll(value, "'", "''") + "'" }

var windowsOwnedName = regexp.MustCompile(`^ra3-[0-9a-f]{8}-(vpn|lan|[A-Za-z0-9_.-]+)$`)

func windowsAdapterQuery(name string) (string, error) {
	if !windowsOwnedName.MatchString(name) {
		return "", fmt.Errorf("cleanup: ownership: invalid adapter name")
	}
	return "$a=@(Get-NetAdapter -IncludeHidden | Where-Object { $_.Name -ceq " + windowsQuote(name) + " }); " +
		"if ($a.Count -gt 1) { throw 'ambiguous adapter' }; ", nil
}

func (s *windowsSteps) checkAdapter(ctx context.Context, name string) bool {
	query, err := windowsAdapterQuery(name)
	if err != nil {
		return true
	}
	out, err := windowsPS(ctx, query+"if ($a.Count) { 'present' }")
	return err != nil || out != ""
}

func (s *windowsSteps) removeAdapter(ctx context.Context, name string) error {
	query, err := windowsAdapterQuery(name)
	if err != nil {
		return err
	}
	for attempt := 0; attempt <= 3; attempt++ {
		out, err := windowsPS(ctx, query+"if ($a.Count) { if ($a[0].Status -eq 'Up') { 'up' } else { 'down' } }")
		if err != nil || out == "" {
			return err
		}
		if out != "up" || attempt == 3 {
			break
		}
		timer := time.NewTimer(2 * time.Second)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}
	}
	// Requery immediately before deletion, and resolve the exact PnP ID only
	// from the adapter whose full friendly name we just checked.
	_, err = windowsPS(ctx, query+`if ($a.Count) {
 $id=$a[0].PNPDeviceID; if (-not $id) { throw 'missing PnP identity' };
 $p=Get-PnpDevice -InstanceId $id;
 if ($p.FriendlyName -cne `+windowsQuote(name)+`) { throw 'adapter identity changed' };
 & pnputil.exe /remove-device $id;
 if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) { throw 'pnputil failed' }
}`)
	return err
}

func windowsRouteQuery(dest, iface string) (string, error) {
	if !windowsOwnedName.MatchString(iface) || dest == "" {
		return "", fmt.Errorf("cleanup: ownership: invalid route identity")
	}
	// Enumerate then compare exactly: cmdlet parameters may accept wildcards.
	return "$r=@(Get-NetRoute | Where-Object { $_.DestinationPrefix -ceq " + windowsQuote(dest) +
		" -and $_.InterfaceAlias -ceq " + windowsQuote(iface) + " }); ", nil
}

func (s *windowsSteps) removeRoute(ctx context.Context, dest, iface string) error {
	query, err := windowsRouteQuery(dest, iface)
	if err != nil {
		return err
	}
	_, err = windowsPS(ctx, query+"$r | Remove-NetRoute -Confirm:$false")
	return err
}

func (s *windowsSteps) checkRoute(ctx context.Context, dest, iface string) bool {
	query, err := windowsRouteQuery(dest, iface)
	if err != nil {
		return true
	}
	out, err := windowsPS(ctx, query+"if ($r.Count) { 'present' }")
	return err != nil || out != ""
}

func (s *windowsSteps) removeRule(_ context.Context, _, _ string) error {
	// The dispatcher passes Linux table/prio, not the Windows rule's name.
	return fmt.Errorf("cleanup: rule: Windows rule name unavailable; rule preserved")
}

func (s *windowsSteps) checkRule(_ context.Context, _, _ string) bool { return true }

func windowsFirewallQuery(name string) (string, error) {
	if !windowsOwnedName.MatchString(name) {
		return "", fmt.Errorf("cleanup: ownership: invalid firewall name")
	}
	return "$r=@(Get-NetFirewallRule | Where-Object { $_.DisplayName -ceq " + windowsQuote(name) + " }); ", nil
}

func (s *windowsSteps) removeFirewall(ctx context.Context, name string) error {
	query, err := windowsFirewallQuery(name)
	if err != nil {
		return err
	}
	// Delete the selected objects, rather than interpreting the name as a glob.
	_, err = windowsPS(ctx, query+"$r | Remove-NetFirewallRule")
	return err
}

func (s *windowsSteps) checkFirewall(ctx context.Context, name string) bool {
	query, err := windowsFirewallQuery(name)
	if err != nil {
		return true
	}
	out, err := windowsPS(ctx, query+"if ($r.Count) { 'present' }")
	return err != nil || out != ""
}
