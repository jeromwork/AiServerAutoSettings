package update

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"time"
)

func (u *updater) Stage(ctx context.Context, candidate, version string) error {
	u.stageMu.Lock()
	defer u.stageMu.Unlock()
	// Only consume candidates created in this updater's temporary directory.
	candidate, err := filepath.Abs(candidate)
	if err != nil {
		return fail("candidate", "invalid path")
	}
	tmp, err := filepath.Abs(u.p.Tmp)
	if err != nil || filepath.Dir(candidate) != tmp {
		return fail("candidate", "candidate must be in Tmp")
	}
	defer func() { _ = os.Remove(candidate) }()
	if err := ctx.Err(); err != nil {
		return fail("cancelled", err.Error())
	}
	// Block C, C5: Checks before pending.json
	// 1. Size <= 100 MiB and non-empty.
	info, err := os.Lstat(candidate)
	if err != nil {
		return fail("candidate", "cannot stat candidate: "+err.Error())
	}
	if !info.Mode().IsRegular() {
		return fail("candidate", "not a regular file")
	}
	if info.Size() <= 0 || info.Size() > maxBinary {
		_ = os.Remove(candidate)
		return fail("size", fmt.Sprintf("binary size %d invalid", info.Size()))
	}

	// 2. Version matches VersionRe, slot directory does not exist yet.
	if !versionPattern.MatchString(version) {
		_ = os.Remove(candidate)
		return fail("version", "invalid version: "+version)
	}
	finalSlotDir := filepath.Join(u.p.Versions, version)
	if _, err := os.Lstat(finalSlotDir); !errors.Is(err, os.ErrNotExist) {
		_ = os.Remove(candidate)
		return fail("slot", "slot already exists: "+version)
	}

	// 3. Execution permissions.
	if err := os.Chmod(candidate, 0700); err != nil { // #nosec G302 -- authenticated candidate requires owner execute permission.
		_ = os.Remove(candidate)
		return fail("chmod", "cannot set candidate permissions: "+err.Error())
	}
	info, err = os.Stat(candidate)
	if err != nil || (runtime.GOOS != "windows" && (info.Mode()&0111 == 0)) {
		_ = os.Remove(candidate)
		return fail("perms", "candidate is not executable")
	}

	// 4. Run <cand> version --json (5s timeout) -> os/arch match, version matches.
	vctx, vcancel := context.WithTimeout(ctx, 5*time.Second)
	defer vcancel()
	vcmd := exec.CommandContext(vctx, candidate, "version", "--json")
	var output bytes.Buffer
	vcmd.Stdout = &boundedOutput{b: &output}
	vcmd.WaitDelay = time.Second
	err = vcmd.Run()
	out := output.Bytes()
	if err != nil {
		_ = os.Remove(candidate)
		return fail("version", "candidate version --json failed: "+err.Error())
	}
	var vi struct {
		Version string `json:"version"`
		OS      string `json:"os"`
		Arch    string `json:"arch"`
	}
	if err := json.Unmarshal(out, &vi); err != nil {
		_ = os.Remove(candidate)
		return fail("version", "invalid candidate version JSON: "+err.Error())
	}
	if vi.Version != version {
		_ = os.Remove(candidate)
		return fail("version", fmt.Sprintf("version mismatch: got %s, want %s", vi.Version, version))
	}
	if vi.OS != u.os || vi.Arch != u.arch {
		_ = os.Remove(candidate)
		return fail("platform", fmt.Sprintf("target mismatch: got %s/%s, want %s/%s", vi.OS, vi.Arch, u.os, u.arch))
	}

	// 5. Run <cand> config check --current --home <home> (10s timeout) -> exit code 0.
	cctx, ccancel := context.WithTimeout(ctx, 10*time.Second)
	defer ccancel()
	ccmd := exec.CommandContext(cctx, candidate, "config", "check", "--current", "--home", u.p.Home)
	ccmd.WaitDelay = time.Second
	if err := ccmd.Run(); err != nil {
		_ = os.Remove(candidate)
		return fail("config", "candidate rejected current config: "+err.Error())
	}

	// 6. Atomically: Tmp -> versions/<v>.tmp -> rename -> pending.json via .tmp + rename.
	if err := os.MkdirAll(u.p.Versions, 0700); err != nil {
		_ = os.Remove(candidate)
		return fail("versions", "cannot create versions directory: "+err.Error())
	}
	tmpSlotDir := filepath.Join(u.p.Versions, version+".tmp")
	if err := os.Mkdir(tmpSlotDir, 0700); err != nil {
		_ = os.Remove(candidate)
		return fail("slot", "cannot create temporary slot directory: "+err.Error())
	}

	binName := "remoteagents"
	if u.os == "windows" {
		binName += ".exe"
	}
	destBin := filepath.Join(tmpSlotDir, binName)

	var success, finalized bool
	defer func() {
		if !success {
			_ = os.Remove(candidate)
			_ = os.RemoveAll(tmpSlotDir)
			if finalized {
				_ = os.RemoveAll(finalSlotDir)
			}
			_ = os.Remove(filepath.Join(u.p.Versions, "pending.json.tmp"))
		}
	}()

	if err := moveOrCopyFile(candidate, destBin); err != nil {
		return fail("io", "cannot move candidate to slot: "+err.Error())
	}
	if err := os.Chmod(destBin, 0700); err != nil { // #nosec G302 -- authenticated candidate requires owner execute permission.
		return fail("chmod", "cannot set slot binary permissions: "+err.Error())
	}

	if err := os.Rename(tmpSlotDir, finalSlotDir); err != nil {
		return fail("slot", "cannot finalize slot directory: "+err.Error())
	}

	finalized = true

	pendingPath := filepath.Join(u.p.Versions, "pending.json")
	pendingTmp := filepath.Join(u.p.Versions, "pending.json.tmp")
	pendingDoc, err := json.Marshal(map[string]string{"dir": version})
	if err != nil {
		return fail("json", "cannot encode pending.json: "+err.Error())
	}
	pendingDoc = append(pendingDoc, '\n')
	if err := os.WriteFile(pendingTmp, pendingDoc, 0600); err != nil {
		return fail("pending", "cannot write pending.json.tmp: "+err.Error())
	}
	if err := os.Rename(pendingTmp, pendingPath); err != nil {
		return fail("pending", "cannot rename pending.json: "+err.Error())
	}

	success = true
	return nil
}

func moveOrCopyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer func() { _ = in.Close() }()
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer func() { _ = out.Close() }()
	if _, err := io.Copy(out, in); err != nil {
		return err
	}
	if err := out.Sync(); err != nil {
		return err
	}
	_ = in.Close()
	if err := out.Close(); err != nil {
		return err
	}
	return os.Remove(src)
}

// boundedOutput consumes excess output without allocating unbounded memory.
type boundedOutput struct{ b *bytes.Buffer }

func (w *boundedOutput) Write(p []byte) (int, error) {
	n := len(p)
	if left := maxMetadata - w.b.Len(); left > 0 {
		if len(p) > left {
			p = p[:left]
		}
		_, _ = w.b.Write(p)
	}
	return n, nil
}
