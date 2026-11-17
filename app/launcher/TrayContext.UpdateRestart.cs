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
            // The helper is bound to the pipe lifetime: restart closes its jobs first.
            // Restore the saved intent only after the new tray authenticates a fresh helper.
            state["vpnOn"] = keepVpnOnRestart || Json.Bool(state, "pending") && Json.Bool(state, "vpnOn");
            state["resumeVpn"] = state["vpnOn"]; state.Remove("vpnHandoff"); Json.Write(UpdateStatePath, state);
            keepVpnOnRestart = false;
        }
        bool resumeUpdatedVpn;
        void AttachUpdateRestart()
        {
            var state = UpdateState();
            resumeUpdatedVpn = Json.Bool(state, "resumeVpn") || Json.Bool(state, "pending") && Json.Bool(state, "vpnOn");
            state.Remove("resumeVpn"); Json.Write(UpdateStatePath, state);
        }
        void ResumeUpdatedVpn(System.Collections.Generic.Dictionary<string, object> transport)
        {
            if (!resumeUpdatedVpn || netHelper == null || !netHelper.Ready || !Json.Bool(transport, "ok") || actionBusy || vpnActionBusy) return;
            resumeUpdatedVpn = false;
            var vpn = runtimes.FirstOrDefault(c => c.Definition.Name == "vpn");
            if (vpn != null) CheckVpn(vpn, true);
        }
        bool UpdateHealthReady()
        {
            var state = UpdateState(); if (!Json.Bool(state, "pending")) return true;
            return Json.Strings(Json.Get(state, "runningComponents")).All(name => runtimes.Any(r => r.Definition.Name == name && (name == "disk" ? r.Alive && diskSession != null && diskSession.ServerConnected && (DateTime.UtcNow - diskUpdated).TotalSeconds <= 10 : r.Healthy))) &&
                (!Json.Bool(state, "vpnOn") || (!resumeUpdatedVpn && netHelper != null && netHelper.Ready && Json.Bool(VpnStatus.Read(home), "ok") && Json.Str(VpnStatus.Read(home), "owner") == "net-helper" && Json.Str(VpnStatus.Read(home), "state") == "on"));
        }
    }
}
