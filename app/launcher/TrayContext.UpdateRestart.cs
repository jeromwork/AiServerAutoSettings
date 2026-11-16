using System;
using System.Diagnostics;
using System.IO;
using System.Linq;

namespace RemoteAgents.Launcher
{
    internal sealed partial class TrayContext
    {
        bool keepVpnOnRestart;
        void PrepareUpdateRestart()
        {
            var state = UpdateState();
            // Actual enabled state, including paused/off modules. No component toggles or secret copies.
            state["runningComponents"] = runtimes.Where(r => r.Enabled && !r.Definition.CommandManaged).Select(r => r.Definition.Name).ToArray();
            var vpn = VpnStatus.Read(home);
            keepVpnOnRestart = Json.Bool(vpn, "ok") && Json.Str(vpn, "state") == "on";
            var owner = keepVpnOnRestart ? Json.Read(Path.Combine(home, "state", "vpn-session.json")) : Json.Map(null);
            bool owned = keepVpnOnRestart && Json.Int(owner, "pid", 0) == Process.GetCurrentProcess().Id;
            state["vpnOn"] = keepVpnOnRestart; state["vpnHandoff"] = owned; Json.Write(UpdateStatePath, state);
            if (!owned) return;
            string session = Json.Str(owner, "session");
            Json.Write(VpnUpdateHandoff.Receipt(home), new { session, parentPid = Process.GetCurrentProcess().Id,
                expiresUtc = DateTime.UtcNow.AddSeconds(90).ToString("o"), hash = Files.Hash(Path.Combine(home, Product.ExeName)) });
        }
        void AttachUpdateRestart()
        {
            string path = VpnUpdateHandoff.Receipt(home); if (!File.Exists(path)) return;
            var receipt = Json.Read(path);
            using (var p = Process.GetCurrentProcess()) {
                if (!Files.Hash(Program.Exe).Equals(Json.Str(receipt, "hash"), StringComparison.OrdinalIgnoreCase)) return;
                receipt["pid"] = p.Id; receipt["started"] = p.StartTime.ToUniversalTime().Ticks.ToString(System.Globalization.CultureInfo.InvariantCulture); Json.Write(path, receipt);
            }
        }
        bool UpdateHealthReady()
        {
            var state = UpdateState(); if (!Json.Bool(state, "pending")) return true;
            return Json.Strings(Json.Get(state, "runningComponents")).All(name => runtimes.Any(r => r.Definition.Name == name && (name == "disk" ? r.Alive && diskSession != null && diskSession.ServerConnected && (DateTime.UtcNow - diskUpdated).TotalSeconds <= 10 : r.Healthy))) &&
                (!Json.Bool(state, "vpnOn") || (Json.Bool(VpnStatus.Read(home), "ok") &&
                    (!Json.Bool(state, "vpnHandoff") || Json.Int(Json.Read(Path.Combine(home, "state", "vpn-session.json")), "pid", 0) == Process.GetCurrentProcess().Id)));
        }
    }
}
