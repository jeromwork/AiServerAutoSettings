//go:build windows

package platform

import (
	"fmt"
	"strings"
	"syscall"

	"remoteagents/internal/api"
)

// Autostart возвращает спецификацию автозапуска через schtasks (autostart.py 30–33).
func (p *stubPlatform) Autostart(binPath, home, inst8 string) api.AutostartSpec {
	if len(inst8) > 6 {
		inst8 = inst8[:6]
	}
	taskName := "RemoteAgents3"
	if inst8 != "" {
		taskName = fmt.Sprintf("RemoteAgents3-%s", inst8)
	}
	execArgs := "supervise --fallback " + syscall.EscapeArg(binPath+".prev")
	if home != "" {
		execArgs += " --home " + syscall.EscapeArg(home)
	}
	trCmd := syscall.EscapeArg(binPath) + " " + execArgs
	xmlContent := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>RemoteAgents3 Autostart</Description></RegistrationInfo>
  <Triggers><LogonTrigger><Enabled>true</Enabled></LogonTrigger></Triggers>
  <Principals><Principal id="Author"><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><AllowHardTerminate>true</AllowHardTerminate><StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable><IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand><Enabled>true</Enabled><Hidden>false</Hidden><RunOnlyIfIdle>false</RunOnlyIfIdle><WakeToRun>false</WakeToRun><ExecutionTimeLimit>PT0S</ExecutionTimeLimit><Priority>7</Priority>
    <RestartOnFailure><Interval>PT1M</Interval><Count>3</Count></RestartOnFailure>
  </Settings>
  <Actions Context="Author"><Exec><Command>%s</Command><Arguments>%s</Arguments></Exec></Actions>
</Task>`, escapeXML(binPath), escapeXML(execArgs))
	return api.AutostartSpec{
		Kind:    "schtasks",
		Path:    taskName,
		Content: xmlContent,
		Install: []string{"schtasks", "/Create", "/TN", taskName, "/SC", "ONLOGON", "/RL", "HIGHEST", "/F", "/TR", trCmd},
		Remove:  []string{"schtasks", "/Delete", "/TN", taskName, "/F"},
		Enable:  []string{"schtasks", "/Change", "/TN", taskName, "/ENABLE"},
		Disable: []string{"schtasks", "/Change", "/TN", taskName, "/DISABLE"},
	}
}

func escapeXML(s string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", "\"", "&quot;").Replace(s)
}
