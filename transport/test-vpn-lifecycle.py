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
        assign, create, resume = (native.index(s) for s in ('new IntPtr(0x0002000D)', 'if (!CreateProcess(', 'if (ResumeThread('))
        self.assertLess(assign, create)  # PROC_THREAD_ATTRIBUTE_JOB_LIST is atomic with creation
        self.assertLess(create, resume)
        self.assertNotIn('AssignProcessToJobObject(', native)
        self.assertIn('0x08080004', native)  # CREATE_SUSPENDED | CREATE_NO_WINDOW
        self.assertIn('TerminateProcess(info.process, 1)', native)
        final = host[host.index('                finally {'):]
        self.assertLess(final.index('job.Dispose()'), final.index('Write(home, state,'))
        self.assertLess(final.index('job.Dispose()'), final.index('new NativeJob()'))
        self.assertIn('process.WaitForExit(2500)', final)

    def test_job_handle_and_inheritance_lifetime(self):
        native = (ROOT/'app/launcher/NativeJob.cs').read_text()
        self.assertIn('readonly SafeFileHandle handle', native)
        self.assertIn('handle.DangerousAddRef(ref pinned)', native)
        self.assertIn('handle.DangerousRelease()', native)
        self.assertIn('TerminateJobObject(handle, 1)', native)
        self.assertIn('new IntPtr(0x00020002)', native)  # inherited stdio whitelist only
        self.assertIn('new IntPtr(3 * IntPtr.Size)', native)
        self.assertIn('ref StartupInfoEx startup', native)
        self.assertIn('startup.cb = Marshal.SizeOf(typeof(StartupInfoEx))', native)

    def test_no_tasks_no_automatic_enable(self):
        script = (ROOT/'transport/Vpn.Tun.ps1').read_text(encoding='utf-8-sig')
        host = (ROOT/'app/launcher/VpnHost.cs').read_text()
        tray = (ROOT/'app/launcher/TrayContext.cs').read_text()
        for source in (script, host):
            for banned in ('Register-ScheduledTask', 'Start-ScheduledTask', 'New-NetRoute', 'AddMinutes(5)'):
                self.assertNotIn(banned, source)
        self.assertIn("$ParentPid -le 0 -or -not $HostExe", script)
        self.assertIn('return c.Name != "vpn" && config.Wanted(c);', tray)
        self.assertNotIn('CheckVpn(vpn);', tray[tray.index('async void WatchHealth'):tray.index('void ShowMain')])
        shutdown = tray[tray.index('protected override void ExitThreadCore'):]
        self.assertLess(shutdown.index('state/vpn.stop'), shutdown.index('stop.Cancel()'))
        self.assertIn('else if (id == "vpn") ToggleVpn();', tray)
        self.assertIn('if (enabled) CheckVpn(vpn, true); else DisableVpn(vpn, true);', tray)
        self.assertIn('catch { if (enabling) SignalVpnStop();', tray)
        self.assertIn('catch (OperationCanceledException) { if (enabling) SignalVpnStop(); }', tray)
        self.assertIn('CheckLegacyVpn();', tray)
        self.assertIn('if (legacyVpnChecked || closing', tray)

    def test_machine_wide_exclusion_includes_cleanup(self):
        host = (ROOT/'app/launcher/VpnHost.cs').read_text()
        policy = (ROOT/'app/launcher/VpnWatchdog.cs').read_text()
        script = (ROOT/'transport/Vpn.Tun.ps1').read_text(encoding='utf-8-sig')
        self.assertIn('new Mutex(false, VpnWatchdog.OwnerMutex)', host)
        self.assertIn('OwnerMutex = @"Global\\RemoteAgents-VpnHost"', policy)
        self.assertNotIn('VpnId(home)', host)
        cleanup = script[script.index("if($action -in @('InspectLegacy','Cleanup'))"):script.index("if($action -eq 'Status')")]
        self.assertIn("Threading.Mutex($false,'Global\\RemoteAgents-VpnHost')", cleanup)
        self.assertLess(cleanup.index('$held=$gate.WaitOne(0)'), cleanup.index('Remove-VpnRemnants $root'))
        self.assertIn('if(-not $held){throw', cleanup)
        self.assertIn('$gate.ReleaseMutex()', cleanup)

    def test_unprivileged_observation_of_elevated_owner(self):
        status = (ROOT/'app/launcher/VpnStatus.cs').read_text()
        owner = status[status.index('static bool IdentityAlive'):]
        self.assertIn('!process.WaitForExit(0)', owner)
        self.assertNotIn('!process.HasExited', owner)
        common = (ROOT/'transport/Transport.Common.ps1').read_text(encoding='utf-8-sig')
        observer = common[common.index('function Test-VpnHostAlive'):]
        self.assertIn('-not $p.WaitForExit(0)', observer)
        self.assertNotIn('$p.HasExited', observer)
        self.assertIn('StartTime.ToUniversalTime().Ticks', observer)
        script = (ROOT/'transport/Vpn.Tun.ps1').read_text(encoding='utf-8-sig')
        self.assertIn('pid=$ParentPid;startedTicks=[string]$parentStart', script)

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
