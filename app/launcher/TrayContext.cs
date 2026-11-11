using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace RemoteAgents.Launcher
{
    internal sealed class TrayContext : ApplicationContext
    {
        readonly string home; readonly Journal log; readonly Configuration config; readonly UpdateEngine engine;
        readonly NotifyIcon icon; readonly Control dispatch = new Control();
        readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer { Interval = 1000 };
        readonly CancellationTokenSource stop = new CancellationTokenSource();
        readonly List<ComponentRuntime> runtimes = new List<ComponentRuntime>(); readonly List<NativeJob> actionJobs = new List<NativeJob>();
        ToolStripItem pathRow, checkedRow, networkRow, diskRow, bridgeRow, vpnRow, errorRow, configErrorRow;
        ToolStripMenuItem pathsMenu, vpnToggle;
        readonly Icon green = MakeIcon(Color.ForestGreen), yellow = MakeIcon(Color.Goldenrod), red = MakeIcon(Color.Firebrick);
        readonly object pipeGate = new object(); NamedPipeServerStream server; Task worker, pipeWorker;
        readonly ConcurrentQueue<string[]> commands = new ConcurrentQueue<string[]>(); volatile bool readyForCommands;
        BundleDefinition definition; bool busy, closing, ticking, actionBusy, serverUpdateRequested, installStop;
        readonly string migrationObserver = Guid.NewGuid().ToString("N");
        DateTime settingsWritten = DateTime.MinValue;
        DateTime nextMigrationCheck = DateTime.MinValue; bool migrationChecking;
        string updateSummary = "обновления устанавливаются вручную из нового EXE";
        public bool RestartRequested { get; private set; }
        public TrayContext(string home, Journal log, string pipeName, SecurityIdentifier sid, string[] args)
        {
            this.home = home; this.log = log; dispatch.CreateControl(); var unused = dispatch.Handle;
            Directory.CreateDirectory(Path.Combine(home, "status"));
            config = new Configuration(home); engine = new UpdateEngine(home, Program.Version);
            // Accept secondary launches while first-install selftest / binary downloads are still running.
            pipeWorker = Task.Run(() => Listen(pipeName, sid));
            try {
                icon = new NotifyIcon { Visible = true, Icon = yellow, Text = Product.Name + ": запускается…" };
                engine.Recover(); Bootstrap();
                icon.MouseClick += (s, e) => { if (e.Button == MouseButtons.Left) ShowStatus(); }; LoadComponents();
            } catch {
                stop.Cancel(); lock (pipeGate) { if (server != null) server.Dispose(); } throw;
            }
            readyForCommands = true;
            timer.Tick += (s, e) => Tick(); timer.Start();
            dispatch.BeginInvoke(new Action(() => { Handle(args); DrainCommands(); Tick();
                if(Path.GetFullPath(home).Equals(Path.GetFullPath(Program.DefaultHome),StringComparison.OrdinalIgnoreCase)) CheckSetup();

            }));
        }
        void Bootstrap()
        {
            if (engine.Current.Length != 0) { BundleDefinition.Load(engine.Folder(engine.Current)); return; }
            string zip = Path.Combine(engine.Root, "embedded.zip");
            try {
                string version = UpgradeInstaller.ExtractEmbedded(zip);
                var manifest = Manifest.Parse(Json.Encode(new { version, file = "embedded.zip", sha256 = Files.Hash(zip), size = new FileInfo(zip).Length, minLauncher = Program.Version }));
                string ready = engine.Prepare(manifest, p => File.Copy(zip, p, true), f => External.SelfTest(f, home, stop.Token), (d, f) => UpdateEngine.InstallBinaries(d, f, home, stop.Token), stop.Token);
                if (ready == null) throw new InvalidDataException(); engine.Activate(ready);
                log.Write("bundle.bootstrap.ok");
            } finally { if (File.Exists(zip)) File.Delete(zip); }
        }

        bool VpnModulesReady()
        {
            // Disabled VPN is a valid installation; updates must never trigger UAC or require TUN.
            return runtimes.Any(r => r.Definition.Critical) ? runtimes.Where(r => r.Definition.Critical).All(r => r.Healthy) : File.Exists(TransportScript("Vpn.Tun.ps1")) && File.Exists(TransportScript("Test-VpnConflict.ps1"));
        }
        void LoadComponents()
        {
            foreach (var r in runtimes) r.Dispose(); runtimes.Clear();
            foreach (var j in actionJobs) j.Dispose(); actionJobs.Clear();
            definition = BundleDefinition.Load(engine.Folder(engine.Current));
            foreach (var c in definition.Components) runtimes.Add(new ComponentRuntime(c, config.Enabled(c), home, engine.Folder(engine.Current), log));
            var vpn = definition.Components.FirstOrDefault(c => c.Name == "vpn" && c.CommandManaged);
            if (vpn != null && !File.Exists(Path.Combine(home, "status", "vpn.json")) && File.Exists(TransportScript("Vpn.Tun.ps1"))) RunAction(new MenuAction { Exe = vpn.Exe, Args = vpn.Args });
            RefreshMenu();
        }
        void Tick()
        {
            if (closing || ticking) return; ticking = true;
            try {
                TryDeleteOld(); ReloadSettings(); foreach (var r in runtimes) r.Tick();
                var critical = runtimes.Where(r => r.Definition.Critical).ToArray();
                bool all = Product.IsVpn ? VpnModulesReady() : critical.Length > 0 && critical.All(r => r.Healthy);
                string result = engine.Observe(all);
                string image = UpgradeInstaller.ObserveImage(home, engine, all, result);
                if (image == "rollback") { log.Write("launcher.rollback"); RestartRequested = true; ExitThread(); return; }
                if (result == "rollback") { log.Write("update.rollback"); updateSummary = "обновление откачено: здоровье не подтверждено"; LoadComponents(); foreach (var r in runtimes) r.Tick(); all = false; }
                if (result == "accepted") { log.Write("update.accepted"); updateSummary = "обновление проверено"; }
                int count = critical.Count(r => r.Healthy); icon.Icon = all ? green : count > 0 ? yellow : red;
                var transport = StatusView.Read(home, "transport", maxAgeSec: 15);
                if (Product.IsVpn) {
                    var vpnStatus = StatusView.Read(home, "vpn", maxAgeSec: 15);
                    icon.Icon = Json.Bool(vpnStatus, "ok") && Json.Str(vpnStatus, "state") == "on" ? green : yellow;
                    string text = "RemoteVPN: " + StatusView.Summary(vpnStatus); icon.Text = text.Length > 63 ? text.Substring(0, 62) + "…" : text;
                } else icon.Text = StatusView.Tooltip(transport); RefreshMenu(); WriteStatus();
                if (!Product.IsVpn && DateTime.UtcNow >= nextMigrationCheck) CheckMigration(false);
                if (serverUpdateRequested && !engine.Pending && !busy && TrySelfUpdate()) return;
            } catch { log.Write("supervisor.tick.failed"); icon.Icon = red; }
            finally { ticking = false; }
        }
        async void CheckMigration(bool confirm)
        {
            if (migrationChecking || closing || !File.Exists(Path.Combine(home, "state", "migration.json"))) return;
            var state = Json.Read(Path.Combine(home, "state", "migration.json"));
            if (Json.Str(state, "phase") != "pending" || Json.Bool(state, "dryRun")) return;
            migrationChecking = true; nextMigrationCheck = DateTime.UtcNow.AddSeconds(10);
            try { await Task.Run(() => Migration.Check(home, confirm, migrationObserver, stop.Token)); }
            catch (OperationCanceledException) { }
            catch { log.Write("migration.check.failed"); }
            finally { migrationChecking = false; }
        }
        void WriteStatus()
        {
            Json.Write(Path.Combine(home, "status", Product.StatusName), new { schema = 1, pid = Process.GetCurrentProcess().Id, launcherVersion = Program.Version, bundleVersion = engine.Current,
                previousVersion = engine.Previous, pending = engine.Pending, running = !closing, updatedUtc = DateTime.UtcNow.ToString("o"), update = updateSummary,
                ok = !closing && (Product.IsVpn ? VpnModulesReady() : runtimes.Any(r => r.Definition.Critical) && runtimes.Where(r => r.Definition.Critical).All(r => r.Healthy)), components = runtimes.Select(r => r.Snapshot()).ToArray() });
            if (!Product.IsVpn && (!closing || (!RestartRequested && !installStop)) && File.Exists(LauncherRecovery.Intent(home))) File.Delete(LauncherRecovery.Intent(home));
        }
        void RefreshMenu()
        {
            // Do not replace a visible menu while the user is choosing an item.
            if (icon.ContextMenuStrip != null && icon.ContextMenuStrip.Visible) { RefreshStatusRows(); return; }
            var menu = new ContextMenuStrip();
            menu.Items.Add("Бандл: " + engine.Current).Enabled = false;
            AddTransportMenu(menu);
            foreach (var r in runtimes.Where(r => r.Definition.Name != "vpn")) {
                var item = new ToolStripMenuItem(r.Definition.Title + ": " + (r.Enabled ? (r.Healthy ? "работает; " : "нет связи; ") : "выключен; ") + r.Summary);
                bool on = r.Definition.Name == "control" ? Json.Bool(StatusView.Read(home, "control", maxAgeSec: 30), "processAlive") : r.Enabled;
                var toggle = new ToolStripMenuItem(on ? "Выключить" : "Включить");
                toggle.Click += (s, e) => Safe(() => EnableRuntime(r, !on)); if (r.Definition.Name != "disk") item.DropDownItems.Add(toggle);
                foreach (var action in r.Definition.Menu) { var a = action; item.DropDownItems.Add(a.Title, null, (s, e) => RunAction(a)); }
                menu.Items.Add(item);
            }
            foreach (var a in definition.Menu) { var action = a; menu.Items.Add(a.Title, null, (s, e) => RunAction(action)); }
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Настройки…", null, (s,e) => ShowSettings()).Enabled = !actionBusy && !busy;
            if (!Product.IsVpn) {
                string accountState=Path.Combine(home,"state","happier-account.json");
                if(File.Exists(accountState)) { var last=Json.Read(accountState);menu.Items.Add(Json.Bool(last,"ok")?"Happier: последняя проверка "+Json.Str(last,"updatedUtc"):"Happier: подключение не подтверждено").Enabled=false; }
                menu.Items.Add("Резервные ключи Happier", null, (s,e) => Safe(() => Open(Path.Combine(home,"secrets"))));
                menu.Items.Add("Аккаунт Happier…", null, (s,e) => ShowSettings(3)).Enabled = !actionBusy && !busy;
                menu.Items.Add("Выбрать папки и файлы…", null, (s,e) => ShowSettings(2)).Enabled = !actionBusy && !busy;
            }
            if (!Product.IsVpn) menu.Items.Add("Открыть папку Disk", null, (s, e) => Safe(() => {
                string saved = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RemoteDisk", "base.txt");
                string path = Files.ReadLine(saved); if (path.Length == 0) path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Disk"); Open(path);
            }));
            var check = menu.Items.Add("Проверить обновления на сервере", null, (s, e) => CheckUpdates()); check.Enabled = !Product.IsVpn && Json.Bool(config.Update, "enabled") && !busy && !actionBusy && !engine.Pending && !MigrationPending();
            check.ToolTipText = "Только вручную и при update.enabled=true в config.json";
            menu.Items.Add(updateSummary).Enabled = false;
            string migrationFile = Path.Combine(home, "state", "migration.json");
            if (!Product.IsVpn && File.Exists(migrationFile)) {
                string phase = Json.Str(Json.Read(migrationFile), "phase");
                menu.Items.Add("Переход: " + (phase == "pending" ? "проверка связи; откат через 10 минут" : phase == "accepted" ? "подтверждён" : phase)).Enabled = false;
                if (phase == "pending") menu.Items.Add("Подтвердить установку (проверить связь)", null, (s, e) => CheckMigration(true));
            }
            menu.Items.Add("Журналы", null, (s, e) => Open(Path.Combine(home, "logs")));
            menu.Items.Add("Перезапустить компоненты", null, (s, e) => Safe(LoadComponents)).Enabled = !busy && !actionBusy;
            menu.Items.Add("Выход", null, (s, e) => ExitThread());
            var old = icon.ContextMenuStrip; icon.ContextMenuStrip = menu; if (old != null) old.Dispose();
        }
        async void CheckSetup()
        {
            if(actionBusy || busy || closing || MigrationPending())return;
            actionBusy=true;
            try {
                // Let supervised components publish their first live observation without showing a window.
                await Task.Delay(3000,stop.Token);
                if(await SetupWizard.CheckOnLaunch(home,engine.Folder(engine.Current))) {
                    if(Product.IsVpn){using(var run=Microsoft.Win32.Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"))run.SetValue("RemoteVPN",Files.Quote(Path.Combine(home,Product.ExeName))+" --tray --home "+Files.Quote(home));}
                    icon.ShowBalloonTip(5000,Product.Name,"Настройка проверена. Приложение работает в трее.",ToolTipIcon.Info);
                }
            }catch(OperationCanceledException){}catch{log.Write("setup.inspect.failed");}
            finally{actionBusy=false;ReloadSettings();}
        }
        void ReloadSettings()
        {
            try {var file=Path.Combine(home,"config.json");var written=File.GetLastWriteTimeUtc(file);if(written==settingsWritten)return;var latest=new Configuration(home).Data;config.Data.Clear();foreach(var pair in latest)config.Data[pair.Key]=pair.Value;settingsWritten=written;
                foreach(var runtime in runtimes.Where(r=>!r.Definition.CommandManaged)){bool enabled=config.Enabled(runtime.Definition);if(runtime.Enabled!=enabled)runtime.SetEnabled(enabled);}
            }catch{log.Write("setup.config.refresh.failed");}
        }
        void ShowSettings(int section = 0)
        {
            if (actionBusy || busy || closing) return; actionBusy = true;
            try { SetupWizard.Display(home,engine.Folder(engine.Current),false,section); }
            catch { log.Write("setup.feature.failed"); MessageBox.Show("Настройка не завершена. Проверьте журнал нужного шага.","RemoteAgents"); }
            finally {
                try {var latest=new Configuration(home).Data;config.Data.Clear();foreach(var pair in latest)config.Data[pair.Key]=pair.Value;
                    foreach(var runtime in runtimes.Where(r=>!r.Definition.CommandManaged)) {bool enabled=config.Enabled(runtime.Definition);if(runtime.Enabled!=enabled)runtime.SetEnabled(enabled);}
                } catch {log.Write("setup.config.refresh.failed");}
                actionBusy=false;
            }
        }
        void ShowStatus()
        {
            RefreshMenu(); SetForegroundWindow(dispatch.Handle); icon.ContextMenuStrip.Show(Cursor.Position);
        }
        string TransportScript(string name) { return Path.Combine(engine.Folder(engine.Current), "transport", name); }
        static ToolStripMenuItem Unavailable(ToolStripMenuItem item)
        { item.Enabled = false; item.ToolTipText = "модуль не установлен"; return item; }
        void AddTransportMenu(ContextMenuStrip menu)
        {
            menu.ShowItemToolTips = true;
            var status = StatusView.Read(home, "transport", maxAgeSec: 15);
            pathRow = menu.Items.Add(""); checkedRow = menu.Items.Add(""); networkRow = menu.Items.Add("");
            errorRow = menu.Items.Add(""); configErrorRow = menu.Items.Add(""); diskRow = menu.Items.Add(""); bridgeRow = menu.Items.Add("");
            foreach (var row in new[] { pathRow, checkedRow, networkRow, errorRow, configErrorRow, diskRow, bridgeRow }) row.Enabled = false;
            var paths = new ToolStripMenuItem("Путь к серверу"); pathsMenu = paths;
            bool installed = File.Exists(TransportScript("Set-TransportPath.ps1"));
            var auto = new ToolStripMenuItem("Автовыбор") { Checked = Json.Str(status, "mode") == "auto", Enabled = installed && !actionBusy };
            auto.Click += (s, e) => ScriptCommand("Set-TransportPath.ps1", new[] { "-Auto" }, false);
            if (!installed) Unavailable(auto); paths.DropDownItems.Add(auto);
            foreach (var candidate in StatusView.Candidates(status)) {
                string tag = Json.Str(candidate, "tag"), state = Json.Text(candidate, "state", "нет данных");
                var item = new ToolStripMenuItem(Json.Text(candidate, "title", tag) + " — " + state + "; " + StatusView.Speed(candidate)) {
                    Checked = Json.Str(status, "mode") == "pinned" && Json.Text(status, "pinnedTag", Json.Str(status, "active")) == tag,
                    Tag = tag, Enabled = installed && !actionBusy && state == "ok" && Json.Bool(candidate, "enabled", true) && tag.Length > 0
                };
                item.ToolTipText = Json.Str(candidate, "kind") + "; " + Json.Str(candidate, "via") + "; проверен: " + Json.Text(candidate, "checkedAt", "нет данных");
                item.Click += (s, e) => ScriptCommand("Set-TransportPath.ps1", new[] { "-Tag", tag }, false);
                if (!installed) Unavailable(item); paths.DropDownItems.Add(item);
            }
            string pinned = Json.Str(status, "pinnedTag");
            if (Json.Str(status, "mode") == "pinned" && pinned.Length > 0 && !StatusView.Candidates(status).Any(c => Json.Str(c, "tag") == pinned))
                paths.DropDownItems.Add(new ToolStripMenuItem(pinned + " — недоступен (нет в списке)") { Checked = true, Enabled = false, Tag = pinned });
            if (status.Count == 0) paths.DropDownItems.Add("нет данных").Enabled = false;
            menu.Items.Add(paths);
            var nodes = new ToolStripMenuItem("Узлы и пути");
            nodes.DropDownItems.Add("Открыть настройки", null, (s, e) => Safe(() => Process.Start(new ProcessStartInfo("notepad.exe", Files.Quote(config.PathName)) { UseShellExecute = true })));
            var list = new ToolStripMenuItem("Список путей") { Enabled = !actionBusy };
            list.Click += (s, e) => ScriptCommand("Edit-Transport.ps1", new[] { "-List" }, true);
            if (!File.Exists(TransportScript("Edit-Transport.ps1"))) Unavailable(list); nodes.DropDownItems.Add(list); if (!Product.IsVpn) menu.Items.Add(nodes);
            var vpn = runtimes.FirstOrDefault(r => r.Definition.Name == "vpn");
            var vpnItem = new ToolStripMenuItem("VPN (весь трафик)") { Checked = vpn != null && vpn.Enabled, Enabled = !actionBusy };
            vpnItem.ToolTipText = StatusView.Summary(StatusView.Read(home, "vpn", maxAgeSec: 15));
            vpnItem.Click += (s, e) => Safe(() => { if (vpn.Enabled) DisableVpn(vpn); else CheckVpn(vpn); });
            if (vpn == null || !File.Exists(TransportScript("Vpn.Tun.ps1")) || !File.Exists(TransportScript("Test-VpnConflict.ps1"))) Unavailable(vpnItem);
            vpnToggle = vpnItem; menu.Items.Add(vpnItem); vpnRow = menu.Items.Add(""); vpnRow.Enabled = false;
            menu.Items.Add(new ToolStripSeparator()); RefreshStatusRows();
        }
        void RefreshStatusRows()
        {
            if (pathRow == null) return;
            var status = StatusView.Read(home, "transport", maxAgeSec: 15);
            pathRow.Text = "Путь: " + StatusView.Title(status) + "; " + StatusView.Speed(status);
            checkedRow.Text = "Проверен: " + StatusView.CheckedAt(status) + "; режим: " + Json.Text(status, "mode", "нет данных");
            networkRow.Text = "Сеть: " + StatusView.Network(status) + "; лимитная: " + StatusView.Metered(status);
            errorRow.Text = "Связь: " + Json.Str(status, "error"); errorRow.Visible = Json.Str(status, "error").Length > 0;
            configErrorRow.Text = "Настройки: " + Json.Str(status, "configError"); configErrorRow.Visible = Json.Str(status, "configError").Length > 0;
            diskRow.Visible = bridgeRow.Visible = !Product.IsVpn; pathsMenu.Visible = !Product.IsVpn;
            diskRow.Text = "Диск: " + StatusView.Summary(StatusView.Read(home, "disk"));
            bridgeRow.Text = "Мост: " + StatusView.Summary(StatusView.Read(home, "control"));
            vpnRow.Text = "VPN: " + StatusView.Summary(StatusView.Read(home, "vpn", maxAgeSec: 15));
            var vpn = runtimes.FirstOrDefault(r => r.Definition.Name == "vpn");
            vpnToggle.Checked = vpn != null && vpn.Enabled;
            bool vpnInstalled = vpn != null && File.Exists(TransportScript("Vpn.Tun.ps1")) && File.Exists(TransportScript("Test-VpnConflict.ps1"));
            vpnToggle.Enabled = !actionBusy && vpnInstalled; vpnToggle.Visible = vpnRow.Visible = Product.IsVpn;
            vpnToggle.ToolTipText = vpnInstalled ? StatusView.Summary(StatusView.Read(home, "vpn", maxAgeSec: 15)) : "модуль не установлен";
            bool installed = File.Exists(TransportScript("Set-TransportPath.ps1"));
            foreach (ToolStripItem entry in pathsMenu.DropDownItems) {
                var item = entry as ToolStripMenuItem; if (item == null) continue;
                string tag = item.Tag as string;
                if (tag == null) { if (item.Text == "Автовыбор") { item.Checked = Json.Str(status, "mode") == "auto"; item.Enabled = installed && !actionBusy; } continue; }
                var candidate = StatusView.Candidates(status).FirstOrDefault(c => Json.Str(c, "tag") == tag);
                item.Enabled = installed && !actionBusy && candidate != null && Json.Str(candidate, "state") == "ok" && Json.Bool(candidate, "enabled", true);
                item.Checked = Json.Str(status, "mode") == "pinned" && Json.Text(status, "pinnedTag", Json.Str(status, "active")) == tag;
                item.Text = candidate == null ? tag + " — недоступен (нет данных)" : Json.Text(candidate, "title", tag) + " — " + Json.Text(candidate, "state", "нет данных") + "; " + StatusView.Speed(candidate);
            }
        }
        void EnableRuntime(ComponentRuntime runtime, bool enabled)
        {
            if (enabled && runtime.Definition.Elevated) {
                using (var task = new ElevatedTask(home, runtime.Definition.Name)) if (!task.Registered) {
                    if (MessageBox.Show("Компонент «" + runtime.Definition.Title + "» требует прав администратора. Сейчас Windows запросит разрешение создать задачу планировщика с наивысшими правами. Лаунчер продолжит работать с обычными правами. Создать задачу?", "RemoteAgents", MessageBoxButtons.YesNo, MessageBoxIcon.Information, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return;
                    task.Register();
                }
            }
            if (runtime.Definition.Name == "control") {
                var statePath = Path.Combine(home, "state", "migration.json");
                bool managed = File.Exists(statePath) && Json.Bool(Json.Read(statePath), "controlChanged");
                var args = new List<string> { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", Path.Combine(engine.Folder(engine.Current), "Start-WindowsControl.ps1"), enabled ? "-Install" : "-Uninstall" };
                if (managed) { args.Add("-LauncherHome"); args.Add(home); }
                // Install uses CIM for the long-lived bridge; let the lifecycle command finish independently.
                Process.Start(new ProcessStartInfo(Files.Executable("powershell.exe"), Files.Arguments(args)) { UseShellExecute = false, CreateNoWindow = true });
                config.SetEnabled(runtime.Definition, true); if (!runtime.Enabled) runtime.SetEnabled(true); RefreshMenu(); return;
            }
            config.SetEnabled(runtime.Definition, enabled); runtime.SetEnabled(enabled); RefreshMenu();
        }
        async void ScriptCommand(string script, string[] args, bool showOutput)
        {
            if (actionBusy || closing) return; actionBusy = true;
            try {
                string output = await Task.Run(() => CaptureScript(script, args));
                if (!closing && showOutput) ShowText("Список путей", output);
            } catch (OperationCanceledException) { }
            catch { if (!closing) { log.Write("transport.command.failed"); MessageBox.Show("Команда модуля не выполнена. Проверьте его наличие и журналы.", "RemoteAgents"); } }
            finally { actionBusy = false; if (!closing) RefreshMenu(); }
        }
        string CaptureScript(string script, string[] args)
        {
            string path = TransportScript(script); if (!File.Exists(path)) throw new FileNotFoundException();
            string output = Path.Combine(home, "state", "command-" + Guid.NewGuid().ToString("N") + ".tmp"); Directory.CreateDirectory(Path.GetDirectoryName(output));
            try {
                var argv = new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", path, "-Home", home }.Concat(args).ToArray();
                if (External.Run("powershell.exe", argv, engine.Folder(engine.Current), output, 120000, 4 * 1024 * 1024, stop.Token) != 0) throw new IOException();
                return Files.LF(External.ReadPowerShellOutput(output));
            } finally { if (File.Exists(output)) File.Delete(output); }
        }
        async void CheckVpn(ComponentRuntime vpn)
        {
            if (actionBusy || closing) return; actionBusy = true;
            try {
                if (Product.IsVpn && !Json.Bool(StatusView.Read(home, "transport", maxAgeSec: 15), "ok")) {
                    MessageBox.Show("Для VPN нужна проверенная связь с сервером. Установите и запустите RemoteAgents.exe; дождитесь подключения.", "RemoteVPN"); return;
                }
                while (!closing) {
                    var result = Json.Map(Json.Parse(await Task.Run(() => CaptureScript("Test-VpnConflict.ps1", new string[0]))));
                    if (closing) return;
                    var items = Json.Get(result, "items");
                    if (!(Json.Get(result, "conflict") is bool) || !(items is System.Collections.IEnumerable) || items is string || items is System.Collections.IDictionary) throw new InvalidDataException();
                    if (!Json.Bool(result, "conflict")) {
                        if (vpn.Definition.CommandManaged) {
                            config.SetEnabled(vpn.Definition, true);
                            await Task.Run(() => CaptureScript("Vpn.Tun.ps1", new[] { "-Enable", "-ParentPid", Process.GetCurrentProcess().Id.ToString() }));
                        } else EnableRuntime(vpn, true);
                        return;
                    }
                    string found = string.Join("; ", Json.Array(Json.Get(result, "items")).Select(x => { var item = Json.Map(x); return string.Join(" — ", new[] { Json.Str(item, "kind"), Json.Str(item, "name"), Json.Str(item, "path"), Json.Str(item, "detail") }.Where(v => v.Length > 0)); }));
                    if (!VpnConflictDialog(found)) return;
                }
            } catch (OperationCanceledException) { }
            catch { if (vpn.Definition.CommandManaged) try { config.SetEnabled(vpn.Definition, false); } catch { log.Write("vpn.config.failed"); }
                if (!closing) { log.Write("vpn.conflict.check.failed"); MessageBox.Show("Проверить наличие другого VPN не удалось. VPN RemoteAgents не включён.", "RemoteAgents"); } }
            finally { actionBusy = false; if (!closing) RefreshMenu(); }
        }
        async void DisableVpn(ComponentRuntime vpn)
        {
            if (!vpn.Definition.CommandManaged) { Safe(() => EnableRuntime(vpn, false)); return; }
            if (actionBusy || closing) return; actionBusy = true;
            try { config.SetEnabled(vpn.Definition, false); await Task.Run(() => CaptureScript("Vpn.Tun.ps1", new[] { "-Disable" })); }
            catch (OperationCanceledException) { }
            catch { if (!closing) MessageBox.Show("Запрос выключения VPN не выполнен. Проверьте статус и журналы; выключение ещё не подтверждено.", "RemoteAgents"); }
            finally { actionBusy = false; if (!closing) RefreshMenu(); }
        }
        static bool VpnConflictDialog(string found)
        {
            using (var form = new Form { Text = "RemoteAgents — другой VPN", Width = 640, Height = 290, StartPosition = FormStartPosition.CenterScreen, MinimizeBox = false, MaximizeBox = false }) {
                var text = new TextBox { Multiline = true, ReadOnly = true, Dock = DockStyle.Fill, ScrollBars = ScrollBars.Vertical, Text = "У вас уже работает VPN: " + (found.Length == 0 ? "нет данных о названии" : found) + ". Чтобы включить VPN RemoteAgents, отключите его сами. Если хотите остаться на нём — нажмите «Оставить как есть»." };
                var buttons = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 48, FlowDirection = FlowDirection.RightToLeft };
                var leave = new Button { Text = "Оставить как есть", AutoSize = true, DialogResult = DialogResult.Cancel };
                var retry = new Button { Text = "Проверить снова", AutoSize = true, DialogResult = DialogResult.Retry };
                buttons.Controls.Add(leave); buttons.Controls.Add(retry); form.Controls.Add(text); form.Controls.Add(buttons); form.CancelButton = leave; form.AcceptButton = leave;
                return form.ShowDialog() == DialogResult.Retry;
            }
        }
        static void ShowText(string title, string text)
        {
            var form = new Form { Text = "RemoteAgents — " + title, Width = 760, Height = 480, StartPosition = FormStartPosition.CenterScreen };
            form.Controls.Add(new TextBox { Text = text.Length == 0 ? "нет данных" : text, ReadOnly = true, Multiline = true, ScrollBars = ScrollBars.Both, WordWrap = false, Dock = DockStyle.Fill }); form.Show();
        }
        bool MigrationPending()
        {
            string file = Path.Combine(home, "state", "migration.json");
            return File.Exists(file) && new[] { "preparing", "activating", "pending", "rolling-back" }.Contains(Json.Str(Json.Read(file), "phase"));
        }
        void CheckUpdates()
        {
            if (busy || actionBusy || closing || engine.Pending || MigrationPending() || !Json.Bool(config.Update, "enabled")) return; busy = true; updateSummary = "проверка обновлений";
            RefreshMenu();
            // Freeze the config snapshot before moving work off the UI thread.
            var snapshot = Json.Encode(config.Update);
            worker = Task.Run(() => {
                string ready = null; string message = "обновлений нет";
                try {
                    var source = SshSource.Load(Configuration.ForUpdate(snapshot), home); var m = source.Manifest(home, stop.Token);
                    if (Files.Compare(m.Minimum, Program.Version) > 0) message = "нужна более новая версия лаунчера";
                    else if (engine.IsBad(m.Version)) message = "версия ранее отклонена";
                    else ready = engine.Prepare(m, p => source.Fetch(m.FileName, p, m.Size, stop.Token), f => External.SelfTest(f, home, stop.Token),
                        (d, f) => UpdateEngine.InstallBinaries(d, f, home, stop.Token), stop.Token);
                    log.Write(ready == null ? "update.check.complete" : "update.prepared");
                } catch (OperationCanceledException) { return; }
                catch { message = "обновление не проверено: нет профиля, связи или проверка не прошла"; log.Write("update.check.failed"); }
                if (stop.IsCancellationRequested) return;
                try { dispatch.BeginInvoke(new Action(() => {
                    if (closing) return; busy = false; updateSummary = message;
                    if (ready != null) Safe(() => { serverUpdateRequested = true; engine.Activate(ready); LoadComponents(); updateSummary = "ожидание здоровья компонентов (120 с)"; });
                    RefreshMenu();
                })); } catch (InvalidOperationException) { }
            });
        }
        void RunAction(MenuAction action)
        {
            Safe(() => {
                var job = new NativeJob();
                try {
                    Func<string, string> expand = s => Environment.ExpandEnvironmentVariables(s.Replace("{bundle}", engine.Folder(engine.Current)).Replace("{home}", home).Replace("{pid}", Process.GetCurrentProcess().Id.ToString()));
                    using (var p = job.Start(expand(action.Exe), action.Args.Select(expand).ToArray(), engine.Folder(engine.Current))) { }
                    actionJobs.Add(job);
                } catch { job.Dispose(); throw; }
            });
        }
        bool TrySelfUpdate()
        {
            string path = Path.Combine(engine.Folder(engine.Current), ".launcher-manifest.json");
            if (!File.Exists(path)) return false;
            var m = Manifest.Parse(File.ReadAllText(path)); if (m.LauncherVersion.Length == 0 || Files.Compare(m.LauncherVersion, Program.Version) <= 0) return false;
            string source = Path.Combine(engine.Folder(engine.Current), Product.ExeName);
            if (!File.Exists(source) || !Files.Hash(source).Equals(m.LauncherHash, StringComparison.OrdinalIgnoreCase) ||
                Files.Compare(FileVersionInfo.GetVersionInfo(source).FileVersion, m.LauncherVersion) != 0) { log.Write("launcher.update.invalid"); return false; }
            string target = Program.Exe, old = Path.Combine(Path.GetDirectoryName(target), Product.Name + ".old.exe"), temp = target + ".new";
            if (File.Exists(old)) return false; // previous image is still exiting
            try {
                if (!Product.IsVpn && LauncherRecovery.Accepted(home)) Files.Atomic(LauncherRecovery.Intent(home), "restart\n");
                File.Copy(source, temp, true);
                using (var flush = new FileStream(temp, FileMode.Open, FileAccess.Write, FileShare.Read)) flush.Flush(true);
                File.Move(target, old);
                try { File.Move(temp, target); } catch { File.Move(old, target); throw; }
                log.Write("launcher.update.ready"); RestartRequested = true; ExitThread(); return true;
            } catch { log.Write("launcher.update.failed"); return false; }
        }
        void TryDeleteOld()
        {
            foreach (string name in new[] { Product.Name + ".old.exe", Product.ExeName + ".retired" })
                try { string old = Path.Combine(Path.GetDirectoryName(Program.Exe), name); if (File.Exists(old)) File.Delete(old); } catch { }
        }
        void Listen(string name, SecurityIdentifier sid)
        {
            var security = new PipeSecurity(); security.SetAccessRuleProtection(true, false); security.AddAccessRule(new PipeAccessRule(sid, PipeAccessRights.FullControl, AccessControlType.Allow));
            while (!stop.IsCancellationRequested) {
                try {
                    using (var pipe = new NamedPipeServerStream(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous, 4096, 4096, security)) {
                        lock (pipeGate) { if (stop.IsCancellationRequested) return; server = pipe; }
                        pipe.WaitForConnection();
                        // Bound command size and client time to avoid blocking all subsequent launches.
                        var read = Task.Run(() => {
                            using (var reader = new StreamReader(pipe, Files.Utf8, true, 4096, true)) { var text = new System.Text.StringBuilder(); int c;
                                while ((c = reader.Read()) >= 0 && c != '\n') { if (text.Length >= 32768) throw new InvalidDataException(); text.Append((char)c); }
                                return Json.Strings(Json.Parse(text.ToString()));
                            }
                        });
                        if (read.Wait(5000) && !stop.IsCancellationRequested) {
                            if (read.Result.Contains("--identify")) {
                                using (var writer = new StreamWriter(pipe, Files.Utf8, 4096, true)) { writer.WriteLine(Json.Encode(new { pid = Process.GetCurrentProcess().Id, home, launcherVersion = Program.Version, bundleVersion = engine.Current })); writer.Flush(); }
                            } else { commands.Enqueue(read.Result); if (readyForCommands) dispatch.BeginInvoke(new Action(DrainCommands)); }
                        }
                    }
                } catch { if (!stop.IsCancellationRequested) { log.Write("ipc.receive.failed"); if (stop.Token.WaitHandle.WaitOne(200)) break; } }
                finally { lock (pipeGate) server = null; }
            }
        }
        void DrainCommands() { string[] command; while (!closing && commands.TryDequeue(out command)) Handle(command); }
        void Handle(string[] args)
        {
            Safe(() => {
                if (args.Contains("--settings")) { ShowSettings(); return; }
                if (args.Contains("--confirm-install")) { CheckMigration(true); return; }
                if (args.Contains("--exit") || args.Contains("--uninstall")) { installStop = args.Contains("--install-stop"); ExitThread(); return; }
                if (args.Contains("--restart-components")) { if (busy || actionBusy) throw new InvalidOperationException(); LoadComponents(); }
                if (args.Contains("--rollback")) { if (busy || actionBusy || MigrationPending()) throw new InvalidOperationException(); engine.Rollback(); LoadComponents(); log.Write("update.rollback.manual"); }
                if (args.Contains("--logs")) Open(Path.Combine(home, "logs"));
                if (args.Contains("--show")) ShowStatus();
                if (args.Contains("--setup-check")) CheckSetup();
            });
        }
        void Safe(Action action) { try { action(); } catch { log.Write("user.command.failed"); MessageBox.Show("Действие не выполнено. Подробности состояния — в папке RemoteAgents и журнале лаунчера.", "RemoteAgents"); } }
        static void Open(string path) { Process.Start(new ProcessStartInfo("explorer.exe", Files.Quote(path)) { UseShellExecute = true }); }
        static Icon MakeIcon(Color color)
        {
            using (var bitmap = new Bitmap(32, 32)) using (var graphics = Graphics.FromImage(bitmap)) using (var brush = new SolidBrush(color)) {
                graphics.Clear(Color.Transparent); graphics.FillEllipse(brush, 2, 2, 28, 28); IntPtr handle = bitmap.GetHicon();
                try { return (Icon)Icon.FromHandle(handle).Clone(); } finally { DestroyIcon(handle); }
            }
        }
        [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr handle);
        [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr handle);
        protected override void ExitThreadCore()
        {
            if (closing) return; closing = true; timer.Stop(); stop.Cancel();
            lock (pipeGate) { if (server != null) server.Dispose(); }
            foreach (var r in runtimes) r.Dispose(); foreach (var job in actionJobs) job.Dispose();
            try { WriteStatus(); } catch { log.Write("status.write.failed"); }
            log.Write("launcher.exit"); icon.Visible = false; icon.Dispose(); timer.Dispose();
            green.Dispose(); yellow.Dispose(); red.Dispose(); dispatch.Dispose(); base.ExitThreadCore();
        }
    }
}
