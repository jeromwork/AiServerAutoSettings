package cleanup

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

type Report struct {
	Found     []string `json:"found,omitempty"`
	Removed   []string `json:"removed,omitempty"`
	Unremoved []string `json:"unremoved,omitempty"`
}

func (r Report) String() string {
	return fmt.Sprintf("found=%d removed=%d unremoved=%d", len(r.Found), len(r.Removed), len(r.Unremoved))
}

func ScanLeftovers(home string) (Report, error) {
	absHome, err := filepath.Abs(home)
	if err != nil || home == "" || filepath.Dir(absHome) == absHome {
		return Report{}, fmt.Errorf("cleanup: home: invalid home")
	}
	if runtime.GOOS == "windows" {
		vol := filepath.VolumeName(absHome)
		if vol != "" && (absHome == vol || absHome == vol+"\\" || absHome == vol+"/") {
			return Report{}, fmt.Errorf("cleanup: home: invalid home")
		}
	}

	bin := filepath.Join(absHome, "bin")
	return scanPlatformProcesses(absHome, bin)
}

func isSubpath(target, parent string) bool {
	if target == "" || parent == "" {
		return false
	}
	cleanTarget := filepath.Clean(target)
	cleanParent := filepath.Clean(parent)

	rel, err := filepath.Rel(cleanParent, cleanTarget)
	if err == nil && rel != "." && rel != ".." && !strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
		return true
	}

	if runtime.GOOS == "windows" {
		rel, err := filepath.Rel(strings.ToLower(cleanParent), strings.ToLower(cleanTarget))
		if err == nil && rel != "." && rel != ".." && !strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
			return true
		}
	}

	evalParent, errParent := filepath.EvalSymlinks(cleanParent)
	evalTarget, errTarget := filepath.EvalSymlinks(cleanTarget)
	if errParent == nil && errTarget == nil && (evalParent != cleanParent || evalTarget != cleanTarget) {
		rel, err := filepath.Rel(evalParent, evalTarget)
		if err == nil && rel != "." && rel != ".." && !strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
			return true
		}
		if runtime.GOOS == "windows" {
			rel, err := filepath.Rel(strings.ToLower(evalParent), strings.ToLower(evalTarget))
			if err == nil && rel != "." && rel != ".." && !strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
				return true
			}
		}
	}

	return false
}
