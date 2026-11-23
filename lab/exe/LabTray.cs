using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace RemoteAgents.Lab
{
    // Значок в трее: серый (запуск), жёлтый (ищу путь), зелёный (канал есть), красный (остановлено). Цвет и текст берутся из состояния.
    internal sealed class LabTray : ApplicationContext
    {
        readonly Supervisor supervisor; readonly NotifyIcon icon = new NotifyIcon();
        readonly Icon grey = MakeIcon(Color.Gray), yellow = MakeIcon(Color.Goldenrod), green = MakeIcon(Color.ForestGreen), red = MakeIcon(Color.Firebrick);
        ToolStripMenuItem diskItem; Timer clickTimer; Form window; TextBox box; Button restart; readonly LabDisk disk;

        public LabTray(Supervisor supervisor)
        {
            this.supervisor = supervisor;
            disk = new LabDisk(supervisor.Home, supervisor.WriteLog, (message, ok) => icon.ShowBalloonTip(4000, "Диск", message, ok ? ToolTipIcon.Info : ToolTipIcon.Warning));
            var menu = new ContextMenuStrip();
            menu.Items.Add("Открыть", null, (s, e) => OpenHappier());
            diskItem = (ToolStripMenuItem)menu.Items.Add("Диск", null, (s, e) => OpenDisk());
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Состояние", null, (s, e) => ShowWindow());
            menu.Items.Add("Скопировать отчёт", null, (s, e) => supervisor.RequestReport());
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Выход", null, (s, e) => { disk.Stop(false); supervisor.RequestExit(); });
            icon.ContextMenuStrip = menu; icon.Visible = true;
            menu.Opening += (s, e) => diskItem.Enabled = supervisor.DiskRunning && supervisor.DiskHome.Length > 0;
            // Одиночный левый клик открывает Happier после паузы DoubleClickTime; двойной клик гасит таймер и открывает только «Состояние».
            clickTimer = new Timer { Interval = SystemInformation.DoubleClickTime };
            clickTimer.Tick += (s, e) => { clickTimer.Stop(); OpenHappier(); };
            icon.MouseClick += (s, e) => { if (e.Button == MouseButtons.Left) { clickTimer.Stop(); clickTimer.Start(); } };
            icon.DoubleClick += (s, e) => { clickTimer.Stop(); ShowWindow(); };
            supervisor.StateChanged += Refresh;
            supervisor.Quit += () => { clickTimer.Stop(); clickTimer.Dispose(); disk.Stop(true); icon.Visible = false; icon.Dispose(); ExitThread(); };
            supervisor.ReportReady += text => {
                try { Clipboard.SetText(text); icon.ShowBalloonTip(3000, "RemoteAgents-Lab", "Отчёт скопирован в буфер обмена", ToolTipIcon.Info); }
                catch (Exception) { icon.ShowBalloonTip(3000, "RemoteAgents-Lab", "Буфер обмена занят, нажмите ещё раз", ToolTipIcon.Warning); }
            };
            Refresh();
        }

        void OpenHappier()
        {
            try { int port = supervisor.HappierPort; System.Diagnostics.Process.Start("http://127.0.0.1:" + (port > 0 ? port : 47831)); }
            catch (Exception ex) { supervisor.WriteLog("Открыть Happier: " + ex.Message); }
        }

        void OpenDisk()
        {
            try { string root = supervisor.DiskHome; if (supervisor.DiskRunning && root.Length > 0) System.Diagnostics.Process.Start("explorer.exe", "\"" + root + "\""); }
            catch (Exception ex) { supervisor.WriteLog("Открыть Диск: " + ex.Message); }
        }

        void Refresh()
        {
            var state = supervisor.State;
            icon.Icon = state.Color == "green" ? green : state.Color == "yellow" ? yellow : state.Color == "red" ? red : grey;
            disk.Sync(supervisor.DiskRunning, supervisor.DiskHome);
            icon.Text = state.Tip; // NotifyIcon.Text: не больше 63 символов, Supervisor их уже обрезал
            if (window != null && window.Visible) FillWindow();
        }

        void ShowWindow()
        {
            if (window == null) {
                window = new Form { Text = "RemoteAgents-Lab: состояние", Width = 560, Height = 380, StartPosition = FormStartPosition.CenterScreen, ShowInTaskbar = true, Icon = grey };
                box = new TextBox { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Fill, Font = new Font("Consolas", 9f) };
                restart = new Button { Text = "Перезапустить Python", Dock = DockStyle.Bottom, Height = 34 };
                restart.Click += (s, e) => supervisor.RestartPython();
                window.Controls.Add(box); window.Controls.Add(restart);
                window.FormClosing += (s, e) => { if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; window.Hide(); } };
            }
            FillWindow(); window.Show(); window.Activate();
        }

        void FillWindow()
        {
            var state = supervisor.State; var slots = supervisor.Slots;
            var text = "Значок: " + state.Color + "\r\n" + state.Tip + "\r\n\r\n" + string.Join("\r\n", state.Lines) + "\r\n\r\n" +
                "EXE: " + supervisor.Version + (supervisor.IsAdmin ? " (администратор)" : " (БЕЗ прав администратора)") + "\r\n" +
                "Python: " + (supervisor.IsRunning ? "запущен" : "не запущен") + "\r\n" +
                (slots != null ? "Версия кода: " + slots.Current + (slots.Unverified ? " (ещё не проверена)" : " (рабочая)") + "\r\nПоследняя рабочая: " + slots.LastGood + "\r\n" : "");
            box.Text = text;
        }

        static Icon MakeIcon(Color color)
        {
            using (var bitmap = new Bitmap(32, 32)) using (var graphics = Graphics.FromImage(bitmap)) using (var brush = new SolidBrush(color)) {
                graphics.Clear(Color.Transparent); graphics.FillEllipse(brush, 2, 2, 28, 28); IntPtr handle = bitmap.GetHicon();
                try { return (Icon)Icon.FromHandle(handle).Clone(); } finally { DestroyIcon(handle); }
            }
        }
        [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr handle);
    }
}
