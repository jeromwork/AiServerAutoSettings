using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.Principal;
using System.Threading;

namespace RemoteAgents.Launcher
{
    // Reuse the bridge's existing environment mutex + exclusive operation registry.
    // Reserving a live entry closes the race between checking processes and stopping the bridge.
    internal sealed class UpdateEnvironment : IDisposable
    {
        readonly string path, id = Guid.NewGuid().ToString("N");
        readonly Mutex mutex;
        UpdateEnvironment(string root, string name) { path = Path.Combine(root, "operations.json"); mutex = new Mutex(false, name); }
        internal static bool Active(Dictionary<string, object> record, Func<int, string, bool> live)
        {
            if (record.Count > 0 && Json.Int(record, "schema", 0) != 1) return true;
            return Json.Array(Json.Get(record, "operations")).Select(Json.Map).Any(p => live(Json.Int(p, "pid", 0), Json.Str(p, "started")));
        }
        static bool Live(int pid, string started)
        {
            try { using (var p = Process.GetProcessById(pid)) return !p.HasExited && p.StartTime.ToUniversalTime().Ticks.ToString() == started; }
            catch (ArgumentException) { return false; } catch { return true; }
        }
        bool Enter() { try { return mutex.WaitOne(0); } catch (AbandonedMutexException) { return true; } }
        internal static UpdateEnvironment TryReserve()
        {
            var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            var lease = new UpdateEnvironment(Path.Combine(local, "RemoteAgents", "environment"), "Global\\RemoteAgents.Environment." + WindowsIdentity.GetCurrent().User.Value);
            if (!lease.Enter()) { lease.mutex.Dispose(); return null; }
            bool reserved = false;
            try {
                foreach (string node in new[] { Path.GetDirectoryName(lease.path), Path.GetDirectoryName(Path.GetDirectoryName(lease.path)), lease.path })
                    if ((File.Exists(node) || Directory.Exists(node)) && (File.GetAttributes(node) & FileAttributes.ReparsePoint) != 0) return null;
                var raw = File.Exists(lease.path) ? Json.Parse(File.ReadAllText(lease.path)) : Json.Map(null);
                if (!(raw is Dictionary<string, object>)) return null;
                var data = Json.Map(raw);
                if (Active(data, Live)) return null;
                using (var p = Process.GetCurrentProcess()) Json.Write(lease.path, new { schema = 1, operations = new[] { new {
                    id = lease.id, taskId = "remoteagents-update", pid = p.Id, started = p.StartTime.ToUniversalTime().Ticks,
                    began = DateTime.UtcNow.Ticks, operation = "process_start", exclusive = true } } });
                reserved = true; return lease;
            } finally { lease.mutex.ReleaseMutex(); if (!reserved) lease.mutex.Dispose(); }
        }
        public void Dispose()
        {
            bool held = false;
            try {
                try { held = mutex.WaitOne(5000); } catch (AbandonedMutexException) { held = true; }
                if (held && File.Exists(path)) {
                    var data = Json.Read(path); data["operations"] = Json.Array(Json.Get(data, "operations")).Where(x => Json.Str(Json.Map(x), "id") != id).ToArray(); Json.Write(path, data);
                }
            } finally { if (held) mutex.ReleaseMutex(); mutex.Dispose(); }
        }
    }
}
