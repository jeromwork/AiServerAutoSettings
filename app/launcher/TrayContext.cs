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
        ConfigWindow mainWindow;
        WindowModel window;
        readonly ConfigSyncSchedule syncSchedule = new ConfigSyncSchedule();
        bool syncRunning, accountResuming, serverHealthRunning;
        readonly ServerHealthSchedule healthSchedule = new ServerHealthSchedule();
        string syncSummary = "Сверка конфига: ожидается подтверждённая связь";
        readonly Icon green = MakeIcon(Color.ForestGreen), yellow = MakeIcon(Color.Goldenrod), red = MakeIcon(Color.Firebrick);
        readonly object pipeGate = new object(); NamedPipeServerStream server; Task worker, pipeWorker;
        readonly ConcurrentQueue<string[]> commands = new ConcurrentQueue<string[]>(); volatile bool readyForCommands;
        string installSource; readonly bool firstSetup; BundleDefinition definition; bool busy, closing, ticking, actionBusy, serverUpdateRequested;
        DateTime settingsWritten = DateTime.MinValue;
        // Detached server installs started by the wizard (state/server-operations.json).
        DateTime nextOperationCheck = DateTime.MinValue; bool operationChecking, operationsActive; string operationTip = "";
        string updateSummary = "обновления устанавливаются вручную из нового EXE";
        public bool RestartRequested { get; private set; }
        public TrayContext(string home, Journal log, string pipeName, SecurityIdentifier sid, string[] args, string installSource = null)
        {
            this.home = home; this.log = log; this.installSource=installSource;
            window = new WindowModel(File.Exists(Path.Combine(home, "state", "tray-hint-shown"))); dispatch.CreateControl(); var unused = dispatch.Handle;
            Directory.CreateDirectory(Path.Combine(home, "status"));
            config = new Configuration(home); engine = new UpdateEngine(home, Program.Version);
            firstSetup = Path.GetFullPath(home).Equals(Path.GetFullPath(Program.DefaultHome),StringComparison.OrdinalIgnoreCase) && FirstInstall.Required(home);
            // Accept secondary launches while first-install selftest / binary downloads are still running.
            pipeWorker = Task.Run(() => Listen(pipeName, sid));
            try {
                icon = new NotifyIcon { Visible = !firstSetup, Icon = yellow, Text = Product.Name + ": запускается…" };
                icon.MouseClick += (s, e) => { if (e.Button == MouseButtons.Left) ShowMain(); };
                icon.MouseDoubleClick += (s, e) => { if (e.Button == MouseButtons.Left) ShowMain(); };
                if (!firstSetup) { engine.Recover(); Bootstrap(); LoadComponents(); }
            } catch {
                stop.Cancel(); lock (pipeGate) { if (server != null) server.Dispose(); }
                if (icon != null) { icon.Visible = false; icon.Dispose(); }
                throw;
            }
            readyForCommands = true;
            timer.Tick += (s, e) => Tick(); timer.Start();
            dispatch.BeginInvoke(new Action(() => {
                if (firstSetup) { RunFirstSetup(); return; }
                Handle(args); DrainCommands(); Tick();
                if(Path.GetFullPath(home).Equals(Path.GetFullPath(Program.DefaultHome),StringComparison.OrdinalIgnoreCase)) CheckSetup();

            }));
        }
        void RunFirstSetup()
        {
            actionBusy=true;
            try {
                // ShowDialog paints the wizard before its Shown handler starts any bundle work.
                Func<Task<string>> prepare=async()=> {
                    worker=Task.Run(()=> {engine.Recover();Bootstrap();});await worker;
                    if(closing)throw new OperationCanceledException();
                    ReloadSettings();LoadComponents();return engine.Folder(engine.Current);
                };
                // One preparation for both windows: «Пройти по шагам» reuses the bundle the config window prepared.
                Task<string> prepared=null;
                Func<Task<string>> once=()=>{if(prepared==null || prepared.IsFaulted || prepared.IsCanceled)prepared=prepare();return prepared;};
                if(!Product.IsVpn) {
                    bool manual=ConfigWindow.First(home,once);
                    if(manual && !closing)SetupWizard.Display(home,null,true,prepare:once);
                } else SetupWizard.Display(home,null,true,prepare:prepare);
            } finally {actionBusy=false;}
            if(closing)return;
            if(FirstInstall.Required(home)){ExitThread();return;}
            ReloadSettings();icon.Visible=true;readyForCommands=true;ShowMain();
            if(Product.IsVpn)Safe(RegisterVpnRun);
            DrainCommands();Tick();
        }
        void Bootstrap()
        {
            if (installSource==null && engine.Current.Length != 0) { BundleDefinition.Load(engine.Folder(engine.Current)); return; }
            string zip = Path.Combine(engine.Root, "embedded.zip");
            try {
                string version = UpgradeInstaller.ExtractEmbedded(zip);
                if(installSource!=null) {
                    string current=engine.Current;
                    if(File.Exists(Path.Combine(home,Product.ExeName)) && current.Length>0 && UpgradeInstaller.Compare(Program.Version,version,FileVersionInfo.GetVersionInfo(Path.Combine(home,Product.ExeName)).FileVersion,current)<0)
                        throw new InvalidDataException("Для отката сначала завершите настройку установленной версии");
                    // Reopening the same downloaded EXE resumes setup without starting an upgrade health deadline.
                    string target=Path.Combine(home,Product.ExeName);
                    if(current==version && File.Exists(target) && Files.Hash(target)==Files.Hash(installSource)) {
                        BundleDefinition.Load(engine.Folder(current));installSource=null;log.Write("bundle.bootstrap.resume");return;
                    }
                    // Unfinished first setup has no healthy components to wait for; a 120 s deadline would roll the new EXE back.
                    UpgradeInstaller.Apply(home,installSource,zip,Program.Version,false,f=>External.SelfTest(f,home,stop.Token),stop.Token,accept:true);
                    installSource=null;log.Write("bundle.bootstrap.ok");return;
                }
                var manifest = Manifest.Parse(Json.Encode(new { version, file = "embedded.zip", sha256 = Files.Hash(zip), size = new FileInfo(zip).Length, minLauncher = Program.Version }));
                string ready = engine.Prepare(manifest, p => File.Copy(zip, p, true), f => External.SelfTest(f, home, stop.Token), (d, f) => UpdateEngine.InstallBinaries(d, f, home, stop.Token), stop.Token, downgrade: true);
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
            foreach (var c in definition.Components) runtimes.Add(new ComponentRuntime(c, Wanted(c), home, engine.Folder(engine.Current), log));
            var vpn = definition.Components.FirstOrDefault(c => c.Name == "vpn" && c.CommandManaged);
            if (vpn != null && !File.Exists(Path.Combine(home, "status", "vpn.json")) && File.Exists(TransportScript("Vpn.Tun.ps1"))) RunAction(new MenuAction { Exe = vpn.Exe, Args = vpn.Args });
            RefreshMenu();
        }
        bool Wanted(Component c) { return config.Wanted(c); }
        void Tick()
        {
            if (closing || ticking || definition == null) return; ticking = true;
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
                } else {
                    icon.Icon = transport.Count == 0 ? yellow : Json.Bool(transport, "ok") ? green : red;
                    icon.Text = TrayMenuModel.Tooltip(transport, ServerHealthView.Read(home));
                }
                if (Product.IsVpn && operationTip.Length > 0) icon.Text = TrayMenuModel.Short(operationTip, 63);
                if (DateTime.UtcNow >= nextOperationCheck) CheckOperations();
                RefreshMenu(); WriteStatus();
                CheckSync(); CheckServerHealth();
                if (serverUpdateRequested && !engine.Pending && MutationConflict().Length == 0 && TrySelfUpdate()) return;
            } catch { log.Write("supervisor.tick.failed"); icon.Icon = red; }
            finally { ticking = false; }
        }
        // Tooltip «Идёт установка: x из y» and a «Готово» balloon. While the wizard window is closed the tray
        // follows the installs itself (short status call every 15 s) and connects a saved Happier key.
        async void CheckOperations()
        {
            if (operationChecking || closing) return; operationChecking = true; nextOperationCheck = DateTime.UtcNow.AddSeconds(15);
            try {
                var state = ServerOperations.Load(home); var list = ServerOperations.FromState(state);
                bool windowPolls = (DateTime.UtcNow - ServerOperations.Updated(state)).TotalSeconds < 30;
                if (ServerOperations.Active(list) && !windowPolls && !actionBusy && !syncRunning && (mainWindow == null || !mainWindow.IsApplying) && engine.Current.Length != 0) {
                    string bundle = engine.Folder(engine.Current); var tracked = Json.Strings(Json.Get(state, "tracked"));
                    var names = tracked.Concat(Json.Bool(state, "pendingAccount") ? new[] { "happier" } : new string[0]).Distinct().ToArray();
                    var result = await Task.Run(() => ServerOperations.Invoke(home, bundle, "Operation", new { operations = names }, stop.Token));
                    var operations = Json.Map(Json.Get(result, "operations")); bool pending = Json.Bool(result, "pendingAccount");
                    if (pending && Json.Str(Json.Map(Json.Get(operations, "happier")), "state") == "finished" && MutationConflict().Length == 0) {
                        try {
                            accountResuming = true;
                            var account = await Task.Run(() => ServerOperations.Invoke(home, bundle, "ResumeAccount", new { }, stop.Token));
                            if (Json.Bool(account, "ok")) { pending = false; icon.ShowBalloonTip(5000, Product.Name, "Happier: " + Json.Text(account, "summary", "аккаунт подключён"), ToolTipIcon.Info); }
                        } catch (OperationCanceledException) { throw; } catch (Exception) { log.Write("operations.account.failed"); pending = false; icon.ShowBalloonTip(10000, Product.Name, "Happier: аккаунт не подключён. Откройте «Подробно» → Happier.", ToolTipIcon.Warning); }
                        finally { accountResuming = false; }
                    }
                    ServerOperations.Save(home, tracked, operations, pending);
                    list = ServerOperations.FromState(ServerOperations.Load(home));
                }
                bool active = ServerOperations.Active(list);
                operationTip = active ? ServerOperations.Tooltip(list) : "";
                if (operationsActive && !active) {
                    var failed = list.Where(o => o.State == "failed").ToArray();
                    if (failed.Length == 0) icon.ShowBalloonTip(5000, Product.Name, "Готово: установка на сервере завершена", ToolTipIcon.Info);
                    else icon.ShowBalloonTip(10000, Product.Name, failed[0].Title + ": " + ServerOperations.Line(failed[0]) + ". «Повторить» — в «Настройки» → «Установка».", ToolTipIcon.Warning);
                }
                operationsActive = active;
            } catch (OperationCanceledException) { } catch (Exception) { log.Write("operations.check.failed"); }
            finally { operationChecking = false; }
        }
        async void CheckSync()
        {
            if(Product.IsVpn || !Json.Bool(Json.Map(Json.Get(config.Data,"wizard")),"configured") || !Json.Map(Json.Get(config.Data,"profile")).ContainsKey("server"))return;
            bool connected=Json.Bool(StatusView.Read(home,"transport",maxAgeSec:15),"ok");
            bool occupied = syncRunning || actionBusy || busy || closing || operationChecking || mainWindow != null && mainWindow.IsApplying;
            if (!syncSchedule.Due(connected, DateTime.UtcNow, occupied)) return;
            syncRunning=true; syncSchedule.Started(DateTime.UtcNow);
            syncSummary="Сверка конфига: выполняется в фоне";
            string bundle = engine.Folder(engine.Current);
            try {
                Dictionary<string, object> result = null;
                await Task.Run(() => { result = ServerOperations.Invoke(home,bundle,"ConfigSync",new {askpassExecutable=Program.Exe},stop.Token); });
                if (!Json.Bool(result, "ok")) throw new IOException(Json.Text(result, "summary", "сервер не подтвердил сверку"));
                syncSummary="Сверка конфига: " + Json.Text(result,"summary",Json.Bool(result,"changed") ? "конфиг обновлён" : "конфиг актуален");
                log.Write(Json.Bool(result,"changed")?"config.sync.updated":"config.sync.current");
            } catch(OperationCanceledException) { }
            catch(Exception e) {
                string reason = e.Message.Replace("\r", " ").Replace("\n", " ");
                syncSummary="Сверка конфига недоступна: " + reason;
                log.Write("config.sync.unavailable " + reason);
            } finally { syncRunning=false; if (!closing) { ReloadSettings(); RefreshMain(); } }
        }
        async void CheckServerHealth()
        {
            if (Product.IsVpn || closing || engine.Current.Length == 0) return;
            bool occupied = serverHealthRunning || syncRunning || actionBusy || busy || operationChecking || mainWindow != null && mainWindow.IsApplying;
            if (!healthSchedule.Due(DateTime.UtcNow, Json.Bool(StatusView.Read(home, "transport", maxAgeSec: 15), "ok"), occupied)) return;
            serverHealthRunning = true; healthSchedule.Started(DateTime.UtcNow);
            string bundle = engine.Folder(engine.Current);
            try {
                await Task.Run(() => ServerOperations.Invoke(home, bundle, "ServerHealth", new { }, stop.Token));
                log.Write("server.health.complete");
            } catch (OperationCanceledException) { }
            catch (Exception) {
                // The outer ten-second budget may kill PowerShell before it can save its failure.
                if (!closing) Json.Write(Path.Combine(home, "state", "server-health.json"), new { schema = 1, ok = false, updatedUtc = DateTime.UtcNow.ToString("o"), summary = "Состояние сервера не получено: проверьте связь" });
                log.Write("server.health.unavailable");
            } finally { serverHealthRunning = false; if (!closing) RefreshMenu(); }
        }
        void WriteStatus()
        {
            Json.Write(Path.Combine(home, "status", Product.StatusName), new { schema = 1, pid = Process.GetCurrentProcess().Id, launcherVersion = Program.Version, bundleVersion = engine.Current,
                previousVersion = engine.Previous, pending = engine.Pending, running = !closing, updatedUtc = DateTime.UtcNow.ToString("o"), update = updateSummary,
                ok = !closing && (Product.IsVpn ? VpnModulesReady() : runtimes.Any(r => r.Definition.Critical) && runtimes.Where(r => r.Definition.Critical).All(r => r.Healthy)), components = runtimes.Select(r => r.Snapshot()).ToArray() });
        }
        void RefreshMenu()
        {
            if (icon.ContextMenuStrip == null) {
                var menu = new ContextMenuStrip { ShowItemToolTips = true };
                if (Product.IsVpn) {
                    menu.Items.Add("Открыть", null, (s, e) => ShowMain());
                    menu.Items.Add("Выход", null, (s, e) => RequestExit());
                } else foreach (var entry in TrayEntries()) {
                    if (entry.Id == "separator") { menu.Items.Add(new ToolStripSeparator()); continue; }
                    string id = entry.Id;
                    var item = new ToolStripMenuItem(entry.Text) { Enabled = entry.Enabled, ToolTipText = entry.Hint };
                    item.Click += (s, e) => Safe(() => {
                        if (id == "open") ShowMain();
                        else if (id == "folders") ShowMain(true);
                        else if (id == "happier") {
                            string url = TrayMenuModel.HappierUrl(config.Data, AccountState());
                            if (url.Length > 0) Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
                        } else if (id == "exit") RequestExit();
                    });
                    menu.Items.Add(item);
                }
                icon.ContextMenuStrip = menu;
            }
            if (!Product.IsVpn) {
                var entries = TrayEntries();
                for (int i = 0; i < entries.Length; i++) {
                    if (entries[i].Id == "separator") continue;
                    var item = icon.ContextMenuStrip.Items[i]; item.Text = entries[i].Text; item.Enabled = entries[i].Enabled; item.ToolTipText = entries[i].Hint;
                }
            }
            RefreshMain();
        }
        Dictionary<string, object> AccountState()
        { try { return Json.Read(Path.Combine(home, "state", "happier-account.json")); } catch { return Json.Map(null); } }
        TrayMenuEntry[] TrayEntries()
        { return TrayMenuModel.Build(config.Data, AccountState(), StatusView.Read(home, "transport", maxAgeSec: 15), ServerHealthView.Read(home)); }
        bool Configured()
        { return Json.Bool(Json.Map(Json.Get(new Configuration(home).Data, "wizard")), "configured"); }
        void RegisterVpnRun()
        { using(var run=Microsoft.Win32.Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"))run.SetValue("RemoteVPN",Files.Quote(Path.Combine(home,Product.ExeName))+" --tray --home "+Files.Quote(home)); }
        async void CheckSetup()
        {
            if(actionBusy || busy || closing )return;
            // Sign-in is quiet; an explicit human launch is routed separately to the main window.
            bool configured=false;try{configured=Configured();}catch{log.Write("setup.config.read.failed");}
            if(configured){if(Product.IsVpn)Safe(RegisterVpnRun);else WatchHealth();return;}
            actionBusy=true;
            try {
                // Let supervised components publish their first live observation without showing a window.
                await Task.Delay(3000,stop.Token);
                if(!Product.IsVpn){
                    // Not configured: the paste window (it resumes a config pasted earlier; «Пройти по шагам» stays available).
                    string bundle=engine.Folder(engine.Current);
                    if(ConfigWindow.First(home,()=>Task.FromResult(bundle)) && !closing)SetupWizard.Display(home,bundle,true);
                    if(!closing && Configured())ShowMain();
                    return;
                }
                string outcome=await SetupWizard.CheckOnLaunch(home,engine.Folder(engine.Current));
                // null: setup still incomplete; "": everything already ready, nothing changed.
                if(Product.IsVpn && outcome!=null)RegisterVpnRun();
                if(!closing && !string.IsNullOrEmpty(outcome))icon.ShowBalloonTip(5000,Product.Name,outcome,ToolTipIcon.Info);
            }catch(OperationCanceledException){}catch{log.Write("setup.inspect.failed");}
            finally{actionBusy=false;ReloadSettings();}
        }
        bool healthWatching;
        async void WatchHealth()
        {
            // Boot can take a while (network, Syncthing): retry quietly before reporting once.
            if (healthWatching) return; healthWatching = true;
            try {
                for(int i=0;i<20 && !closing;i++){
                    await Task.Delay(15000,stop.Token);
                    if(Json.Bool(StatusView.Read(home,"transport",maxAgeSec:15),"ok")){
                        var vpn=runtimes.FirstOrDefault(r=>r.Definition.Name=="vpn");
                        var wantedVpn=Json.Map(Json.Get(Json.Map(Json.Get(config.Data,"profile")),"vpn"));
                        if(vpn!=null && Json.Bool(wantedVpn,"enabled") && !vpn.Healthy)CheckVpn(vpn);
                        return;
                    }
                }
                if(!closing){log.Write("setup.health.unconfirmed");icon.ShowBalloonTip(10000,Product.Name,"Связь с сервером не подтверждена за 5 минут. Откройте RemoteAgents и проверьте состояние.",ToolTipIcon.Warning);}
            }catch(OperationCanceledException){}
            finally{healthWatching=false;}
        }
        void ReloadSettings()
        {
            try {var file=Path.Combine(home,"config.json");var written=File.GetLastWriteTimeUtc(file);if(written==settingsWritten)return;var latest=new Configuration(home).Data;config.Data.Clear();foreach(var pair in latest)config.Data[pair.Key]=pair.Value;settingsWritten=written;
                foreach(var runtime in runtimes.Where(r=>!r.Definition.CommandManaged)){bool enabled=Wanted(runtime.Definition);if(runtime.Enabled!=enabled)runtime.SetEnabled(enabled);}
            }catch{log.Write("setup.config.refresh.failed");}
        }
        void ShowMain(bool folders = false)
        {
            if (closing) return;
            // During first installation the existing paste/step window remains the only window.
            if (FirstInstall.Required(home)) {
                var setup = Application.OpenForms.Cast<Form>().FirstOrDefault(f => f is ConfigWindow || f is SetupWizard);
                if (setup != null) ActivateWindow(setup); else CheckSetup();
                return;
            }
            if (mainWindow == null || mainWindow.IsDisposed) {
                mainWindow = ConfigWindow.Main(home, engine.Folder(engine.Current));
                mainWindow.MutationConflict = MutationConflict;
                mainWindow.HiddenToTray = () => {
                    if (window.CloseToTray()) {
                        Safe(() => Files.Atomic(Path.Combine(home, "state", "tray-hint-shown"), "shown\n"));
                        icon.ShowBalloonTip(8000, Product.Name, "RemoteAgents работает — значок в трее", ToolTipIcon.Info);
                    }
                };
                mainWindow.ServiceActions(new[] {
                    Service("Открыть папку Disk", OpenDisk),
                    Service("Журналы", () => Open(Path.Combine(home, "logs"))),
                    Service("Резервные ключи Happier", () => Open(Path.Combine(home, "secrets"))),
                    Service("Аккаунт Happier", () => mainWindow.OpenDetails(3)),
                    Service("Проверить обновления на сервере", CheckUpdates),
                    Service("Перезапустить компоненты", () => { if (AllowMutation()) LoadComponents(); }),
                    Service("Узлы и пути", () => mainWindow.OpenDetails(1)),
                    Service("Список путей", () => ScriptCommand("Edit-Transport.ps1", new[] { "-List" }, true))
                }, tag => ScriptCommand("Set-TransportPath.ps1", tag.Length == 0 ? new[] { "-Auto" } : new[] { "-Tag", tag }, false));
            }
            window.Show(); RefreshMain(); if (folders) mainWindow.OpenFolders(); ActivateWindow(mainWindow);
        }
        KeyValuePair<string, Action> Service(string title, Action action)
        { return new KeyValuePair<string, Action>(title, () => Safe(action)); }
        static void ActivateWindow(Form form)
        {
            if (!form.Visible) form.Show();
            if (form.WindowState == FormWindowState.Minimized) form.WindowState = FormWindowState.Normal;
            form.BringToFront(); form.Activate(); SetForegroundWindow(form.Handle);
        }
        void OpenDisk()
        {
            string saved = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RemoteDisk", "base.txt");
            string path = Files.ReadLine(saved); if (path.Length == 0) path = ConfigSession.DiskBase(); Open(path);
        }
        string MutationConflict()
        {
            string operation = syncRunning ? "сверка конфига" : busy ? "обновление" : actionBusy ? "настройка компонентов" : accountResuming ? "подключение аккаунта Happier" : mainWindow != null && mainWindow.IsApplying ? "применение настроек" : "";
            return WindowModel.Conflict(operation);
        }
        bool AllowMutation()
        {
            string conflict = MutationConflict();
            if (conflict.Length == 0) return !closing;
            if (!closing) MessageBox.Show(mainWindow, conflict, Product.Name);
            return false;
        }
        void RefreshMain()
        {
            if (mainWindow == null || mainWindow.IsDisposed) return;
            var transport = StatusView.Read(home, "transport", maxAgeSec: 15);
            mainWindow.UpdateMain(new[] {
                StatusView.Line("Связь с сервером", transport, true),
                ServerHealthView.Summary(ServerHealthView.Read(home)),
                StatusView.Line("Управление компьютером (мост)", StatusView.Read(home, "control", maxAgeSec: 30)),
                StatusView.Happier(home),
                StatusView.Line("Диск", StatusView.Read(home, "disk", maxAgeSec: 30)),
                StatusView.Line("VPN", StatusView.Read(home, "vpn", maxAgeSec: 15))
            }, syncSummary + "\r\n" + updateSummary,
            "Версия: " + Program.Version + "; бандл: " + engine.Current + "\r\nПапка: " + home +
            "\r\nПуть: " + StatusView.Title(transport) + "; " + StatusView.Speed(transport) + "; проверен: " + StatusView.CheckedAt(transport) +
            "\r\nСеть: " + StatusView.Network(transport) + "; лимитная: " + StatusView.Metered(transport) +
            (Json.Str(transport, "configError").Length > 0 ? "\r\nНастройки: " + Json.Str(transport, "configError") : ""), transport, ServerHealthView.Read(home));
        }
        string TransportScript(string name) { return Path.Combine(engine.Folder(engine.Current), "transport", name); }
        void EnableRuntime(ComponentRuntime runtime, bool enabled)
        {
            if (enabled && runtime.Definition.Elevated) {
                using (var task = new ElevatedTask(home, runtime.Definition.Name)) if (!task.Registered) {
                    if (MessageBox.Show("Компонент «" + runtime.Definition.Title + "» требует прав администратора. Сейчас Windows запросит разрешение создать задачу планировщика с наивысшими правами. Лаунчер продолжит работать с обычными правами. Создать задачу?", "RemoteAgents", MessageBoxButtons.YesNo, MessageBoxIcon.Information, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return;
                    task.Register();
                }
            }
            if (runtime.Definition.Name == "control") {
                var args = new List<string> { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", Path.Combine(engine.Folder(engine.Current), "Start-WindowsControl.ps1"), enabled ? "-Install" : "-Uninstall", "-LauncherHome", home };
                // Install uses CIM for the long-lived bridge; let the lifecycle command finish independently.
                Process.Start(new ProcessStartInfo(Files.Executable("powershell.exe"), Files.Arguments(args)) { UseShellExecute = false, CreateNoWindow = true });
                config.SetEnabled(runtime.Definition, true); if (!runtime.Enabled) runtime.SetEnabled(Wanted(runtime.Definition)); RefreshMenu(); return;
            }
            config.SetEnabled(runtime.Definition, enabled); runtime.SetEnabled(Wanted(runtime.Definition)); RefreshMenu();
        }
        async void ScriptCommand(string script, string[] args, bool showOutput)
        {
            bool mutating = !showOutput;
            if (closing || mutating && !AllowMutation()) return;
            if (mutating) actionBusy = true;
            try {
                string output = await Task.Run(() => CaptureScript(script, args));
                if (!closing && showOutput) ShowText("Список путей", output);
            } catch (OperationCanceledException) { }
            catch { if (!closing) { log.Write("transport.command.failed"); MessageBox.Show("Команда модуля не выполнена. Проверьте его наличие и журналы.", "RemoteAgents"); } }
            finally { if (mutating) actionBusy = false; if (!closing) RefreshMenu(); }
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
            if (!AllowMutation()) return; actionBusy = true;
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
                            config.SetVpnIntent(true);config.SetEnabled(vpn.Definition, true);
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
            if (!AllowMutation()) return; actionBusy = true;
            try { config.SetVpnIntent(false);config.SetEnabled(vpn.Definition, false); await Task.Run(() => CaptureScript("Vpn.Tun.ps1", new[] { "-Disable" })); }
            catch (OperationCanceledException) { }
            catch { if (!closing) MessageBox.Show("Запрос выключения VPN не выполнен. Проверьте статус и журналы; выключение ещё не подтверждено.", "RemoteAgents"); }
            finally { actionBusy = false; if (!closing) RefreshMenu(); }
        }
        internal static bool VpnConflictDialog(string found)
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
        void CheckUpdates()
        {
            if (!AllowMutation()) return;
            if (engine.Pending || !Json.Bool(config.Update, "enabled")) { MessageBox.Show(mainWindow, engine.Pending ? "Идёт проверка обновления, подождите" : "Обновления на сервере не включены в конфиге", Product.Name); return; }
            busy = true; updateSummary = "проверка обновлений";
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
                WindowCommand command = WindowModel.Route(args);
                if (args.Contains("--exit") || args.Contains("--uninstall")) { RequestExit(); return; }
                if(firstSetup && !icon.Visible){foreach(var form in Application.OpenForms.Cast<Form>().Where(f=>f is SetupWizard || f is ConfigWindow).ToArray()) { ActivateWindow(form); } return;}
                switch (command) {
                    case WindowCommand.Show: ShowMain(); break;
                    case WindowCommand.Restart: if (AllowMutation()) LoadComponents(); break;
                    case WindowCommand.Rollback: if (AllowMutation()) { engine.Rollback(); LoadComponents(); log.Write("update.rollback.manual"); } break;
                    case WindowCommand.Logs: Open(Path.Combine(home, "logs")); break;
                    case WindowCommand.CheckUpdates: CheckUpdates(); break;
                    case WindowCommand.SetupCheck: CheckSetup(); break;
                }
            });
        }
        void RequestExit()
        {
            bool applying = actionBusy && !firstSetup || Application.OpenForms.Cast<Form>().Any(f => f is ConfigWindow && ((ConfigWindow)f).IsApplying || f is SetupWizard && ((SetupWizard)f).IsApplying);
            if (window.Exit(applying) == WindowExit.ConfirmApplying && MessageBox.Show(mainWindow, "Идёт применение настроек. Прервать?", Product.Name, MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
            if (mainWindow != null) mainWindow.Unload();
            foreach (var form in Application.OpenForms.Cast<Form>().ToArray()) { var wizard = form as SetupWizard; if (wizard != null) wizard.CancelEmbedded(); form.Dispose(); }
            ExitThread();
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
        void StopManagedComponents()
        {
            if (Product.IsVpn || definition == null) return;
            string bundle = engine.Folder(engine.Current);
            string helper = Path.Combine(bundle, "build", "Setup.Common.ps1");
            if (!File.Exists(helper)) { log.Write("components.stop.helpers.missing"); return; }
            string script = Path.Combine(home, "state", "stop-components.ps1");
            // Reuse the existing PID/command-line ownership checks and Disk engine shutdown.
            Files.Atomic(script, "param([string]$Bundle,[string]$Root)\r\n$ErrorActionPreference='Stop'\r\n" +
                ". (Join-Path $Bundle 'build/Setup.Common.ps1')\r\n" +
                "$failed=$false;try{Stop-ManagedControl $Root}catch{$failed=$true}\r\n" +
                "$disk=Join-Path $env:LOCALAPPDATA 'RemoteDisk';$config=Join-Path $Root 'config.json'\r\n" +
                "if(Test-Path $config){$c=Read-TransportJson $config;if($c.disk.home){$disk=[string]$c.disk.home}}\r\n" +
                "try{Stop-ManagedDisk $disk}catch{$failed=$true};if($failed){exit 1}\r\n");
            try {
                if (External.Run("powershell.exe", new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-Bundle", bundle, "-Root", home }, bundle, null, 45000, 1024, CancellationToken.None) != 0) log.Write("components.stop.failed");
            } catch { log.Write("components.stop.failed"); }
            finally { try { File.Delete(script); } catch { } }
        }
        protected override void ExitThreadCore()
        {
            if (closing) return; closing = true; timer.Stop(); stop.Cancel();
            if (mainWindow != null && !mainWindow.IsDisposed) mainWindow.Unload();
            lock (pipeGate) { if (server != null) server.Dispose(); }
            foreach (var r in runtimes) r.Dispose(); foreach (var job in actionJobs) job.Dispose();
            try { StopManagedComponents(); } catch { log.Write("components.stop.failed"); }
            try { WriteStatus(); } catch { log.Write("status.write.failed"); }
            log.Write("launcher.exit"); icon.Visible = false; icon.Dispose(); timer.Dispose();
            green.Dispose(); yellow.Dispose(); red.Dispose(); dispatch.Dispose(); base.ExitThreadCore();
        }
    }
}
