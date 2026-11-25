package procs

import "os/exec"

func setCmdLine(cmd *exec.Cmd, line string) {
	if line != "" {
		cmd.SysProcAttr.CmdLine = line
	}
}
