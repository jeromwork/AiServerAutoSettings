using System;
using System.Linq;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace RemoteAgents.Launcher
{
    internal enum WindowCommand { None, Show, Exit, Logs, Restart, Rollback, CheckUpdates, SetupCheck }
    internal enum WindowExit { Unload, ConfirmApplying }

    // Pure policy, shared by startup, IPC and the window; no WinForms or process state.
    internal sealed class WindowModel
    {
        internal bool Visible { get; private set; }
        internal bool HintShown { get; private set; }
        internal WindowModel(bool hintShown = false) { HintShown = hintShown; }
        internal static WindowCommand Route(string[] args)
        {
            if (args.Contains("--exit") || args.Contains("--uninstall")) return WindowCommand.Exit;
            if (args.Contains("--restart-components")) return WindowCommand.Restart;
            if (args.Contains("--rollback")) return WindowCommand.Rollback;
            if (args.Contains("--logs")) return WindowCommand.Logs;
            if (args.Contains("--check-updates")) return WindowCommand.CheckUpdates;
            if (ShouldShow(args)) return WindowCommand.Show;
            return args.Contains("--setup-check") ? WindowCommand.SetupCheck : WindowCommand.None;
        }
        internal static bool ShouldShow(string[] args)
        {
            if (args.Any(a => new[] { "--exit", "--uninstall", "--identify", "--install-stop", "--restart-components", "--rollback", "--logs", "--check-updates", "--disk-shell" }.Contains(a))) return false;
            if (args.Any(a => new[] { "--show", "--started", "--settings" }.Contains(a))) return true;
            return !args.Contains("--tray") && !args.Contains("--after-update") && !args.Contains("--setup-check");
        }
        internal static string[] ForwardArguments(string[] args)
        { return ShouldShow(args) && !args.Contains("--show") ? args.Concat(new[] { "--show" }).ToArray() : args; }
        internal void Show() { Visible = true; }
        internal bool CloseToTray()
        { Visible = false; bool notify = !HintShown; HintShown = true; return notify; }
        internal WindowExit Exit(bool applying) { return applying ? WindowExit.ConfirmApplying : WindowExit.Unload; }
        internal static bool CanOpen(string page, string operation)
        { return page == "Конфиг" || page == "Подробно" || page == "Сервис" || string.IsNullOrEmpty(operation); }
        // Pending (VPN not yet confirmed, a server install) is handed to the tray and does not hold up «Готово»;
        // Disk runs in the background (BackgroundWork.Disk) and never gates it.
        internal static bool CanFinish(bool running, IDictionary<string, SectionState> states)
        { return !running && states.Where(s => s.Key != ConfigSections.Disk).All(s => s.Value == SectionState.Done || s.Value == SectionState.Unchanged || s.Value == SectionState.Failed || s.Value == SectionState.Blocked || s.Value == SectionState.Pending); }
        internal const string DiskInBackground = "Диск устанавливается в фоне — окно можно закрыть, программа продолжит сама. Папки сервера принимайте в Syncthing Tray.";
        internal static string Conflict(string operation)
        { return string.IsNullOrEmpty(operation) ? "" : "Идёт " + operation + ", подождите"; }
    }

    internal static class LauncherInstallerGate
    {
        internal static bool TryEnter(Mutex installer, string[] args, out bool owned)
        {
            owned = false;
            try { owned = installer.WaitOne(0); } catch (AbandonedMutexException) { owned = true; }
            return owned;
        }
    }

    // One background job at a time for the whole process, not tied to any window: closing a window keeps it
    // running, only Stop (tray exit) cancels it. A request during a run replaces the queued one and runs right after.
    // The only job is the Disk install (Syncthing and Syncthing Tray, pairing, folders to accept at once).
    internal sealed class SerialRunner<T> where T : class
    {
        readonly object gate = new object();
        readonly CancellationTokenSource stop = new CancellationTokenSource();
        Func<CancellationToken, Task<T>> next; bool busy; T last;
        // Raised on a worker thread when a run starts or the queue drains.
        internal event Action Changed = delegate { };
        internal bool Busy { get { lock (gate) return busy; } }
        internal T Last { get { lock (gate) return last; } }
        internal Task Current { get; private set; }
        internal SerialRunner() { Current = Task.FromResult(true); }
        // true: started now; false: queued behind the running job.
        internal bool Start(Func<CancellationToken, Task<T>> work)
        {
            lock (gate) {
                if (stop.IsCancellationRequested) return false;
                if (busy) { next = work; return false; }
                busy = true; Current = Task.Run(() => Loop(work));
            }
            Changed(); return true;
        }
        async Task Loop(Func<CancellationToken, Task<T>> work)
        {
            while (true) {
                T result = null;
                try { result = await work(stop.Token).ConfigureAwait(false); } catch (Exception) { }
                lock (gate) {
                    if (result != null) last = result;
                    if (next == null || stop.IsCancellationRequested) { next = null; busy = false; break; }
                    work = next; next = null;
                }
            }
            Changed();
        }
        internal void Stop() { lock (gate) { next = null; } stop.Cancel(); }
    }
    internal sealed class DiskRun { internal bool Ok; internal string Summary = "", Binding = ""; }
    internal static class BackgroundWork { internal static readonly SerialRunner<DiskRun> Disk = new SerialRunner<DiskRun>(); }

    // Wait for two continuous minutes of fresh confirmed connectivity, then five minutes per attempt.
    internal sealed class ConfigSyncSchedule
    {
        DateTime? connectedSince; DateTime next = DateTime.MinValue;
        internal bool Due(bool connected, DateTime now, bool occupied)
        {
            if (!connected) { connectedSince = null; return false; }
            if (!connectedSince.HasValue) connectedSince = now;
            return !occupied && now >= connectedSince.Value.AddMinutes(2) && now >= next;
        }
        internal void Started(DateTime now) { next = now.AddMinutes(5); }
    }
}
