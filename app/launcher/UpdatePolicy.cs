using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace RemoteAgents.Launcher
{
    internal sealed class ConfigCompatibilityException : Exception
    {
        internal ConfigCompatibilityException() : base("конфиг не поддерживается; попросите администратора выдать новый конфиг") { }
    }
    // Version 1 keeps its format. Defaults are an additive migration, never a rewrite of secrets.
    internal static class UpdatePolicy
    {
        internal const int ConfigSchema = 1;
        internal static bool Defaults(Dictionary<string, object> settings)
        {
            var update = Json.Map(Json.Get(settings, "update")); bool changed = !settings.ContainsKey("update");
            // Builds before auto-update wrote {"enabled": false} by themselves; that was never a decision.
            // An explicit opt-out always carries "auto" (owner decision 16.11.2026: updates are on by default).
            if (!update.ContainsKey("auto") && update.ContainsKey("enabled")) { update["enabled"] = true; changed = true; }
            foreach (var pair in new Dictionary<string, object> { { "enabled", true }, { "auto", true }, { "intervalHours", 6 }, { "remoteDir", UpdateChannel.RemoteDir } })
                if (!update.ContainsKey(pair.Key)) { update[pair.Key] = pair.Value; changed = true; }
            settings["update"] = update; return changed;
        }
        internal static int Interval(Dictionary<string, object> update) { return Math.Max(1, Math.Min(168, Json.Int(update, "intervalHours", 6))); }
        // Used by the NEW EXE before any activation. No Configuration constructor, vault, network or writes.
        internal static Dictionary<string, object> Compatible(string path)
        {
            try {
                var value = Json.Parse(File.ReadAllText(path));
                if (!(value is Dictionary<string, object>)) throw new InvalidDataException();
                var settings = Json.Map(value);
                if (settings.ContainsKey("schema") && Json.Str(settings, "schema") != "1") throw new InvalidDataException();
                if (settings.ContainsKey("profile")) ConfigBundle.Parse(Json.Encode(settings["profile"]));
                foreach (string field in new[] { "components", "transport", "update" })
                    if (settings.ContainsKey(field) && !(settings[field] is Dictionary<string, object>)) throw new InvalidDataException();
                var update = Json.Map(Json.Get(settings, "update"));
                foreach (string field in new[] { "enabled", "auto" }) if (update.ContainsKey(field) && !(update[field] is bool)) throw new InvalidDataException();
                if (update.ContainsKey("intervalHours") && (!int.TryParse(Json.Str(update, "intervalHours"), out var hours) || hours < 1 || hours > 168)) throw new InvalidDataException();
                settings["schema"] = ConfigSchema; Defaults(settings); return settings;
            } catch { throw new ConfigCompatibilityException(); }
        }
    }
    internal sealed class UpdateSchedule
    {
        DateTime next = DateTime.MinValue;
        internal void Retry() { next = DateTime.MinValue; }
        internal bool Due(DateTime now, Dictionary<string, object> update, bool occupied)
        { return Json.Bool(update, "enabled", true) && !occupied && now >= next; }
        internal void Started(DateTime now, Dictionary<string, object> update) { next = now.AddHours(UpdatePolicy.Interval(update)); }
        internal static bool Safe(string mutation, bool disk, bool windows, bool bridge)
        { return mutation.Length == 0 && !disk && !windows && !bridge; }
    }
}
