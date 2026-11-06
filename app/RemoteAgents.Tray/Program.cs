using System.Diagnostics;
using System.Net.Http;
using System.Text.Json;
using RemoteAgents.Core;
using System.Windows.Forms;

ApplicationConfiguration.Initialize();
using var mutex = new Mutex(true, "RemoteAgents.Tray.Singleton", out var created);
if (!created) return;
Application.Run(new TrayContext());

sealed class TrayContext : ApplicationContext
{
    readonly NotifyIcon icon = new() { Visible = true, Text = "RemoteAgents: проверка синхронизации", Icon = System.Drawing.SystemIcons.Information };
    readonly PauseController pause = new();
    readonly System.Windows.Forms.Timer timer = new() { Interval = 5000 };
    readonly string data = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RemoteAgents");
    public TrayContext()
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add("Проекты", null, (_, _) => ShowProjects());
        menu.Items.Add("Пауза на 30 минут", null, (_, _) => Pause(TimeSpan.FromMinutes(30)));
        menu.Items.Add("Пауза на 2 часа", null, (_, _) => Pause(TimeSpan.FromHours(2)));
        menu.Items.Add("Пауза до возобновления", null, (_, _) => { pause.PauseUntilResume(); Update(); });
        menu.Items.Add("Возобновить", null, (_, _) => { pause.Resume(); Update(); });
        menu.Items.Add("Показать ошибки", null, (_, _) => ShowErrors());
        menu.Items.Add("Открыть папку", null, (_, _) => OpenFolder());
        menu.Items.Add("Журнал", null, (_, _) => OpenLog());
        menu.Items.Add("Выход", null, (_, _) => ExitThread());
        icon.ContextMenuStrip = menu; timer.Tick += (_, _) => Update(); timer.Start(); Update();
    }
    void Pause(TimeSpan d) { pause.Pause(d); MessageBox.Show("На паузе команды агента не пройдут проверку свежести."); Update(); }
    void Update() { var projects = SyncDiscovery.Find(data); icon.Text = pause.IsPaused ? "RemoteAgents: пауза" : projects.Count == 0 ? "RemoteAgents: нет подключения" : "RemoteAgents: проверка состояния"; }
    void ShowProjects() { var p = SyncDiscovery.Find(data); MessageBox.Show(p.Count == 0 ? "Нет подключённых проектов." : string.Join(Environment.NewLine, p.Select(x => $"{x.ProjectId}: состояние проверяется"))); }
    void ShowErrors() => MessageBox.Show("Ошибок не получено.");
    void OpenFolder() { var p = SyncDiscovery.Find(data).FirstOrDefault(); if (p != null && Directory.Exists(p.ReplicaPath)) Process.Start("explorer.exe", p.ReplicaPath); }
    void OpenLog() { var p = SyncDiscovery.Find(data).FirstOrDefault(); var log = p is null ? null : Path.Combine(p.StateDirectory, "app.log"); if (log != null && File.Exists(log)) Process.Start("notepad.exe", log); }
    protected override void ExitThreadCore() { timer.Dispose(); icon.Visible = false; icon.Dispose(); base.ExitThreadCore(); }
}
