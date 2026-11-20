using System.Collections.Generic;

namespace RemoteAgents.Launcher
{
    // Pure helpers for the remote-control switch; kept out of the network-helper source list on purpose.
    internal static class TrayBridge
    {
        internal static TrayMenuEntry Entry(CardView helper)
        {
            string text = string.IsNullOrEmpty(helper.SwitchText) ? "Удалённое управление" : helper.SwitchText;
            return new TrayMenuEntry("bridge", text, !string.IsNullOrEmpty(helper.SwitchText) && helper.SwitchEnabled) { Hint = helper.State ?? "" };
        }

        // Same rule as the wizard and ConfigApply.Bridge: bridge.enabled decides when present; otherwise
        // components.control.enabled; with no control key at all the bridge counts as on.
        internal static bool Enabled(Dictionary<string, object> config)
        {
            var bridge = Json.Map(Json.Get(config, "bridge"));
            if (Json.Get(bridge, "enabled") is bool) return Json.Bool(bridge, "enabled");
            var control = Json.Map(Json.Get(Json.Map(Json.Get(config, "components")), "control"));
            return Json.Bool(control, "enabled", true);
        }

        // Mirrors the applied bridge state into profile.bridge only when the profile already exists:
        // creating an empty profile would change how old installations read their configuration.
        internal static void SyncProfile(Dictionary<string, object> latest)
        {
            if (!(Json.Get(latest, "profile") is Dictionary<string, object>)) return;
            var profile = new Dictionary<string, object>(Json.Map(Json.Get(latest, "profile")));
            var bridge = new Dictionary<string, object>(Json.Map(Json.Get(profile, "bridge")));
            var actual = Json.Map(Json.Get(latest, "bridge"));
            bridge["enabled"] = Json.Bool(actual, "enabled", true);
            bridge["allowShell"] = Json.Bool(actual, "allowShell", true);
            profile["bridge"] = bridge; latest["profile"] = profile;
        }
    }
}
