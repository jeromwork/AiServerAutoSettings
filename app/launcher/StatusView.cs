using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;

namespace RemoteAgents.Launcher
{
    internal static class StatusView
    {
        public static Dictionary<string, object> Read(string home, string name, DateTime? utcNow = null, int maxAgeSec = 300)
        {
            try {
                string file = Files.Under(home, "status/" + name + ".json"); DateTime now = utcNow ?? DateTime.UtcNow;
                double age = (now - File.GetLastWriteTimeUtc(file)).TotalSeconds;
                if (!File.Exists(file) || age > maxAgeSec || age < -5) return Json.Map(null);
                var data = Json.Read(file); string stamp = Json.Text(data, "updatedAt", Json.Str(data, "updatedUtc"));
                if (stamp.Length > 0) {
                    DateTime updated;
                    if (!DateTime.TryParse(stamp, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out updated)) return Json.Map(null);
                    age = (now - updated.ToUniversalTime()).TotalSeconds; if (age > maxAgeSec || age < -5) return Json.Map(null);
                }
                return data;
            } catch { return Json.Map(null); }
        }
        // UI readiness comes from the same fresh files as the path/tooltip, never a second process summary.
        internal static string Line(string title, Dictionary<string, object> data, bool transport = false)
        {
            if (data.Count == 0) return "⏳ " + title + ": ожидается проверка";
            if (Json.Bool(data, "ok")) return "✅ " + title + ": " + (transport ? "подключено; " + Title(data) : Summary(data));
            string state = Json.Str(data, "state");
            bool waiting = state == "starting" || state == "checking" || state == "pending" || state == "off" || Json.Get(data, "ok") == null;
            return (waiting ? "⏳ " : "❌ ") + title + ": " + (transport ? Json.Text(data, "error", "связь не подтверждена") : Summary(data));
        }
        internal static string Happier(string home)
        {
            // Account registration is a saved check, not a heartbeat from Happier.
            try {
                var data = Json.Read(Path.Combine(home, "state", "happier-account.json"));
                return "⏳ Happier: " + (Json.Bool(data, "ok") ? "аккаунт подключён; последняя проверка " + Json.Text(data, "updatedUtc", "неизвестна") : Json.Text(data, "summary", "аккаунт не подтверждён"));
            } catch { return "⏳ Happier: аккаунт ещё не проверен"; }
        }
        public static Dictionary<string, object>[] Candidates(Dictionary<string, object> data)
        { return Json.Array(Json.Get(data, "candidates")).Select(Json.Map).ToArray(); }
        public static string Title(Dictionary<string, object> data)
        {
            if (data.Count == 0) return "нет данных";
            string active = Json.Str(data, "active");
            var candidate = Candidates(data).FirstOrDefault(c => Json.Str(c, "tag") == active) ?? Json.Map(null);
            return Json.Text(data, "title", Json.Text(candidate, "title", active.Length == 0 ? "нет данных" : active));
        }
        public static string Speed(Dictionary<string, object> data)
        {
            double n;
            return double.TryParse(Json.Str(data, "kbps"), NumberStyles.Float, CultureInfo.InvariantCulture, out n) && !double.IsNaN(n) && !double.IsInfinity(n) && n >= 0 ? n.ToString("0.#", CultureInfo.CurrentCulture) + " КБ/с" : "скорость: нет данных";
        }
        public static string Tooltip(Dictionary<string, object> data)
        {
            const string prefix = "RemoteAgents: "; string suffix = " " + Speed(data), title = Title(data);
            int room = Math.Max(1, 63 - prefix.Length - suffix.Length);
            if (title.Length > room) {
                int take = room - 1; if (take > 0 && char.IsHighSurrogate(title[take - 1])) take--;
                title = title.Substring(0, take) + "…";
            }
            return prefix + title + suffix;
        }
        public static string CheckedAt(Dictionary<string, object> data)
        {
            var candidate = Candidates(data).FirstOrDefault(c => Json.Str(c, "tag") == Json.Str(data, "active")) ?? Json.Map(null);
            return Json.Text(data, "checkedAt", Json.Text(candidate, "checkedAt", "нет данных"));
        }
        public static string Network(Dictionary<string, object> data)
        {
            var network = Json.Get(data, "network"); var map = Json.Map(network);
            return map.Count > 0 ? Json.Text(map, "title", Json.Text(map, "name", "нет данных")) : (network is string && ((string)network).Length > 0 ? (string)network : "нет данных");
        }
        public static string Metered(Dictionary<string, object> data)
        { var value = Json.Get(data, "metered"); return value is bool ? ((bool)value ? "да" : "нет") : "нет данных"; }
        internal static string Lan(Dictionary<string, object> data)
        { var networks = Json.Array(Json.Get(data, "networks")).Select(Json.Map).ToArray();
            if (networks.Length > 0 && networks.All(n => Json.Str(n, "state") == "no-helper")) return "Локальные сети: помощник не установлен — установите помощник";
            return "Локальные сети: " + networks.Count(n => Json.Str(n, "state") == "ok") + " из " + networks.Length + " работают"; }
        public static string Summary(Dictionary<string, object> data)
        {
            if (data.Count == 0) return "нет данных";
            return Json.Text(data, "summary", Json.Get(data, "ok") is bool ? (Json.Bool(data, "ok") ? "работает" : "не работает") : "нет данных");
        }
    }
}
