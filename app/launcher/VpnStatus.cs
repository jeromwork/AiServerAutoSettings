using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;

namespace RemoteAgents.Launcher
{
    internal static class VpnStatus
    {
        // Terminal results are events, not health heartbeats. Keep the reason
        // until the next explicit action; both tray and card read this same file.
        internal static Dictionary<string, object> Read(string home)
        {
            try {
                var status = Json.Read(Path.Combine(home, "status/vpn.json"));
                if (!Json.Bool(status, "enabled") || Json.Str(status, "state") == "awaiting-uac") return status;
                bool alive = OwnerAlive(home); DateTime stamp;
                if (alive && DateTime.TryParse(Json.Str(status, "updatedAt"), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out stamp)) {
                    double age = (DateTime.UtcNow - stamp.ToUniversalTime()).TotalSeconds;
                    if (age >= 0 && age <= 3) return status;
                }
                string state = alive ? "watchdog-stalled" : "core-exited";
                // The host's independent lease has already closed the core Job at 2.5 s.
                // Also request host exit when it returns from a stalled system call.
                Files.Atomic(Path.Combine(home, "state/vpn.stop"), "stop\n");
                status = new Dictionary<string, object> { { "ok", false }, { "enabled", false }, { "state", state }, { "summary", VpnWatchdog.FailureSummary(state) }, { "updatedAt", DateTime.UtcNow.ToString("o") } };
                Files.Atomic(Path.Combine(home, "status/vpn.json"), Json.Encode(status)); return status;
            } catch { return Json.Map(null); }
        }
        static bool OwnerAlive(string home)
        {
            try {
                var owner = Json.Read(Path.Combine(home, "state/vpn-host.json"));
                using (var process = Process.GetProcessById(Json.Int(owner, "pid", 0)))
                    // net48 HasExited opens PROCESS_QUERY_INFORMATION, denied across UAC.
                    // WaitForExit(0) needs SYNCHRONIZE; StartTime uses QUERY_LIMITED_INFORMATION.
                    return !process.WaitForExit(0) && process.StartTime.ToUniversalTime().Ticks.ToString(CultureInfo.InvariantCulture) == Json.Str(owner, "startedTicks");
            } catch { return false; }
        }
    }
}
