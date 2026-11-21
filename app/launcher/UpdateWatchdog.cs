using System;
using System.Diagnostics;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace RemoteAgents.Launcher
{
    // Прежний EXE: события квитанции, хэндл нового процесса и UpdateFailed, без опроса.
    internal static class UpdateWatchdog
    {
        const int WatcherStartTimeoutMs = 10000;
        internal static string EventName(string instance, string suffix) { return "Global\\" + instance + "." + suffix; }
        static string Instance(string home) { return Program.InstanceName(home, WindowsIdentity.GetCurrent().User); }
        static EventWaitHandle Event(string name)
        {
            var security = new EventWaitHandleSecurity();
            security.SetAccessRuleProtection(true, false);
            security.AddAccessRule(new EventWaitHandleAccessRule(WindowsIdentity.GetCurrent().User, EventWaitHandleRights.FullControl, AccessControlType.Allow));
            bool created; return new EventWaitHandle(false, EventResetMode.ManualReset, name, out created, security);
        }
        internal static EventWaitHandle FailureEvent(string home) { return Event(EventName(Instance(home), "UpdateFailed")); }
        internal static void SignalFailure(string home)
        { try { using (var failed = FailureEvent(home)) failed.Set(); } catch { } }
        internal static void Start(string home, string observerExe)
        {
            if (!File.Exists(Path.Combine(home, Product.BundleDirectory, "exe-upgrade.json"))) return;
            using (var ready = Event(EventName(Instance(home), "UpdateWatching"))) {
                if (ready.WaitOne(0)) return; // наблюдатель H2 уже вооружён вызывающим процессом
                using (var failed = FailureEvent(home)) failed.Reset(); // новая транзакция: прежний отказ не переносится
                using (var process = Process.Start(new ProcessStartInfo(observerExe, "--watch-update " + Files.Quote(home)) { UseShellExecute = false, CreateNoWindow = true })) { }
                if (!ready.WaitOne(WatcherStartTimeoutMs)) throw new IOException("Наблюдатель обновления не запустился"); // timer-ok: D — ответ старого EXE недоступен при сбое запуска; прервать активацию, успех не объявлять.
            }
        }
        internal static int Run(string home)
        {
            try {
                string name = Instance(home);
                using (var singleton = new Mutex(false, EventName(name, "UpdateObserver"))) {
                    bool held; try { held = singleton.WaitOne(0); } catch (AbandonedMutexException) { held = true; }
                    if (!held) return 0;
                    try {
                        var engine = new UpdateEngine(home, Program.Version);
                        string receipt = Path.Combine(engine.Root, "exe-upgrade.json");
                        using (var changed = new AutoResetEvent(false))
                        using (var failed = FailureEvent(home))
                        using (var ready = Event(EventName(name, "UpdateWatching")))
                        using (var watcher = new FileSystemWatcher(engine.Root, "exe-upgrade.json") { NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.FileName | NotifyFilters.Size }) {
                            Action wake = () => { try { changed.Set(); } catch (ObjectDisposedException) { } };
                            watcher.Changed += (s, e) => wake(); watcher.Created += (s, e) => wake();
                            watcher.Deleted += (s, e) => wake(); watcher.Renamed += (s, e) => wake(); watcher.Error += (s, e) => wake();
                            watcher.EnableRaisingEvents = true; ready.Set();
                            string reason = WaitForOutcome(receipt, changed, failed);
                            if (reason.Length == 0) return 0;
                            failed.Set(); // исключить приёмку, пока внешний наблюдатель останавливает новый EXE
                            new Journal(home).Write("update.failed reason=" + reason);
                            using (var mutex = new Mutex(false, "Global\\" + name)) {
                                bool owned; try { owned = mutex.WaitOne(0); } catch (AbandonedMutexException) { owned = true; }
                                if (!owned) Program.StopInstalled(name, Path.Combine(home, Product.ExeName), home, mutex, new Journal(home));
                                try {
                                    if (File.Exists(receipt)) {
                                        string version = Json.Str(Json.Read(receipt), "version");
                                        UpgradeInstaller.ObserveImage(home, engine, false, "rollback");
                                        string path = Path.Combine(engine.Root, "update-state.json");
                                        var state = File.Exists(path) ? Json.Read(path) : Json.Map(null);
                                        state["queuedFailure"] = version; state["pending"] = false; state["failureReason"] = reason; Json.Write(path, state);
                                    } // Приёмка могла завершиться перед остановкой: всё равно перезапустить остановленный трей.
                                } finally { mutex.ReleaseMutex(); }
                            }
                        }
                        Program.StartLauncher(Path.Combine(home, Product.ExeName), home, true); return 0;
                    } finally { singleton.ReleaseMutex(); }
                }
            } catch { return 1; }
        }
        sealed class ProcessWaitHandle : WaitHandle
        {
            internal ProcessWaitHandle(IntPtr handle) { SafeWaitHandle = new SafeWaitHandle(handle, false); }
        }
        static string WaitForOutcome(string receipt, WaitHandle changed, WaitHandle failed)
        {
            Process process = null; WaitHandle exited = null;
            try {
                while (File.Exists(receipt)) {
                    System.Collections.Generic.Dictionary<string, object> record;
                    try { record = Json.Read(receipt); } catch (FileNotFoundException) { return ""; }
                    if (failed.WaitOne(0)) return "UpdateFailed";
                    if (process == null && Json.Int(record, "pid", 0) > 0) {
                        try {
                            process = Process.GetProcessById(Json.Int(record, "pid", 0)); var pinned = process.Handle;
                            if (process.StartTime.ToUniversalTime().Ticks.ToString(System.Globalization.CultureInfo.InvariantCulture) != Json.Str(record, "processStarted")) return "process-exited";
                            exited = new ProcessWaitHandle(pinned);
                        } catch (ArgumentException) { return "process-exited"; }
                        catch (InvalidOperationException) { return "process-exited"; }
                        catch (System.ComponentModel.Win32Exception) { return "process-unavailable"; }
                    }
                    DateTime progress;
                    if (!DateTime.TryParse(Json.Text(record, "lastHealthUtc", Json.Str(record, "startedUtc")), null, System.Globalization.DateTimeStyles.RoundtripKind, out progress)) return "invalid-receipt";
                    var board = new HealthBoard(new string[0], progress.ToUniversalTime());
                    DateTime now = DateTime.UtcNow;
                    if (board.FuseExpired(now)) return UpdateObservation.Decide(File.Exists(receipt), false, false, true);
                    int remaining = (int)Math.Max(1, Math.Min(HealthBoard.UpdateNoProgressFuseMs, Math.Ceiling(HealthBoard.UpdateNoProgressFuseMs - (now - board.LastEventUtc).TotalMilliseconds)));
                    var handles = exited == null ? new[] { failed, changed } : new[] { failed, changed, exited };
                    int signal = WaitHandle.WaitAny(handles, remaining); // timer-ok: C — health.accepted недоступен при зависшем новом EXE; UpdateNoProgressFuseMs от последней готовности даёт только откат.
                    if (signal == WaitHandle.WaitTimeout) continue; // перечитать прогресс перед решением предохранителя
                    string decision = UpdateObservation.Decide(File.Exists(receipt), signal == 0, signal == 2, false);
                    if (decision != null) return decision;
                }
                return "";
            } finally { if (exited != null) exited.Dispose(); if (process != null) process.Dispose(); }
        }
    }
}
