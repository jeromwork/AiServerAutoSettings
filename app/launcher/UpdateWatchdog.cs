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
        internal static bool IsWatching(string home)
        {
            using (var ready = Event(EventName(Instance(home), "UpdateWatching"))) {
                if (!ready.WaitOne(0)) return false;
                using (var singleton = new Mutex(false, EventName(Instance(home), "UpdateObserver"))) {
                    bool held; try { held = singleton.WaitOne(0); } catch (AbandonedMutexException) { held = true; }
                    if (!held) return true;
                    singleton.ReleaseMutex(); return false; // взведённое событие без живого владельца устарело
                }
            }
        }
        internal static bool SignalFailure(string home)
        {
            try {
                using (var failed = FailureEvent(home)) {
                    failed.Set();
                    if (!File.Exists(Path.Combine(home, Product.BundleDirectory, "exe-upgrade.json"))) return false;
                    if (!IsWatching(home)) Start(home, Path.Combine(home, Product.Name + ".previous.exe"), preserveFailure: true);
                    return IsWatching(home);
                }
            } catch (Exception ex) { new Journal(home).Write("update.observer.restart.failed kind=" + ex.GetType().Name); return false; }
        }
        internal static void Start(string home, string observerExe, bool preserveFailure = false)
        {
            if (!File.Exists(Path.Combine(home, Product.BundleDirectory, "exe-upgrade.json"))) return;
            using (var ready = Event(EventName(Instance(home), "UpdateWatching"))) {
                if (IsWatching(home)) return;
                ready.Reset();
                if (!preserveFailure) using (var failed = FailureEvent(home)) failed.Reset();
                using (var process = Process.Start(new ProcessStartInfo(observerExe, "--watch-update " + Files.Quote(home)) { UseShellExecute = false, CreateNoWindow = true })) { }
                if (!ready.WaitOne(WatcherStartTimeoutMs)) throw new IOException("Наблюдатель обновления не запустился"); // timer-ok: D — ответ старого EXE недоступен при сбое запуска; прервать активацию, успех не объявлять.
            }
        }
        internal static int Run(string home)
        {
            bool restart = false, preserveFailure = false;
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
                            string reason = WaitForOutcome(home, receipt, changed, failed);
                            if (reason.Length == 0) return 0;
                            failed.Set(); // исключить приёмку, пока внешний наблюдатель останавливает новый EXE
                            var log = new Journal(home); log.Write("update.failed reason=" + reason);
                            restart = true;
                            try {
                                preserveFailure = UpdateObservation.TryRollback(() => {
                                    using (var mutex = new Mutex(false, "Global\\" + name)) {
                                        bool owned; try { owned = mutex.WaitOne(0); } catch (AbandonedMutexException) { owned = true; }
                                        if (!owned) {
                                            try { Program.StopInstalled(name, Path.Combine(home, Product.ExeName), home, mutex, log); owned = true; }
                                            catch (Exception ex) { log.Write("update.stop.failed kind=" + ex.GetType().Name); throw; }
                                        }
                                        if (owned) try {
                                            if (File.Exists(receipt)) {
                                                var record = Json.Read(receipt);
                                                if (!Json.Bool(record, "healthAccepted")) {
                                                    string version = Json.Str(record, "version");
                                                    UpgradeInstaller.ObserveImage(home, engine, false, "rollback");
                                                    string path = Path.Combine(engine.Root, "update-state.json");
                                                    var state = File.Exists(path) ? Json.Read(path) : Json.Map(null);
                                                    state["queuedFailure"] = version; state["pending"] = false; state["failureReason"] = reason; Json.Write(path, state);
                                                }
                                            }
                                        } finally { mutex.ReleaseMutex(); }
                                    }
                                }, reasonFailed => UpdateObservation.RecordRollbackFailure(home, reasonFailed));
                            } finally {
                                // Даже ошибка записи update-state не оставляет отказ взведённым навечно.
                                if (!preserveFailure) failed.Reset();
                            }
                            return preserveFailure ? 0 : 1;
                        }
                    } finally { singleton.ReleaseMutex(); }
                }
            } catch (Exception ex) { new Journal(home).Write("update.observer.failed kind=" + ex.GetType().Name); return 1; }
            finally {
                // Мьютекс наблюдателя уже отпущен: новый трей сможет вооружить своё наблюдение.
                if (restart) try { Program.StartLauncher(Path.Combine(home, Product.ExeName), home, true, preserveUpdateFailure: preserveFailure); }
                catch (Exception ex) { new Journal(home).Write("update.restart.failed kind=" + ex.GetType().Name); }
            }
        }
        sealed class ProcessWaitHandle : WaitHandle
        {
            internal ProcessWaitHandle(IntPtr handle) { SafeWaitHandle = new SafeWaitHandle(handle, false); }
        }
        static string ProcessExitOutcome(string home, Process process, int pid, string processStarted)
        {
            bool clean = process.ExitCode == 0;
            int count = clean ? UpgradeInstaller.NoteCleanExit(home, pid, processStarted) : 0;
            if (count < 0) return null;
            return UpdateObservation.Decide(true, false, true, false, clean, count);
        }
        static string WaitForOutcome(string home, string receipt, WaitHandle changed, WaitHandle failed)
        {
            Process process = null; WaitHandle exited = null; int pid = 0; string processStarted = ""; bool exitSignaled = false;
            try {
                while (File.Exists(receipt)) {
                    var record = UpdateObservation.TryRead(() => {
                        // Одно чтение с разрешённой атомарной заменой; без скрытых повторов/Sleep.
                        using (var stream = new FileStream(receipt, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                        using (var reader = new StreamReader(stream)) return Json.Map(Json.Parse(reader.ReadToEnd()));
                    });
                    if (record == null) {
                        // Ошибка доступа во время Replace — ждём следующую доставку changed, это не исход.
                        if (!File.Exists(receipt)) return "";
                        int signal = WaitHandle.WaitAny(UpdateObservation.OutcomeHandles(failed, changed, exitSignaled ? null : exited));
                        if (signal == 0) return "UpdateFailed";
                        // Перечитываем актуальную пару до решения; уже доставленный exited не создаёт цикл при ошибке чтения.
                        if (signal == 2) exitSignaled = true;
                        continue;
                    }
                    if (Json.Bool(record, "healthAccepted")) return "";
                    if (failed.WaitOne(0)) return "UpdateFailed";
                    if (Json.Bool(record, "cleanExit")) return UpdateObservation.Decide(true, false, false, false, true, Json.Int(record, "cleanExitCount", 0));
                    if (!UpdateObservation.SameProcess(record, pid, processStarted)) {
                        exitSignaled = false;
                        if (exited != null) { exited.Dispose(); exited = null; }
                        if (process != null) { process.Dispose(); process = null; }
                        pid = Json.Int(record, "pid", 0); processStarted = Json.Str(record, "processStarted");
                        if (pid > 0) try {
                            process = Process.GetProcessById(pid); var pinned = process.Handle;
                            if (process.StartTime.ToUniversalTime().Ticks.ToString(System.Globalization.CultureInfo.InvariantCulture) != processStarted) return "process-exited";
                            exited = new ProcessWaitHandle(pinned);
                        } catch (ArgumentException) { return "process-exited"; }
                        catch (InvalidOperationException) { return "process-exited"; }
                        catch (System.ComponentModel.Win32Exception) { return "process-unavailable"; }
                    }
                    if (process != null && process.HasExited) {
                        string outcome = ProcessExitOutcome(home, process, pid, processStarted);
                        if (outcome != null) return outcome;
                        continue; // квитанция уже принадлежит другому процессу
                    }
                    DateTime progress;
                    if (!DateTime.TryParse(Json.Text(record, "lastHealthUtc", Json.Str(record, "startedUtc")), null, System.Globalization.DateTimeStyles.RoundtripKind, out progress)) return "invalid-receipt";
                    var board = new HealthBoard(new string[0], progress.ToUniversalTime());
                    DateTime now = DateTime.UtcNow;
                    if (board.FuseExpired(now)) return UpdateObservation.Decide(File.Exists(receipt), false, false, true);
                    int remaining = (int)Math.Max(1, Math.Min(HealthBoard.UpdateNoProgressFuseMs, Math.Ceiling(HealthBoard.UpdateNoProgressFuseMs - (now - board.LastEventUtc).TotalMilliseconds)));
                    var handles = UpdateObservation.OutcomeHandles(failed, changed, exited);
                    WaitHandle.WaitAny(handles, remaining); // timer-ok: C — health.accepted недоступен при зависшем новом EXE; UpdateNoProgressFuseMs от последней готовности даёт только откат.
                    // После ЛЮБОГО сигнала сначала перечитываем квитанцию: PID мог смениться, приёмка/штатный выход — завершиться.
                }
                return "";
            } finally { if (exited != null) exited.Dispose(); if (process != null) process.Dispose(); }
        }
    }
}
