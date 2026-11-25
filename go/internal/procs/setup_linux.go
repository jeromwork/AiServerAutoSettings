package procs

import "syscall"

func setDeathSignal(attr *syscall.SysProcAttr) { attr.Pdeathsig = syscall.SIGKILL }
