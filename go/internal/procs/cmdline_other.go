//go:build !windows

package procs

import "os/exec"

func setCmdLine(*exec.Cmd, string) {}
