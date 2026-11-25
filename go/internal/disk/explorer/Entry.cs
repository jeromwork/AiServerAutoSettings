using System;
using System.IO;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;

namespace RemoteAgents.Lab {
    internal static class Entry {
        [STAThread] static int Main(string[] args) {
            // Menu commands use the same asInvoker helper, with the v2 user-only pipe.
            if (args.Length == 2) return LabDisk.ForwardShell(new[] { "--disk-shell", args[0], args[1] });
            if (args.Length != 3 || args[0] != "serve") return 2;
            Application.EnableVisualStyles();
            using (var window = new Form { ShowInTaskbar = false, WindowState = FormWindowState.Minimized })
            using (var icon = new NotifyIcon { Icon = new System.Drawing.Icon(Assembly.GetExecutingAssembly().GetManifestResourceStream("RemoteAgents.App.ico")), Visible = true, Text = "Диск" }) {
                window.Load += (s, e) => window.Hide();
                window.Shown += (s, e) => {
                    window.Hide();
                    var disk = new LabDisk(args[1], message => Console.WriteLine(message),
                        (message, ok) => icon.ShowBalloonTip(4000, "Диск", message, ok ? ToolTipIcon.Info : ToolTipIcon.Warning));
                    disk.Sync(true, args[2]);
                    new Thread(() => {
                        try { while (Console.ReadLine() != null) disk.Wake(); }
                        finally { window.BeginInvoke(new Action(() => { disk.Stop(true); icon.Visible = false; window.Close(); })); }
                    }) { IsBackground = true }.Start();
                };
                Application.Run(window);
            }
            return 0;
        }
    }
}
