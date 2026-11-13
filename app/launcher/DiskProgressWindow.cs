using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace RemoteAgents.Launcher
{
    // A small view of the same tray observation. No second poller, transfer engine or folder picker.
    internal sealed class DiskProgressWindow : Form
    {
        readonly Func<DiskSyncSnapshot> snapshot; readonly Func<Dictionary<string, string>> paths;
        readonly FlowLayoutPanel rows = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true, Padding = new Padding(12) };
        readonly Label rate = new Label { AutoSize = true, Padding = new Padding(10) };
        readonly ComboBox projects = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 210 };
        DiskSyncSnapshot previous;
        readonly Action retry;
        readonly Timer timer = new Timer { Interval = 1000 }; readonly DiskTransferRate meter = new DiskTransferRate();
        internal DiskProgressWindow(Func<DiskSyncSnapshot> snapshot, Func<Dictionary<string, string>> paths, Action<string> openFolder, Action retry, Action details)
        {
            this.snapshot = snapshot; this.paths = paths; this.retry = retry;
            Text = "Ход синхронизации Диска"; StartPosition = FormStartPosition.CenterScreen;
            Size = new Size(570, 350); MinimumSize = new Size(470, 260); ShowIcon = false;
            var bottom = new FlowLayoutPanel { Dock = DockStyle.Bottom, AutoSize = true, Padding = new Padding(10) };
            var open = new Button { Text = "Открыть папку", AutoSize = true };
            var more = new Button { Text = "Подробнее…", AutoSize = true };
            open.Click += (s, e) => { string value; if (projects.SelectedItem != null && paths().TryGetValue(projects.SelectedItem.ToString(), out value)) openFolder(value); };
            more.Click += (s, e) => { try { details(); } catch (Exception error) { MessageBox.Show(this, error.Message, "Подробнее", MessageBoxButtons.OK, MessageBoxIcon.Information); } };
            bottom.Controls.Add(projects); bottom.Controls.Add(open); bottom.Controls.Add(more);
            var status = new Panel { Dock = DockStyle.Bottom, Height = 42 }; status.Controls.Add(rate);
            Controls.Add(rows); Controls.Add(status); Controls.Add(bottom);
            timer.Tick += (s, e) => RefreshSnapshot(); Shown += (s, e) => { RefreshSnapshot(); timer.Start(); };
            FormClosed += (s, e) => timer.Dispose();
        }
        internal void RefreshSnapshot()
        {
            var current = snapshot() ?? new DiskSyncSnapshot();
            string selected = projects.SelectedItem as string; var displayPaths = new Dictionary<string, string>(paths(), StringComparer.OrdinalIgnoreCase);
            foreach (var row in BackgroundWork.DiskProgress.Snapshot().Values) {
                string name = Path.GetFileName(row.Path.TrimEnd('\\', '/'));
                if (!displayPaths.ContainsKey(name)) displayPaths[name] = row.Path;
            }
            var names = displayPaths.Keys.OrderBy(n => n, StringComparer.CurrentCultureIgnoreCase).ToArray();
            projects.Items.Clear(); projects.Items.AddRange(names); if (names.Length > 0) projects.SelectedItem = names.Contains(selected) ? selected : names[0];
            if (!ReferenceEquals(previous, current)) { rate.Text = meter.Observe(current); previous = current; }
            rows.SuspendLayout(); foreach (Control old in rows.Controls.Cast<Control>().ToArray()) old.Dispose(); rows.Controls.Clear();
            int shown = 0;
            foreach (string name in names) {
                DiskSyncFolder folder; current.Folders.TryGetValue(name, out folder);
                var operation = BackgroundWork.DiskProgress.Row(displayPaths[name]);
                if (operation == null && DiskSyncStatus.Complete(current, folder)) continue;
                decimal total = folder == null ? -1 : DiskSyncStatus.Number(folder.Status, "globalBytes"), have = folder == null ? -1 : DiskSyncStatus.Number(folder.Status, "inSyncBytes");
                int percent = total > 0 && have >= 0 ? (int)Math.Floor(Math.Max(0, Math.Min(100, have / total * 100))) : 0;
                var panel = new Panel { Width = Math.Max(400, rows.ClientSize.Width - 30), Height = 105 };
                panel.Controls.Add(new Label { Text = name, AutoSize = true, Top = 0, Left = 0 });
                panel.Controls.Add(new ProgressBar { Left = 0, Top = 23, Width = panel.Width - 55, Height = 16, Value = percent, Style = operation != null && operation.Marquee ? ProgressBarStyle.Marquee : ProgressBarStyle.Continuous });
                panel.Controls.Add(new Label { Text = operation == null && total > 0 && have >= 0 ? percent + "%" : "…", AutoSize = true, Top = 22, Left = panel.Width - 48 });
                panel.Controls.Add(new Label { Text = operation == null ? DiskSyncStatus.Text(current, folder) : operation.Failure.Length > 0 ? "⚠ " + operation.Failure : operation.Step, Left = 0, Top = 44, Width = panel.Width, Height = 30, AutoEllipsis = true });
                if (operation != null && operation.NextText.Length > 0) panel.Controls.Add(new Label { Text = operation.NextText, Left = 0, Top = 78, Width = panel.Width - 145, AutoEllipsis = true });
                if (operation != null && operation.CanRetry) {
                    var again = new Button { Text = "Повторить сейчас", AutoSize = true, Left = panel.Width - 140, Top = 73 };
                    again.Click += (s, e) => { retry(); RefreshSnapshot(); }; panel.Controls.Add(again);
                }
                rows.Controls.Add(panel); shown++;
            }
            if (shown == 0) rows.Controls.Add(new Label { Text = names.Length == 0 ? "Нет выбранных папок" : "Все выбранные папки синхронизированы", AutoSize = true });
            rows.ResumeLayout();
        }
    }
    internal static class DiskDetailsLauncher
    {
        static Process window;
        [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr handle);
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr handle, int command);
        internal static void Open(string diskHome)
        {
            if (window != null && !window.HasExited) { ShowWindow(window.MainWindowHandle, 9); SetForegroundWindow(window.MainWindowHandle); return; }
            string tray = Path.Combine(diskHome, "tray"), exe = Path.Combine(tray, "syncthingtray.exe"), ini = Path.Combine(tray, "syncthingtray.ini");
            if (!File.Exists(exe) || !File.Exists(ini)) throw new IOException("Syncthing Tray ещё не установлен");
            string details = Path.Combine(tray, "details"); Directory.CreateDirectory(details);
            File.WriteAllText(Path.Combine(details, "syncthingtray.ini"), DiskDetailsSettings.WithoutAutostart(File.ReadAllText(ini)), Files.Utf8);
            // QtUtilities checks the working directory's portable INI first. --new-instance prevents
            // forwarding into any unrelated tray; --windowed returns before creating a tray icon.
            window = Process.Start(new ProcessStartInfo(exe, "qt-widgets-gui --windowed --new-instance") { WorkingDirectory = details, UseShellExecute = false });
        }
    }
}
