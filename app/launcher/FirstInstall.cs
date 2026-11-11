using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace RemoteAgents.Launcher
{
    internal static class FirstInstall
    {
        internal static bool Required(string home)
        {
            string config = Path.Combine(home,"config.json");
            if(File.Exists(config) && Json.Bool(Json.Map(Json.Get(Json.Read(config),"wizard")),"configured")) return false;
            string state = Path.Combine(home, "state", "migration.json");
            return !File.Exists(state) || new[] { "rolled-back", "error" }.Contains(Json.Str(Json.Read(state), "phase"));
        }
        internal static bool HasProfile(string home)
        {
            string file = Path.Combine(home, "config.json");
            if (File.Exists(file) && Json.Str(Json.Map(Json.Get(Json.Read(file), "transport")), "profilePath").Length > 0) return true;
            if (File.Exists(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RemoteDisk", "profile.txt"))) return true;
            string profiles = Path.Combine(home, "ssh-profiles");
            return Directory.Exists(profiles) && Directory.GetFiles(profiles, "ssh-transport.json", SearchOption.AllDirectories).Length > 0;
        }
        public static void Start(string home)
        {
            if (!Path.GetFullPath(home).TrimEnd('\\').Equals(Path.GetFullPath(Program.DefaultHome).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)) throw new IOException("Установка с Run доступна только в основном Home; используйте --tray --home для изоляции");
            Application.EnableVisualStyles();
            Program.StartLauncher(Path.Combine(home, Product.ExeName), home, false);
        }

        public static void UninstallVpn(string home)
        {
            try { Program.Forward(Program.InstanceName(home, System.Security.Principal.WindowsIdentity.GetCurrent().User), new[] { "--exit" }); } catch { }
            using (var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run")) {
                string command = Convert.ToString(key.GetValue("RemoteVPN", ""));
                if (command.IndexOf(Path.Combine(home, Product.ExeName), StringComparison.OrdinalIgnoreCase) >= 0) key.DeleteValue("RemoteVPN", false);
            }
        }
    }
}
