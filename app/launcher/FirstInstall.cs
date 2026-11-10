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
            if (Product.IsVpn) {
                using (var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"))
                    key.SetValue("RemoteVPN", Files.Quote(Path.Combine(home, Product.ExeName)) + " --tray --home " + Files.Quote(home));
                Program.StartLauncher(Path.Combine(home, Product.ExeName), home, true);
                if (!HasProfile(home)) MessageBox.Show("Для VPN установите и настройте RemoteAgents.exe. VPN включается только из меню, с подтверждением UAC.", "RemoteVPN");
                return;
            }
            string address = "", login = "";
            if (!HasProfile(home)) {
                using (var form = new Form { Text = "RemoteAgents — первый запуск", Width = 520, Height = 240, StartPosition = FormStartPosition.CenterScreen }) {
                    var server = new TextBox { Left = 160, Top = 25, Width = 320 };
                    var user = new TextBox { Left = 160, Top = 65, Width = 320, Text = "root" };
                    form.Controls.Add(new Label { Left = 20, Top = 28, Width = 135, Text = "Адрес сервера" }); form.Controls.Add(server);
                    form.Controls.Add(new Label { Left = 20, Top = 68, Width = 135, Text = "Пользователь" }); form.Controls.Add(user);
                    form.Controls.Add(new Label { Left = 20, Top = 105, Width = 460, Height = 40, Text = "Пароль и проверка ключа сервера — в следующем защищённом окне SSH. Пароль не сохраняется." });
                    var next = new Button { Left = 330, Top = 155, Width = 150, Text = "Настроить", DialogResult = DialogResult.OK };
                    form.Controls.Add(next); form.AcceptButton = next;
                    if (form.ShowDialog() != DialogResult.OK) return;
                    address = server.Text.Trim(); login = user.Text.Trim();
                    if (address.Length == 0 || login.Length == 0) throw new ArgumentException();
                }
            }
            var engine = new UpdateEngine(home, Program.Version);
            var psi = new ProcessStartInfo(Files.Executable("powershell.exe"), Files.Arguments(new[] {
                "-NoLogo", "-NoProfile", "-NonInteractive", "-STA", "-ExecutionPolicy", "Bypass", "-File",
                Path.Combine(engine.Folder(engine.Current), "build", "FirstInstall.ps1"), "-Home", home, "-ServerAddress", address, "-Login", login
            })) { UseShellExecute = false, CreateNoWindow = true };
            using (var process = Process.Start(psi)) using (var form = new Form { Text = "RemoteAgents — установка", Width = 560, Height = 150, StartPosition = FormStartPosition.CenterScreen })
            using (var timer = new System.Windows.Forms.Timer { Interval = 500 }) {
                form.Controls.Add(new Label { Dock = DockStyle.Fill, Padding = new Padding(16), Text = "Настраиваем SSH, диск и управление.\r\nЕсли открыт запрос SSH, проверьте сервер и введите пароль." });
                bool done = false; form.FormClosing += (s,e) => { if (!done) e.Cancel = true; };
                timer.Tick += (s,e) => { if (process.HasExited) { done = true; form.Close(); } }; timer.Start(); form.ShowDialog();
                if (process.ExitCode != 0) throw new IOException("Установка не завершена");
            }
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
