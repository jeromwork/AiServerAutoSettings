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
                            string reason;
                            while (true) {
                                reason = WaitForOutcome(home, receipt, changed, failed);
                                if (reason.Length != 0) break;
                                if (UpgradeInstaller.TryFinishObservation(home, () => {
                                    ready.Reset(); singleton.ReleaseMutex(); held = false;
                                })) return 0;
                                // B успел зарегистрироваться после чистого выхода A: продолжаем за B.
                            }
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
                                            UpgradeInstaller.RollbackObservedImage(home, engine, reason);
                                        } finally { mutex.ReleaseMutex(); }
                                    }
                                }, reasonFailed => UpdateObservation.RecordRollbackFailure(home, reasonFailed));
                            } finally {
                                // Даже ошибка записи update-state не оставляет отказ взведённым навечно.
                                if (!preserveFailure) failed.Reset();
                            }
                            return preserveFailure ? 0 : 1;
                        }
                    } finally { if (held) singleton.ReleaseMutex(); }
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
        sealed class ImageProcess : UpdateObservation.IImageProcess
        {
            readonly Process process; readonly WaitHandle exited;
            internal ImageProcess(int pid, string started)
            {
                process = Process.GetProcessById(pid);
                try {
                    var pinned = process.Handle;
                    if (process.StartTime.ToUniversalTime().Ticks.ToString(System.Globalization.CultureInfo.InvariantCulture) != started)
                        throw new InvalidOperationException("Process identity changed");
                    exited = new ProcessWaitHandle(pinned);
                } catch { process.Dispose(); throw; }
            }
            public WaitHandle Exited { get { return exited; } }
            public bool HasExited { get { return process.HasExited; } }
            public bool CleanExit { get { return process.ExitCode == 0; } }
            public void Dispose() { exited.Dispose(); process.Dispose(); }
        }
        static string WaitForOutcome(string home, string receipt, WaitHandle changed, WaitHandle failed)
        {
            return UpdateObservation.WaitForOutcome(() => File.Exists(receipt), () => UpdateObservation.ReadReceipt(receipt),
                changed, failed, (pid, started) => new ImageProcess(pid, started),
                (pid, started) => UpgradeInstaller.NoteCleanExit(home, pid, started), () => DateTime.UtcNow,
                (handles, remaining) => WaitHandle.WaitAny(handles, remaining));
        }
    }
}
