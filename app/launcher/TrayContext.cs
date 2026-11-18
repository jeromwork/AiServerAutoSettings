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
    internal sealed partial class TrayContext : ApplicationContext
    {
        readonly string home; readonly Journal log; readonly Configuration config; readonly UpdateEngine engine;
        readonly NotifyIcon icon; readonly Control dispatch = new Control();
        readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer { Interval = 1000 };
        readonly CancellationTokenSource stop = new CancellationTokenSource();
        readonly List<ComponentRuntime> runtimes = new List<ComponentRuntime>(); readonly List<NativeJob> actionJobs = new List<NativeJob>();
        readonly Stopwatch trayClickClock = Stopwatch.StartNew();
        readonly TrayMenuState menuState = new TrayMenuState();
        readonly TickFailureLog tickFailures = new TickFailureLog();
        long lastTrayClick = -SystemInformation.DoubleClickTime - 1L;
        ConfigWindow mainWindow;
        DiskExplorerController diskExplorer;
        WindowModel window;
        readonly ConfigSyncSchedule syncSchedule = new ConfigSyncSchedule();
        bool syncRunning, accountResuming, serverHealthRunning, syncTaskRetired, syncTaskRetiring;
        DateTime nextSyncTaskRetirement = DateTime.MinValue;
        readonly ServerHealthSchedule healthSchedule = new ServerHealthSchedule();
        bool diskReading;
        int diskFolders = -1;
        bool vpnActionBusy, vpnActionWanted;
        string vpnError = "";
        HelperClient netHelper;
        string diskSummary = "Диск: ожидается проверка";
        DateTime diskUpdated = DateTime.MinValue;
        DiskTraySession diskSession;
        string syncSummary = "Сверка конфига: ожидается подтверждённая связь";
        readonly Icon green = MakeIcon(Color.ForestGreen), yellow = MakeIcon(Color.Goldenrod), red = MakeIcon(Color.Firebrick);
        readonly object pipeGate = new object(); NamedPipeServerStream server; Task worker, pipeWorker;
        readonly ConcurrentQueue<string[]> commands = new ConcurrentQueue<string[]>(); volatile bool readyForCommands;
        string installSource; readonly bool firstSetup; BundleDefinition definition; bool busy, closing, ticking, actionBusy;
        DateTime settingsWritten = DateTime.MinValue;
        // Detached server installs started by the wizard (state/server-operations.json).
        DateTime nextOperationCheck = DateTime.MinValue; bool operationChecking, operationsActive; string operationTip = "";
        string updateSummary = "Обновления: ожидается проверка";
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
                icon.MouseClick += (s, e) => {
                    long now = trayClickClock.ElapsedMilliseconds;
                    if (e.Button != MouseButtons.Left || !TrayMenuModel.AcceptLeftClick(e.Clicks, now - lastTrayClick, SystemInformation.DoubleClickTime)) return;
                    lastTrayClick = now;
                    Safe(() => {
                        if (TrayMenuModel.LeftClickAction(config.Data, AccountState()) == "happier") OpenHappier();
                        else ShowMain();
                    });
                };
                if (!firstSetup) { engine.Recover(); Bootstrap(); LoadComponents(); updateSummary = Json.Text(UpdateState(), "summary", updateSummary); AttachUpdateRestart(); }
            } catch {
                stop.Cancel(); lock (pipeGate) { if (server != null) server.Dispose(); }
                if (icon != null) { icon.Visible = false; icon.Dispose(); }
                throw;
            }
            readyForCommands = true;
            timer.Tick += (s, e) => Tick(); timer.Start();
            // The folder choice keeps applying after its window closed; the tray reports the result.
            BackgroundWork.Disk.Changed += () => { try { dispatch.BeginInvoke(new Action(DiskFinished)); } catch (InvalidOperationException) { } };
            dispatch.BeginInvoke(new Action(() => {
                if (firstSetup) { RunFirstSetup(); return; }
                netHelper = new HelperClient(home, dispatch); netHelper.EnsureRunning();
                DeliverUpdateNotice(); CheckLegacyVpn(); StartLegacyDiskCleanup(); Handle(args); DrainCommands(); Tick();
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
                    ReloadSettings();LoadComponents();CheckLegacyVpn();return engine.Folder(engine.Current);
                };
                // One preparation for both windows: «Пройти по шагам» reuses the bundle the config window prepared.
                Task<string> prepared=null;
                Func<Task<string>> once=()=>{if(prepared==null || prepared.IsFaulted || prepared.IsCanceled)prepared=prepare();return prepared;};
                bool manual=ConfigWindow.First(home,once);
                if(manual && !closing)SetupWizard.Display(home,null,true,prepare:once);
            } finally {actionBusy=false;}
            if(closing)return;
            if(FirstInstall.Required(home)){ExitThread();return;}
            ReloadSettings();icon.Visible=true;readyForCommands=true;ShowMain();
            netHelper = new HelperClient(home, dispatch); netHelper.EnsureRunning();
            CheckLegacyVpn();StartLegacyDiskCleanup();DrainCommands();Tick();
        }
        void Bootstrap()
        {
            try { log.Write("openssh." + PortableTools.EnsureOpenSsh(home)); } catch { log.Write("openssh.failed"); }
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

        void LoadComponents()
        {
            foreach (var r in runtimes) r.Dispose(); runtimes.Clear();
            foreach (var j in actionJobs) j.Dispose(); actionJobs.Clear();
            definition = BundleDefinition.Load(engine.Folder(engine.Current));
            if (mainWindow != null && !mainWindow.IsDisposed) mainWindow.RebindBundle(engine.Folder(engine.Current));
            foreach (var c in definition.Components.Where(c => Product.VpnEnabled || c.Name != "vpn")) runtimes.Add(new ComponentRuntime(c, Wanted(c), home, engine.Folder(engine.Current), log));
            RefreshMenu();
        }
        bool Wanted(Component c) { return c.Name != "vpn" && config.Wanted(c); }
        void Tick()
        {
            if (closing || ticking || definition == null) return; ticking = true;
            Icon shown = icon.Icon; // final tray colour of this tick, applied once in finally
            try {
                bool ok = true, restart = false, coreFailed = false;
                var transport = Json.Map(null);
                ok &= Step("settings", () => { RetireConfigSyncTask(); TryDeleteOld(); ReloadSettings(); });
                if (!Step("components", () => { foreach (var r in runtimes) r.Tick(); })) { ok = false; coreFailed = true; }
                if (!Step("update", () => {
                    var critical = runtimes.Where(r => r.Definition.Critical).ToArray();
                    bool all = critical.Length > 0 && critical.Where(r => r.Enabled).All(r => r.Healthy);
                    all = all && UpdateHealthReady();
                    string result = engine.Observe(all);
                    string image = UpgradeInstaller.ObserveImage(home, engine, all, result);
                    if (image == "rollback") { try { PrepareUpdateRestart(); } catch { keepVpnOnRestart = false; log.Write("update.resume.failed"); } UpdateOutcome(Json.Text(UpdateState(), "target", engine.Previous), "здоровье не подтверждено; выполнен откат"); log.Write("launcher.rollback"); RestartRequested = true; ExitThread(); restart = true; return; }
                    if (result == "rollback") { log.Write("update.rollback"); updateSummary = "обновление откачено: здоровье не подтверждено"; LoadComponents(); foreach (var r in runtimes) r.Tick(); all = false; }
                    if (result == "accepted" || image == "accepted") { log.Write("update.accepted"); UpdateOutcome(engine.Current, ""); }
                    int count = critical.Count(r => r.Healthy); shown = all ? green : count > 0 ? yellow : red;
                })) { ok = false; coreFailed = true; }
                if (restart) return;
                if (!Step("transport", () => { transport = StatusView.Read(home, "transport", maxAgeSec: 15); })) { ok = false; coreFailed = true; }
                ok &= Step("lan", () => { if (netHelper != null) netHelper.UpdateLan(config.Data, transport); });
                ok &= Step("vpn-resume", () => ResumeUpdatedVpn(transport));
                ok &= Step("icon", () => {
                    var linkPhase = StatusView.Phase(transport); shown = linkPhase == LinkPhase.Ok ? green : linkPhase == LinkPhase.Checking ? yellow : red;
                    var vpnStatus = VpnStatus.Read(home);
                    string vpnReason = VpnWatchdog.FailureSummary(Json.Str(vpnStatus, "state"), Json.Str(vpnStatus, "stage"));
                    if (vpnReason.Length > 0 && Json.Str(vpnStatus, "owner") == "net-helper") vpnReason = Json.Text(vpnStatus, "summary", vpnReason);
                    if (Json.Str(vpnStatus, "state") == "conflict") shown = yellow;
                    icon.Text = vpnReason.Length > 0 ? TrayMenuModel.Short(vpnReason, 63) : TrayMenuModel.Tooltip(transport, ServerHealthView.Read(home));
                });
                ok &= Step("operations", () => { if (DateTime.UtcNow >= nextOperationCheck) CheckOperations(); });
                ok &= Step("menu", RefreshMenuItems);
                ok &= Step("main", RefreshMain);
                ok &= Step("status", WriteStatus);
                ok &= Step("sync", CheckSync);
                ok &= Step("server-health", CheckServerHealth);
                ok &= Step("disk", CheckDisk);
                ok &= Step("updates", PollUpdates);
                // Honest icon: a broken core step is red; any other broken step must not leave it green.
                if (coreFailed) shown = red; else if (!ok && shown == green) shown = yellow;
            } catch (Exception ex) { tickFailures.Write(log, ex, "tick"); shown = red; }
            finally { ticking = false; if (!closing && icon.Icon != shown) icon.Icon = shown; }
        }
        bool Step(string name, Action action) { return tickFailures.Run(log, name, action); }
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
                            if (Json.Bool(account, "ok")) {
                                pending = false;
                                string message = new HappierAccountCreation(home).Complete(SectionOutcome.From(account, "Аккаунт Happier подключён ✓"));
                                if (message.Length > 0) {
                                    ShowMain();
                                    if (mainWindow != null && !mainWindow.IsDisposed) mainWindow.ShowHappierAccountCreated(message);
                                    else MessageBox.Show(message + "\r\nКнопки аккаунта находятся в главном окне на карточке «Happier».", Product.Name, MessageBoxButtons.OK, MessageBoxIcon.Information);
                                } else icon.ShowBalloonTip(5000, Product.Name, "Happier: " + Json.Text(account, "summary", "аккаунт подключён"), ToolTipIcon.Info);
                            }
                        } catch (OperationCanceledException) { throw; } catch (Exception) { log.Write("operations.account.failed"); pending = false; icon.ShowBalloonTip(10000, Product.Name, "Happier: аккаунт не подключён. Откройте «Настройки» → Happier.", ToolTipIcon.Warning); }
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
        async void RetireConfigSyncTask()
        {
            if (closing || syncTaskRetired || syncTaskRetiring || DateTime.UtcNow < nextSyncTaskRetirement) return;
            syncTaskRetiring = true;
            string bundle = engine.Folder(engine.Current);
            try {
                await Task.Run(() => ServerOperations.Invoke(home, bundle, "RetireConfigSync", new { }, stop.Token));
                syncTaskRetired = true;
            } catch (OperationCanceledException) { }
            catch (Exception) { log.Write("config.sync.task.retire.failed"); }
            finally { syncTaskRetiring = false; nextSyncTaskRetirement = DateTime.UtcNow.AddSeconds(30); }
        }
        async void CheckSync()
        {
            if(!Json.Bool(Json.Map(Json.Get(config.Data,"wizard")),"configured") || !Json.Map(Json.Get(config.Data,"profile")).ContainsKey("server"))return;
            bool connected=Json.Bool(StatusView.Read(home,"transport",maxAgeSec:15),"ok");
            bool occupied = !syncTaskRetired || syncRunning || actionBusy || busy || closing || operationChecking || BackgroundWork.Disk.Busy || mainWindow != null && mainWindow.IsApplying;
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
            if (closing || engine.Current.Length == 0) return;
            bool occupied = serverHealthRunning || syncRunning || actionBusy || busy || operationChecking || mainWindow != null && mainWindow.IsApplying;
            string serverId = ServerHealthView.Identity(home);
            if (!healthSchedule.Due(DateTime.UtcNow, Json.Bool(StatusView.Read(home, "transport", maxAgeSec: 15), "ok"), occupied, serverId)) return;
            serverHealthRunning = true; healthSchedule.Started(DateTime.UtcNow);
            string bundle = engine.Folder(engine.Current);
            try {
                await Task.Run(() => ServerOperations.Invoke(home, bundle, "ServerHealth", new { }, stop.Token));
                log.Write("server.health.complete");
            } catch (OperationCanceledException) { }
            catch (Exception) {
                // The outer ten-second budget may kill PowerShell before it can save its failure.
                if (!closing) Json.Write(Path.Combine(home, "state", "server-health.json"), new { schema = 1, ok = false, serverId = serverId, updatedUtc = DateTime.UtcNow.ToString("o"), summary = "Состояние сервера не получено: проверьте связь" });
                log.Write("server.health.unavailable");
            } finally { serverHealthRunning = false; if (!closing) RefreshMenu(); }
        }
        void WriteStatus()
        {
            Json.Write(Path.Combine(home, "status", Product.StatusName), new { schema = 1, pid = Process.GetCurrentProcess().Id, launcherVersion = Program.Version, bundleVersion = engine.Current,
                previousVersion = engine.Previous, pending = engine.Pending, running = !closing, updatedUtc = DateTime.UtcNow.ToString("o"), update = updateSummary,
                ok = !closing && (runtimes.Any(r => r.Definition.Critical) && runtimes.Where(r => r.Definition.Critical).All(r => r.Healthy)), components = runtimes.Select(r => r.Snapshot()).ToArray() });
        }
        bool openingHappier;
        async void OpenHappier()
        {
            if (openingHappier) return;
            openingHappier = true;
            try {
                string url = await TrayMenuModel.HappierUrl(config.Data, AccountState(), home);
                if (closing) return;
                if (url.Length > 0) Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
                else ShowMain();
            } catch (Exception) { if (!closing) ShowMain(); }
            finally { openingHappier = false; }
        }
        void RefreshMenu() { RefreshMenuItems(); RefreshMain(); }
        void RefreshMenuItems()
        {
            // One snapshot: LAN can appear after HelperClient starts, or disappear on reload.
            menuState.Refresh(TrayEntries(), entries => {
                var menu = new ContextMenuStrip { ShowItemToolTips = true };
                foreach (var entry in entries) {
                    if (entry.Id == "separator") { menu.Items.Add(new ToolStripSeparator()); continue; }
                    string id = entry.Id;
                    var item = new ToolStripMenuItem(entry.Text) { Enabled = entry.Enabled, ToolTipText = entry.Hint };
                    item.Click += (s, e) => Safe(() => {
                        if (id == "update-check") CheckUpdates();
                        else if (id == "open") OpenHappier();
                        else if (id == "settings") ShowMain();
                        else if (id == "disk") OpenDisk();
                        else if (id == "synchronization") OpenSynchronization();
                        else if (id == "vpn") ToggleVpn();
                        else if (id == "exit") RequestExit();
                    });
                    menu.Items.Add(item);
                }
                var previous = icon.ContextMenuStrip;
                icon.ContextMenuStrip = menu;
                if (previous != null) previous.Dispose();
            }, (i, entry) => {
                var item = icon.ContextMenuStrip.Items[i]; item.Text = entry.Text; item.Enabled = entry.Enabled; item.ToolTipText = entry.Hint;
            });
        }
        TrayMenuEntry VpnMenu()
        {
            var card = MainScreenModel.Build(new MainScreenFacts { VpnInstalled = true, Vpn = VpnStatus.Read(home), VpnBusy = vpnActionBusy, VpnWanted = vpnActionWanted, Operation = MutationConflict() }).Vpn;
            return new TrayMenuEntry("vpn", card.On ? "Выключить VPN" : "Включить VPN", card.SwitchEnabled) { Hint = card.State };
        }
        void ToggleVpn()
        {
            var vpn = runtimes.FirstOrDefault(r => r.Definition.Name == "vpn"); if (vpn == null) return;
            if (Json.Bool(VpnStatus.Read(home), "enabled")) DisableVpn(vpn); else CheckVpn(vpn);
        }
        Dictionary<string, object> AccountState()
        { try { return Json.Read(Path.Combine(home, "state", "happier-account.json")); } catch { return Json.Map(null); } }
        TrayMenuEntry[] TrayEntries()
        {
            var entries = TrayMenuModel.Build(config.Data, AccountState(), StatusView.Read(home, "transport", maxAgeSec: 15), ServerHealthView.Read(home), DiskSummary()).ToList();
            var lanStatus = LocalLanStatus();
            if (Json.Bool(lanStatus, "enabled")) entries.Insert(0, new TrayMenuEntry("lan-status", StatusView.Lan(lanStatus), false));
            entries.Insert(entries.Count - 1, new TrayMenuEntry("update-status", updateSummary, false));
            entries.Insert(entries.Count - 1, new TrayMenuEntry("update-check", "Проверить обновления сейчас", !updateChecking && !engine.Pending));
            entries.Insert(entries.Count - 1, VpnMenu()); return entries.ToArray();
        }
        bool Configured()
        { return Json.Bool(Json.Map(Json.Get(new Configuration(home).Data, "wizard")), "configured"); }
        async void CheckSetup()
        {
            if(actionBusy || busy || closing )return;
            // Sign-in is quiet; an explicit human launch is routed separately to the main window.
            bool configured=false;try{configured=Configured();}catch{log.Write("setup.config.read.failed");}
            if(configured){WatchHealth();return;}
            actionBusy=true;
            try {
                // Let supervised components publish their first live observation without showing a window.
                await Task.Delay(3000,stop.Token);
                {
                    // Not configured: the paste window (it resumes a config pasted earlier; «Пройти по шагам» stays available).
                    string bundle=engine.Folder(engine.Current);
                    if(ConfigWindow.First(home,()=>Task.FromResult(bundle)) && !closing)SetupWizard.Display(home,bundle,true);
                    if(!closing && Configured())ShowMain();
                    return;
                }
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
                        // VPN is enabled only by an explicit card/tray action; never by setup or autostart.
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
        void ShowMain()
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
                mainWindow.VpnRequested = enabled => {
                    var vpn = runtimes.FirstOrDefault(r => r.Definition.Name == "vpn");
                    if (vpn == null) return;
                    if (enabled) CheckVpn(vpn, true); else DisableVpn(vpn, true);
                };
                mainWindow.MainAction = action => Safe(() => {
                    if (action == "retry") { if (AllowMutation()) LoadComponents(); }
                    else if (action == "open-sync") OpenSynchronization();
                    else if (action == "open-disk") OpenDisk();
                });
                mainWindow.HiddenToTray = () => {
                    if (window.CloseToTray()) {
                        Safe(() => Files.Atomic(Path.Combine(home, "state", "tray-hint-shown"), "shown\n"));
                        icon.ShowBalloonTip(8000, Product.Name, "Значок в трее: клик открывает Happier, если адрес задан. Окно программы: пункт «Настройки».", ToolTipIcon.Info);
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
            window.Show(); RefreshMain(); ActivateWindow(mainWindow);
        }
        KeyValuePair<string, Action> Service(string title, Action action)
        { return new KeyValuePair<string, Action>(title, () => Safe(action)); }
        static void ActivateWindow(Form form)
        {
            if (!form.Visible) form.Show();
            if (form.WindowState == FormWindowState.Minimized) form.WindowState = FormWindowState.Normal;
            form.BringToFront(); form.Activate(); SetForegroundWindow(form.Handle);
        }
        // The in-process Explorer monitor first removes v1 menus/icons, including those recreated by a downgrade.
        // Its v2 registration starts only after cleanup succeeds; failures are journalled and retried in the background.
        // Only the installed program does it: an isolated --home (tests, smoke runs) must not touch this computer's Explorer settings.
        void StartLegacyDiskCleanup()
        {
            if (closing || engine.Current.Length == 0) return;
            if (!Path.GetFullPath(home).Equals(Path.GetFullPath(Program.DefaultHome), StringComparison.OrdinalIgnoreCase)) return;
            if (diskExplorer != null) return;
            diskExplorer = new DiskExplorerController(home, () => ConfigProfile.DiskRoot(ConfigProfile.Load(home)), () => engine.Folder(engine.Current),
                () => ConfigSections.DiskDescribed(ConfigProfile.Load(home)),
                () => !LegacyDiskCleanup.Required(home) || LegacyDiskCleanup.Run(home, engine.Folder(engine.Current),
                    (exe, args) => External.Run(exe, args, engine.Folder(engine.Current), null, 120000, 1024 * 1024, stop.Token), log.Write),
                (message, ok) => { try { dispatch.BeginInvoke(new Action(() => { if (!closing) icon.ShowBalloonTip(4000, "Диск", message, ok ? ToolTipIcon.Info : ToolTipIcon.Warning); })); } catch (InvalidOperationException) { } },
                log.Write, DiskExplorerNative.CreateService(Path.Combine(DiskExplorerController.DefaultDiskHome, "explorer-icons"), log.Write), DiskExplorerNative.CreateRegistry(log.Write));
        }
        // The Disk root in Explorer: the local REST monitor supplies folder icons and shell commands.
        void OpenDisk()
        {
            string root = ConfigProfile.DiskRoot(ConfigProfile.Load(home));
            if (Directory.Exists(root)) { Open(root); return; }
            MessageBox.Show(mainWindow, "Папка Диска ещё не создана: " + root + "\r\nДиск устанавливается вместе с настройкой сервера («Настройки» → «Дополнительно» → «Редактор конфига» → «Применить»). Папки сервера принимайте в Syncthing Tray.", Product.Name);
        }
        string DiskSummary()
        {
            if (!runtimes.Any(r => r.Definition.Name == "disk" && r.Enabled)) return "Диск: отключён";
            return (DateTime.UtcNow - diskUpdated).TotalSeconds <= 10 ? diskSummary : "Диск: состояние не получено";
        }
        async void CheckDisk()
        {
            if (closing || diskReading) return;
            if (!runtimes.Any(r => r.Definition.Name == "disk" && r.Enabled)) { diskSession = null; diskFolders = -1; diskUpdated = DateTime.MinValue; return; }
            string root = DiskTraySession.Home(config.Data);
            diskReading = true;
            try {
                var current = diskSession;
                var result = await Task.Run(() => {
                    var candidate = new DiskTraySession(root);
                    var session = current != null && current.Root == root && current.Identity == candidate.Identity ? current : candidate;
                    string summary = session.Read(stop.Token);
                    return Tuple.Create(session, summary, session.FolderCount);
                });
                if (!closing && root == DiskTraySession.Home(config.Data) && runtimes.Any(r => r.Definition.Name == "disk" && r.Enabled)) { diskSession = result.Item1; diskSummary = result.Item2; diskFolders = result.Item3; diskUpdated = DateTime.UtcNow; }
            } catch (Exception) { diskSession = null; diskFolders = -1; diskSummary = "Диск: локальный Syncthing недоступен"; diskUpdated = DateTime.UtcNow; }
            finally { diskReading = false; }
        }
        void OpenSynchronization()
        {
            string script = Path.Combine(engine.Folder(engine.Current), "disk", "Disk.Engine.ps1");
            if (!File.Exists(script)) throw new FileNotFoundException();
            // The UI has its own action Job. Closing it cannot affect the disk component's Job.
            RunAction(new MenuAction { Exe = "powershell.exe", Args = new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-OpenWindow", "-Home", home } });
        }
        string MutationConflict()
        {
            string operation = legacyVpnCleaning ? "очистка старого VPN" : syncRunning ? "сверка конфига" : busy ? "обновление" : actionBusy ? "настройка компонентов" : accountResuming ? "подключение аккаунта Happier" : mainWindow != null && mainWindow.IsApplying ? "применение настроек" : "";
            return WindowModel.Conflict(operation);
        }
        // Restart/rollback/update stop processes: they also wait for the background Disk install (windows do not).
        bool AllowMutation()
        {
            string conflict = MutationConflict(); if (conflict.Length == 0 && BackgroundWork.Disk.Busy) conflict = WindowModel.Conflict("установка Диска");
            if (conflict.Length == 0) return !closing;
            if (!closing) MessageBox.Show(mainWindow, conflict, Product.Name);
            return false;
        }
        Dictionary<string, object> LocalLanStatus()
        { return netHelper == null ? Json.Map(null) : netHelper.LanStatus(config.Data); }
        void RefreshMain()
        {
            if (mainWindow == null || mainWindow.IsDisposed) return;
            var transport = StatusView.Read(home, "transport", maxAgeSec: 15);
            var health = ServerHealthView.Read(home);
            HappierAccountModel account;
            try { account = HappierAccountModel.From(config.Data, name => SecretVault.Has(home, name)); }
            catch (Exception) { account = new HappierAccountModel(); }
            var facts = new MainScreenFacts {
                Transport = transport, Lan = LocalLanStatus(),
                Vpn = VpnStatus.Read(home),
                Control = StatusView.Read(home, "control", maxAgeSec: 30), Health = health,
                VpnInstalled = definition != null && definition.Components.Any(c => c.Name == "vpn"),
                VpnWanted = vpnActionBusy ? vpnActionWanted : Json.Bool(Json.Map(Json.Get(Json.Map(Json.Get(config.Data, "profile")), "vpn")), "enabled"),
                VpnBusy = vpnActionBusy, VpnError = vpnError, VpnDisableFailed = vpnError.Length > 0 && !vpnActionWanted, Operation = MutationConflict(),
                DiskEnabled = runtimes.Any(r => r.Definition.Name == "disk" && r.Enabled), DiskSummary = DiskSummary(),
                DiskFolders = (DateTime.UtcNow - diskUpdated).TotalSeconds <= 10 ? diskFolders : -1, DiskServerOnly = -1,
                HappierVisible = account.Visible, HappierHasKey = account.HasKey, HappierLabel = account.Label,
                HappierConfirmed = Json.Bool(AccountState(), "ok"), HappierUrl = account.WebUrl
            };
            mainWindow.UpdateActivity(syncSummary + "\r\n" + updateSummary);
            mainWindow.UpdateMain(facts,
                "Версия: " + Program.Version + "; бандл: " + engine.Current + "\r\nПапка: " + home +
                "\r\nПуть: " + StatusView.Title(transport) + "; " + StatusView.Speed(transport) + "; проверен: " + StatusView.CheckedAt(transport) +
                "\r\nСеть: " + StatusView.Network(transport) + "; лимитная: " + StatusView.Metered(transport) +
                (Json.Str(transport, "configError").Length > 0 ? "\r\nНастройки: " + Json.Str(transport, "configError") : ""), transport, health);
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
        bool legacyVpnChecked, legacyVpnCleaning;
        async void CheckLegacyVpn()
        {
            if (legacyVpnChecked || closing || engine.Current.Length == 0) return;
            legacyVpnChecked = true; bool cleaning = false;
            try {
                var result = Json.Map(Json.Parse(await Task.Run(() => CaptureScript("Vpn.Tun.ps1", new[] { "-InspectLegacy" }))));
                if (closing || !Json.Bool(result, "found")) return;
                using (var prompt = new Form { Text = "RemoteAgents", Width = 570, Height = 190, StartPosition = FormStartPosition.CenterScreen,
                    FormBorderStyle = FormBorderStyle.FixedDialog, MinimizeBox = false, MaximizeBox = false }) {
                    prompt.Controls.Add(new Label { Text = "Остался VPN от прошлой версии RemoteAgents, он может мешать сети. Убрать? (потребуется подтверждение администратора)", Dock = DockStyle.Fill, Padding = new Padding(16) });
                    var buttons = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 44, FlowDirection = FlowDirection.RightToLeft, Padding = new Padding(6) };
                    var later = new Button { Text = "Не сейчас", DialogResult = DialogResult.Cancel, AutoSize = true };
                    var remove = new Button { Text = "Убрать", DialogResult = DialogResult.OK, AutoSize = true };
                    buttons.Controls.Add(later); buttons.Controls.Add(remove); prompt.Controls.Add(buttons); prompt.CancelButton = later;
                    if (prompt.ShowDialog(mainWindow) != DialogResult.OK || closing) return;
                }
                cleaning = legacyVpnCleaning = true; RefreshMain();
                string exe = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
                string arguments = Files.Arguments(new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", TransportScript("Vpn.Tun.ps1"), "-Home", home, "-Cleanup" });
                await Task.Run(() => {
                    using (var process = Process.Start(new ProcessStartInfo(exe, arguments) { UseShellExecute = true, Verb = "runas", WindowStyle = ProcessWindowStyle.Hidden })) {
                        process.WaitForExit(); if (process.ExitCode != 0) throw new IOException();
                    }
                });
                ReloadSettings();
            } catch (System.ComponentModel.Win32Exception e) when (e.NativeErrorCode == 1223) { log.Write("vpn.cleanup.cancelled"); }
            catch (OperationCanceledException) { }
            catch {
                log.Write("vpn.cleanup.failed");
                if (cleaning && !closing) MessageBox.Show("Не удалось убрать остатки VPN. Очистка не подтверждена. Журнал: logs\\launcher.log", "RemoteAgents");
            } finally { legacyVpnCleaning = false; if (!closing) RefreshMenu(); }
        }
        async void CheckVpn(ComponentRuntime vpn, bool fromCard = false)
        {
            if (!vpn.Definition.CommandManaged) { VpnFailure("Обновите компоненты программы перед включением VPN", fromCard); return; }
            if (!AllowMutation()) return; actionBusy = vpnActionBusy = true; vpnActionWanted = true; vpnError = ""; RefreshMain();
            try {
                if (netHelper == null) throw new IOException(HelperClient.PermissionRequired);
                var transport = StatusView.Read(home, "transport", maxAgeSec: 3);
                var options = new System.Collections.Generic.Dictionary<string, object>(Json.Map(Json.Get(config.Data, "vpn")));
                // Intent/interface names are not part of the privileged command.
                options = options.Where(p => new[] { "address", "excludeCidrs", "dnsServer", "checkUrl", "probeAddress" }.Contains(p.Key)).ToDictionary(p => p.Key, p => p.Value);
                options["socksPort"] = Json.Int(Json.Map(Json.Get(transport, "helper")), "vpnInPort", Json.Int(Json.Map(Json.Get(config.Data, "transport")), "vpnInPort", 17881));
                var status = await netHelper.VpnOn(VpnTun.Read(options));
                if (closing) return;
                if (Json.Str(status, "state") != "on") { if (!fromCard) MessageBox.Show(Json.Text(status, "summary", "VPN не включён: соединение не подтверждено"), Product.Name); return; }
                config.SetVpnIntent(true); config.SetEnabled(vpn.Definition, true);
            } catch (OperationCanceledException) { }
            catch { if (!closing) { log.Write("vpn.helper.failed"); VpnFailure("Не удалось включить VPN. Проверьте подключение сетевого помощника и диагностику.", fromCard); } }
            finally { actionBusy = vpnActionBusy = false; if (!closing) RefreshMenu(); }
        }
        void SignalVpnStop()
        { try { Files.Atomic(Path.Combine(home, "state/vpn.stop"), "stop\n"); } catch { log.Write("vpn.stop.failed"); } }
        void VpnFailure(string message, bool fromCard)
        { vpnError = message; if (!fromCard && !closing) MessageBox.Show(message, Product.Name); }
        async void DisableVpn(ComponentRuntime vpn, bool fromCard = false)
        {
            if (!AllowMutation()) return;
            resumeUpdatedVpn = false;
            try { var updateState = UpdateState(); updateState["vpnOn"] = false; updateState.Remove("resumeVpn"); Json.Write(UpdateStatePath, updateState); }
            catch { log.Write("update.resume.cancel.failed"); }
            actionBusy = vpnActionBusy = true; vpnActionWanted = false; vpnError = ""; RefreshMain();
            try {
                if (!vpn.Definition.CommandManaged) { EnableRuntime(vpn, false); return; }
                if (netHelper == null) throw new IOException(HelperClient.PermissionRequired);
                await netHelper.VpnOff();
                config.SetVpnIntent(false); config.SetEnabled(vpn.Definition, false);
            }
            catch (OperationCanceledException) { }
            catch { if (!closing) VpnFailure("Запрос выключения VPN не выполнен. Проверьте статус и журналы; выключение ещё не подтверждено.", fromCard); }
            finally { actionBusy = vpnActionBusy = false; if (!closing) RefreshMenu(); }
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
        bool TrySelfUpdate(string version)
        {
            string path = Path.Combine(engine.Folder(version), ".launcher-manifest.json");
            if (!File.Exists(path)) return false;
            var manifest = Manifest.Parse(File.ReadAllText(path));
            // FileVersion can stay equal between daily bundles. Verify and replace by hash for EVERY new bundle.
            UpgradeInstaller.ActivatePrepared(home, engine, manifest);
            try {
                PrepareUpdateRestart();
                Process.Start(new ProcessStartInfo(Path.Combine(home, Product.Name + ".previous.exe"), "--watch-update " + Files.Quote(home) + " --watch-parent " + Process.GetCurrentProcess().Id.ToString()) { UseShellExecute = false, CreateNoWindow = true });
            } catch {
                engine.Rollback(); UpgradeInstaller.ObserveImage(home, engine, false, "rollback"); keepVpnOnRestart = false; throw;
            }
            log.Write("launcher.update.ready"); RestartRequested = true; ExitThread(); return true;
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
                var diskShell = DiskShellRequest.Parse(args);
                if (diskShell != null) {
                    if (busy) { icon.ShowBalloonTip(4000, "Диск", "Идёт обновление программы; повторите действие после перезапуска", ToolTipIcon.Info); return; }
                    if (diskExplorer != null) diskExplorer.Submit(diskShell);
                    else icon.ShowBalloonTip(4000, "Диск", "Диск ещё не установлен или отключён", ToolTipIcon.Warning);
                    return;
                }
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
        DiskRun reportedDisk;
        void DiskFinished()
        {
            var last = BackgroundWork.Disk.Last;
            if (closing || BackgroundWork.Disk.Busy || last == null || last == reportedDisk) return;
            reportedDisk = last;
            if (!DiskApplyWait.Current(last.Binding, ConfigProfile.Load(home))) return;
            // An open window shows the result itself; the balloon is for a run that outlived its window.
            if (Application.OpenForms.Cast<Form>().Any(f => f is ConfigWindow && f.Visible) || !icon.Visible) return;
            if (last.Ok) icon.ShowBalloonTip(5000, Product.Name, "Диск: " + last.Summary, ToolTipIcon.Info);
            else icon.ShowBalloonTip(10000, Product.Name, "Диск не подключён: " + last.Summary + ". Повторите: «Настройки» → «Дополнительно» → «Редактор конфига» → «Применить».", ToolTipIcon.Warning);
        }
        void RequestExit()
        {
            bool applying = actionBusy && !vpnActionBusy && !firstSetup || BackgroundWork.Disk.Busy || Application.OpenForms.Cast<Form>().Any(f => f is ConfigWindow && ((ConfigWindow)f).IsApplying || f is SetupWizard && ((SetupWizard)f).IsApplying);
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
            if (definition == null) return;
            string bundle = engine.Folder(engine.Current);
            string helper = Path.Combine(bundle, "build", "Setup.Common.ps1");
            if (!File.Exists(helper)) { log.Write("components.stop.helpers.missing"); return; }
            string script = Path.Combine(home, "state", "stop-components.ps1");
            // Reuse the existing PID/command-line ownership checks and Disk engine shutdown.
            Files.Atomic(script, "param([string]$Bundle,[string]$Root)\r\n$ErrorActionPreference='Stop'\r\n" +
                ". (Join-Path $Bundle 'build/Setup.Common.ps1')\r\n" +
                "$failed=$false;try{Remove-LegacyConfigSyncTask $Root}catch{$failed=$true}\r\n" +
                "try{Stop-ManagedControl $Root}catch{$failed=$true}\r\n" +
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
            if (closing) return;
            if (netHelper != null) netHelper.Dispose();
            bool preserveVpn = RestartRequested && keepVpnOnRestart;
            if (!preserveVpn) try { Files.Atomic(Path.Combine(home, "state/vpn.stop"), "stop\n"); } catch { log.Write("vpn.stop.failed"); }
            closing = true; timer.Stop(); stop.Cancel(); BackgroundWork.Disk.Stop();
            if (diskExplorer != null) { diskExplorer.Dispose(); diskExplorer.Wait(3500); }
            if (mainWindow != null && !mainWindow.IsDisposed) mainWindow.Unload();
            lock (pipeGate) { if (server != null) server.Dispose(); }
            try { StopManagedComponents(); } catch { log.Write("components.stop.failed"); }
            foreach (var r in runtimes) r.Dispose(preserveVpn); foreach (var job in actionJobs) job.Dispose();
            try { WriteStatus(); } catch { log.Write("status.write.failed"); }
            log.Write("launcher.exit"); icon.Visible = false; icon.Dispose(); timer.Dispose();
            green.Dispose(); yellow.Dispose(); red.Dispose(); dispatch.Dispose(); base.ExitThreadCore();
        }
    }
}
