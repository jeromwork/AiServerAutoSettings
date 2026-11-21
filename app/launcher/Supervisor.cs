using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using Microsoft.Win32.SafeHandles;

namespace RemoteAgents.Launcher
{
    internal sealed class ComponentRuntime : IDisposable
    {
        public readonly Component Definition; readonly string home, bundle; readonly Journal log;
        NativeJob job; Process process; ElevatedTask elevated; bool attempted; int delay = 5; DateTime next = DateTime.MinValue, started;
        TransportBusBridge transportBridge;
        internal EventBus Bus; // шина: component.start|exit (ставит TrayContext)
        public bool Enabled; public bool Healthy; public string Summary = "нет данных"; public bool Alive;
        public ComponentRuntime(Component c, bool enabled, string home, string bundle, Journal log)
        { Definition = c; Enabled = c.CommandManaged ? false : enabled; this.home = home; this.bundle = bundle; this.log = log; }
        public string Expand(string text) { return Environment.ExpandEnvironmentVariables(text.Replace("{bundle}", bundle).Replace("{home}", home).Replace("{pid}", Process.GetCurrentProcess().Id.ToString())); }
        public void Tick()
        {
            if (!Product.VpnEnabled && Definition.Name == "vpn") { Enabled = Alive = Healthy = false; Summary = "Отключено в этой версии"; return; }
            DateTime now = DateTime.UtcNow;
            if (Definition.CommandManaged) {
                var status = StatusView.Read(home, Definition.Name, maxAgeSec: 15);
                Alive = Enabled = Json.Bool(status, "enabled");
                Healthy = Alive && Json.Bool(status, "ok") && (Definition.Name != "vpn" || Json.Str(status, "state") == "on"); Summary = StatusView.Summary(status); return;
            }
            if (process != null && process.HasExited) {
                int exitCode = -1; try { exitCode = process.ExitCode; } catch { }
                if (transportBridge != null) { transportBridge.CompleteAfterProcessExit(); transportBridge = null; }
                process.Dispose(); process = null; if (job != null) job.Dispose(); job = null;
                // Код выхода в журнал: перезапуск по предохранителю памяти (75) отличается от падений; пауза общая, 5 с до 60 с.
                next = now.AddSeconds(delay); delay = Math.Min(60, delay * 2); log.Write("component." + Definition.Name + ".exit code=" + exitCode); TrayBusWiring.ComponentExit(Bus, Definition.Name, exitCode);
            }
            if (elevated != null && !elevated.Alive) { elevated.Dispose(); elevated = null; next = now.AddSeconds(delay); delay = Math.Min(60, delay * 2); }
            if (Enabled && process == null && elevated == null && now >= next && (!attempted || Definition.Restart == "always")) {
                attempted = true;
                try {
                    started = now;
                    if (Definition.Elevated) { elevated = new ElevatedTask(home, Definition.Name); elevated.Start(); }
                    else if (Definition.Bus) {
                        job = new NativeJob();
                        SafeFileHandle readEnd, writeEnd;
                        // The build channel is passed explicitly; inherited environment/config cannot enable faults in Main.
                        var busArgs = Definition.Args.Select(Expand).ToArray();
                        if (Definition.Name == "transport") busArgs = TransportFaultCommand.DaemonArguments(busArgs, UpdateChannel.IsTest);
                        process = job.StartDuplex(Expand(Definition.Exe), busArgs,
                            Expand(Definition.Cwd), out readEnd, out writeEnd);
                        try {
                            transportBridge = new TransportBusBridge(new FileStream(readEnd, FileAccess.Read),
                                new FileStream(writeEnd, FileAccess.Write), Bus, Path.Combine(home, "logs"));
                            transportBridge.Start();
                            ApplyPriority();
                        } catch { readEnd.Dispose(); writeEnd.Dispose(); throw; }
                    }
                    else { job = new NativeJob(); process = job.Start(Expand(Definition.Exe), Definition.Args.Select(Expand).ToArray(), Expand(Definition.Cwd)); ApplyPriority(); }
                    log.Write("component." + Definition.Name + ".start"); TrayBusWiring.ComponentStart(Bus, Definition.Name);
                } catch { if (elevated != null) elevated.Dispose(); elevated = null; if (job != null) job.Dispose(); job = null; if (transportBridge != null) { transportBridge.Dispose(); transportBridge = null; } if (process != null) process.Dispose(); process = null; next = now.AddSeconds(delay); delay = Math.Min(60, delay * 2); log.Write("component." + Definition.Name + ".start.failed"); }
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
        public void CheckStale() { CheckStale(DateTime.UtcNow); }
        readonly StaleChecker staleChecker = new StaleChecker();
        // Только в UI-потоке (доставка tick.supervisor через TryPostUi): работает с process/job и теми же полями, что Tick().
        public void CheckStale(DateTime now)
        {
            bool expected = Enabled && !Definition.CommandManaged && Definition.HasPeriodicStatus
                && Definition.Restart == "always" && (Alive || process != null || elevated != null);
            DateTime? modified = null;
            try {
                if (expected) {
                    string file = Definition.HealthFile.Contains("{home}") ? Expand(Definition.HealthFile) : Files.Under(home, Definition.HealthFile);
                    if (File.Exists(file)) modified = File.GetLastWriteTimeUtc(file);
                }
            } catch { }
            // Учитываем каждый тик, даже без доступного статуса; после сна запоминаем resyncUtc на полный предохранитель.
            try {
                if (staleChecker.Check(modified, now, Definition.MaxAge, started, expected) == SupervisorDecision.KillAndRestart) {
                    // Предохранитель (конституция 4а): свежий статус компонента недоступен, если процесс завис; при срабатывании — убить процесс и перезапустить, успех не объявляет.
                    KillStale(now, staleChecker.AgeMs(modified, now, started) / 1000);
                }
            } catch { }
        }
        void KillStale(DateTime now, double ageSec)
        {
            if (process != null) { try { process.Kill(); } catch { } try { process.WaitForExit(5000); } catch { } process.Dispose(); process = null; }
            if (job != null) { try { job.Dispose(); } catch { } job = null; }
            if (elevated != null) { try { elevated.Dispose(); } catch { } elevated = null; }
            Alive = Healthy = false;
            next = now.AddSeconds(delay); delay = Math.Min(60, delay * 2);
            log.Write("component." + Definition.Name + ".stale-restart age=" + (int)ageSec + "s");
            TrayBusWiring.ComponentStaleRestart(Bus, Definition.Name);
        }
        // Связь не должна отставать от обычных программ при нехватке процессора/памяти; сбой установки приоритета не фатален.
        void ApplyPriority()
        { if (Definition.Priority == "above-normal") { try { process.PriorityClass = ProcessPriorityClass.AboveNormal; } catch { log.Write("component." + Definition.Name + ".priority.failed"); } } }
        public object Snapshot() { return new { name = Definition.Name, title = Definition.Title, enabled = Enabled, critical = Definition.Critical, alive = Alive, ok = Healthy, summary = Summary, pid = Alive && process != null ? (int?)process.Id : null }; }
        public void SetEnabled(bool enabled) { Dispose(); Enabled = enabled; attempted = false; next = DateTime.MinValue; delay = 5; Tick(); }
        public void Dispose() { Dispose(false); }
        public void Dispose(bool preserveCommandManaged)
        {
            if (!preserveCommandManaged && Definition.CommandManaged && Definition.StopFile.Length > 0) {
                // Only the module-owned stop flag; never stop foreign tasks, processes or routes.
                try { Files.Atomic(Files.Under(home, Definition.StopFile), "stop\n"); } catch { log.Write("component." + Definition.Name + ".stop.failed"); }
            }
            if (elevated != null) { elevated.Dispose(); elevated = null; }
            if (transportBridge != null) { transportBridge.Dispose(); transportBridge = null; }
            if (job != null) { job.Dispose(); job = null; }
            if (process != null) { try { process.WaitForExit(5000); } catch { } process.Dispose(); process = null; }
            Alive = Healthy = false;
        }
    }
}
