using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;

namespace RemoteAgents.Launcher
{
    internal sealed class ComponentRuntime : IDisposable
    {
        public readonly Component Definition; readonly string home, bundle; readonly Journal log;
        NativeJob job; Process process; ElevatedTask elevated; bool attempted; int delay = 5; DateTime next = DateTime.MinValue, started;
        public bool Enabled; public bool Healthy; public string Summary = "нет данных"; public bool Alive;
        public ComponentRuntime(Component c, bool enabled, string home, string bundle, Journal log)
        { Definition = c; Enabled = c.CommandManaged ? false : enabled; this.home = home; this.bundle = bundle; this.log = log; }
        public string Expand(string text) { return Environment.ExpandEnvironmentVariables(text.Replace("{bundle}", bundle).Replace("{home}", home).Replace("{pid}", Process.GetCurrentProcess().Id.ToString())); }
        public void Tick()
        {
            DateTime now = DateTime.UtcNow;
            if (Definition.CommandManaged) {
                var status = StatusView.Read(home, Definition.Name, maxAgeSec: 15);
                Alive = Enabled = Json.Bool(status, "enabled");
                Healthy = Alive && Json.Bool(status, "ok") && (Definition.Name != "vpn" || Json.Str(status, "state") == "on"); Summary = StatusView.Summary(status); return;
            }
            if (process != null && process.HasExited) {
                process.Dispose(); process = null; if (job != null) job.Dispose(); job = null;
                next = now.AddSeconds(delay); delay = Math.Min(60, delay * 2); log.Write("component." + Definition.Name + ".exit");
            }
            if (elevated != null && !elevated.Alive) { elevated.Dispose(); elevated = null; next = now.AddSeconds(delay); delay = Math.Min(60, delay * 2); }
            if (Enabled && process == null && elevated == null && now >= next && (!attempted || Definition.Restart == "always")) {
                attempted = true;
                try {
                    started = now;
                    if (Definition.Elevated) { elevated = new ElevatedTask(home, Definition.Name); elevated.Start(); }
                    else { job = new NativeJob(); process = job.Start(Expand(Definition.Exe), Definition.Args.Select(Expand).ToArray(), Expand(Definition.Cwd)); }
                    log.Write("component." + Definition.Name + ".start");
                } catch { if (elevated != null) elevated.Dispose(); elevated = null; if (job != null) job.Dispose(); job = null; process = null; next = now.AddSeconds(delay); delay = Math.Min(60, delay * 2); log.Write("component." + Definition.Name + ".start.failed"); }
            }
            Alive = elevated != null ? elevated.Alive : process != null && !process.HasExited; Healthy = false; Summary = "нет данных";
            try {
                string file = Definition.HealthFile.Contains("{home}") ? Expand(Definition.HealthFile) : Files.Under(home, Definition.HealthFile);
                if (File.Exists(file)) {
                    var status = Json.Read(file); Summary = Json.Text(status, "summary", "нет данных");
                    var modified = File.GetLastWriteTimeUtc(file); double age = (now - modified).TotalSeconds;
                    Healthy = Enabled && Alive && Json.Bool(status, "ok") && age >= -5 && age <= Definition.MaxAge && modified >= started;
                    if (age > Definition.MaxAge || age < -5) Summary += " (данные устарели)";
                }
            } catch { Summary = "нет данных"; }
            if (Healthy && (now - started).TotalSeconds >= 120) delay = 5;
        }
        public object Snapshot() { return new { name = Definition.Name, title = Definition.Title, enabled = Enabled, critical = Definition.Critical, alive = Alive, ok = Healthy, summary = Summary, pid = Alive && process != null ? (int?)process.Id : null }; }
        public void SetEnabled(bool enabled) { Dispose(); Enabled = enabled; attempted = false; next = DateTime.MinValue; delay = 5; Tick(); }
        public void Dispose()
        {
            if (Definition.CommandManaged && Definition.StopFile.Length > 0) {
                // Only the module-owned stop flag; never stop foreign tasks, processes or routes.
                try { Files.Atomic(Files.Under(home, Definition.StopFile), "stop\n"); } catch { log.Write("component." + Definition.Name + ".stop.failed"); }
            }
            if (elevated != null) { elevated.Dispose(); elevated = null; }
            if (job != null) { job.Dispose(); job = null; }
            if (process != null) { try { process.WaitForExit(5000); } catch { } process.Dispose(); process = null; }
            Alive = Healthy = false;
        }
    }
}
