using System;
using System.IO;
using System.Threading;

namespace RemoteAgents.Launcher
{
    // Removes autostart, stops the tray and the Explorer Disk entry. User files and settings stay.
    internal static class Uninstall
    {
        public static void Run(string home)
        {
            using (var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey("Software\\Microsoft\\Windows\\CurrentVersion\\Run")) {
                var value = Convert.ToString(key.GetValue("RemoteAgents", ""));
                if (value.IndexOf(Path.Combine(home, "RemoteAgents.exe"), StringComparison.OrdinalIgnoreCase) >= 0) key.DeleteValue("RemoteAgents", false);
            }
            try { Program.Forward(Program.InstanceName(home, System.Security.Principal.WindowsIdentity.GetCurrent().User), new[] { "--exit" }); } catch { }
            var engine = new UpdateEngine(home, Program.Version);
            if (engine.Current.Length == 0) return;
            string script = Path.Combine(engine.Folder(engine.Current), "build", "Uninstall.ps1");
            string output = Path.Combine(home, "state", "uninstall-output.tmp"); Directory.CreateDirectory(Path.GetDirectoryName(output));
            try {
                if (External.Run("powershell.exe", new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-Home", home }, home, output, 180000, 1024 * 1024, CancellationToken.None) != 0) throw new IOException("Удаление не завершено");
            } finally { if (File.Exists(output)) File.Delete(output); }
        }
    }
}
