using System;
using System.IO;
using System.Threading;

namespace RemoteAgents.Launcher
{
    // Removes autostart and stops the tray; the installed bundle's Uninstall.ps1 removes the Disk pin. User files and settings stay.
    internal static class Uninstall
    {
        public static void Run(string home)
        {
            using (var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey("Software\\Microsoft\\Windows\\CurrentVersion\\Run")) {
                var value = Convert.ToString(key.GetValue("RemoteAgents", ""));
                if (value.IndexOf(Path.Combine(home, "RemoteAgents.exe"), StringComparison.OrdinalIgnoreCase) >= 0) key.DeleteValue("RemoteAgents", false);
            }
            string instance = Program.InstanceName(home, System.Security.Principal.WindowsIdentity.GetCurrent().User);
            try { Program.Forward(instance, new[] { "--exit" }); } catch { }
            // Wait until the tray has stopped before anything of it is removed.
            try { using (var running = Mutex.OpenExisting("Global\\" + instance)) {
                bool held = false;
                try { try { held = running.WaitOne(60000); } catch (AbandonedMutexException) { held = true; }
                    if (!held) throw new IOException("Закройте RemoteAgents перед удалением");
                } finally { if (held) running.ReleaseMutex(); }
            } } catch (WaitHandleCannotBeOpenedException) { }
            LanPacOwnership.Recover(home, new LanWindowsBrowser());
            if (Path.GetFullPath(home).Equals(Path.GetFullPath(Program.DefaultHome), StringComparison.OrdinalIgnoreCase)) {
                string diskHome = DiskExplorerController.DefaultDiskHome;
                DiskExplorerController.RemoveIntegration(ConfigProfile.DiskRoot(ConfigProfile.Load(home)), diskHome,
                    DiskExplorerNative.CreateService(Path.Combine(diskHome, "explorer-icons"), delegate { }), DiskExplorerNative.CreateRegistry(delegate { }));
                DiskExplorerNative.CleanupIcons(Path.Combine(diskHome, "explorer-icons"));
            }
            var engine = new UpdateEngine(home, Program.Version);
            // No installed bundle: nothing was ever set up beyond autostart, which is already removed.
            if (engine.Current.Length == 0) return;
            string script = Path.Combine(engine.Folder(engine.Current), "build", "Uninstall.ps1");
            string output = Path.Combine(home, "state", "uninstall-output.tmp"); Directory.CreateDirectory(Path.GetDirectoryName(output));
            try {
                if (External.Run("powershell.exe", new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-Home", home }, home, output, 180000, 1024 * 1024, CancellationToken.None) != 0) throw new IOException("Удаление не завершено");
            } finally { if (File.Exists(output)) File.Delete(output); }
        }
    }
}
