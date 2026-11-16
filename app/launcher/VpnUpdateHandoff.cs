using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Globalization;

namespace RemoteAgents.Launcher
{
    // The elevated broker keeps owning the same Job/routes. Only its unprivileged parent changes.
    // A receipt cannot start an elevated process or change the VPN plan, session, watchdog or network.
    internal static class VpnUpdateHandoff
    {
        internal static string Receipt(string home) { return Path.Combine(home, "state", Product.Name + "-vpn-update.json"); }
        internal static bool Valid(Dictionary<string, object> receipt, string session, int parentPid, DateTime now)
        {
            DateTime expires;
            return Json.Str(receipt, "session") == session && session.Length > 0 && Json.Int(receipt, "parentPid", 0) == parentPid &&
                DateTime.TryParse(Json.Str(receipt, "expiresUtc"), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out expires) &&
                expires.ToUniversalTime() >= now && expires.ToUniversalTime() <= now.AddSeconds(300);
        }
        internal static bool Follow(string home, string session, ref Process parent)
        {
            try {
                var receipt = Json.Read(Receipt(home));
                if (!Valid(receipt, session, parent.Id, DateTime.UtcNow)) return false;
                int pid = Json.Int(receipt, "pid", 0); if (pid == 0) return true; // bounded wait, watchdog keeps checking
                using (var current = Process.GetCurrentProcess()) if (pid == current.Id) return false;
                var next = Process.GetProcessById(pid);
                try {
                    var pinned = next.Handle;
                    string expected = Path.GetFullPath(Path.Combine(home, Product.ExeName));
                    if (next.HasExited || next.StartTime.ToUniversalTime().Ticks.ToString(CultureInfo.InvariantCulture) != Json.Str(receipt, "started") ||
                        !next.MainModule.FileName.Equals(expected, StringComparison.OrdinalIgnoreCase) ||
                        !Files.Hash(expected).Equals(Json.Str(receipt, "hash"), StringComparison.OrdinalIgnoreCase)) return false;
                    parent.Dispose(); parent = next; next = null;
                    string sessionPath = Path.Combine(home, "state", "vpn-session.json");
                    var owner = Json.Read(sessionPath); owner["pid"] = parent.Id;
                    owner["startedTicks"] = parent.StartTime.ToUniversalTime().Ticks.ToString(CultureInfo.InvariantCulture); Json.Write(sessionPath, owner);
                    if (File.Exists(Path.Combine(home, Product.BundleDirectory, "exe-upgrade.json"))) {
                        // Keep a bounded fallback while the candidate is being observed. A crash must not
                        // retire the elevated broker before the previous EXE can restore its parent.
                        receipt["parentPid"] = parent.Id; receipt.Remove("pid"); receipt.Remove("started");
                        receipt["expiresUtc"] = DateTime.UtcNow.AddSeconds(240).ToString("o"); Json.Write(Receipt(home), receipt);
                    } else File.Delete(Receipt(home));
                    return true;
                } finally { if (next != null) next.Dispose(); }
            } catch { return false; }
        }
    }
}
