"""Architecture guards for Windows-only ownership paths; no network mutation."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class Lifecycle(unittest.TestCase):
    def test_elevated_owner(self):
        host = (ROOT/'app/launcher/VpnHost.cs').read_text(encoding='utf-8-sig')
        native = (ROOT/'app/launcher/NativeJob.cs').read_text()
        self.assertIn('WindowsBuiltInRole.Administrator', host)
        self.assertIn('parent.Handle', host)
        self.assertIn('parent.StartTime.ToUniversalTime().Ticks', host)
        self.assertIn('parent.HasExited', host)
        self.assertIn('job.Start(Json.Str(plan, "exe")', host)
        self.assertIn('0x2000', native)  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        create, assign, resume = (native.index(s) for s in ('if (!CreateProcess(', 'if (!AssignProcessToJobObject(', 'if (ResumeThread('))
        self.assertLess(create, assign)
        self.assertLess(assign, resume)
        self.assertIn('0x08000004', native)  # CREATE_SUSPENDED | CREATE_NO_WINDOW
        self.assertIn('TerminateProcess(info.process, 1)', native)
        final = host[host.index('                finally {'):]
        self.assertLess(final.index('job.Dispose()'), final.index('Write(home, state,'))
        self.assertLess(final.index('job.Dispose()'), final.index('new NativeJob()'))
        self.assertIn('process.WaitForExit(2500)', final)

    def test_no_tasks_no_automatic_enable(self):
        script = (ROOT/'transport/Vpn.Tun.ps1').read_text(encoding='utf-8-sig')
        host = (ROOT/'app/launcher/VpnHost.cs').read_text()
        tray = (ROOT/'app/launcher/TrayContext.cs').read_text()
        for source in (script, host):
            for banned in ('Register-ScheduledTask', 'Start-ScheduledTask', 'New-NetRoute', 'AddMinutes(5)'):
                self.assertNotIn(banned, source)
        self.assertIn("$ParentPid -le 0 -or -not $HostExe", script)
        self.assertNotIn('CheckVpn(vpn);', tray[tray.index('async void WatchHealth'):tray.index('void ShowMain')])
        shutdown = tray[tray.index('protected override void ExitThreadCore'):]
        self.assertLess(shutdown.index('state/vpn.stop'), shutdown.index('stop.Cancel()'))
        self.assertIn('else if (id == "vpn") ToggleVpn();', tray)
        self.assertIn('if (enabled) CheckVpn(vpn, true); else DisableVpn(vpn, true);', tray)
        self.assertIn('CheckLegacyVpn();', tray)
        self.assertIn('if (legacyVpnChecked || closing', tray)

    def test_bounded_probe_cannot_be_direct_success(self):
        probe = (ROOT/'app/launcher/VpnProbe.cs').read_text()
        self.assertIn('GetBestInterface(', probe)
        self.assertIn('index != tunIndex', probe)
        self.assertIn('client.ConnectAsync(address, url.Port)', probe)
        self.assertIn('AuthenticateAsClientAsync(url.DnsSafeHost)', probe)
        self.assertIn('client.Close()', probe)
        self.assertNotIn('GetHostAddresses', probe)
        self.assertNotIn('HttpWebRequest', probe)
        self.assertNotIn('ServerCertificateValidationCallback', probe)

if __name__ == '__main__':
    unittest.main()
