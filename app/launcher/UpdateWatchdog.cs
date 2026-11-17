using System;
using System.Diagnostics;
using System.IO;
using System.Security.Principal;
using System.Threading;

namespace RemoteAgents.Launcher
{
    // The previous EXE watches the same receipt, including failure before the first tray Tick.
    internal static class UpdateWatchdog
    {
        static bool Alive(int pid, string started)
        {
            try { using (var p = Process.GetProcessById(pid)) return !p.HasExited && p.StartTime.ToUniversalTime().Ticks.ToString(System.Globalization.CultureInfo.InvariantCulture) == started; }
            catch { return false; }
        }
        internal static int Run(string home, string parentId)
        {
            try {
                var engine = new UpdateEngine(home, Program.Version);
                string receipt = Path.Combine(engine.Root, "exe-upgrade.json"); DateTime parentGone = DateTime.MaxValue;
                int originalId; Process original = null;
                if (int.TryParse(parentId, out originalId)) try { original = Process.GetProcessById(originalId); var pinned = original.Handle; } catch { }
                try {
                    while (File.Exists(receipt)) {
                        var record = Json.Read(receipt); DateTime began;
                        if (!DateTime.TryParse(Json.Str(record, "startedUtc"), null, System.Globalization.DateTimeStyles.RoundtripKind, out began)) return 1;
                        if (DateTime.UtcNow >= began.ToUniversalTime().AddSeconds(125)) break;
                        int pid = Json.Int(record, "pid", 0);
                        if (pid > 0 && !Alive(pid, Json.Str(record, "processStarted"))) break;
                        if (original == null || original.HasExited) {
                            if (parentGone == DateTime.MaxValue) parentGone = DateTime.UtcNow;
                            if (pid == 0 && (DateTime.UtcNow - parentGone).TotalSeconds >= 5) break;
                        }
                        Thread.Sleep(250);
                    }
                } finally { if (original != null) original.Dispose(); }
                if (!File.Exists(receipt)) return 0;
                var sid = WindowsIdentity.GetCurrent().User; string name = Program.InstanceName(home, sid);
                using (var mutex = new Mutex(false, "Global\\" + name)) {
                    bool held; try { held = mutex.WaitOne(0); } catch (AbandonedMutexException) { held = true; }
                    if (!held) Program.StopInstalled(name, Path.Combine(home, Product.ExeName), home, mutex, new Journal(home));
                    try {
                        if (File.Exists(receipt)) {
                            string version = Json.Str(Json.Read(receipt), "version");
                            UpgradeInstaller.ObserveImage(home, engine, false, "rollback");
                            string path = Path.Combine(engine.Root, "update-state.json");
                            var state = File.Exists(path) ? Json.Read(path) : Json.Map(null);
                            state["queuedFailure"] = version; Json.Write(path, state);
                        }
                    } finally { mutex.ReleaseMutex(); }
                }
                Program.StartLauncher(Path.Combine(home, Product.ExeName), home, true); return 0;
            } catch { return 1; }
        }
    }
}
