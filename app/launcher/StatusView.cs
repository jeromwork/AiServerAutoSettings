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
        public static string Summary(Dictionary<string, object> data)
        {
            if (data.Count == 0) return "нет данных";
            return Json.Text(data, "summary", Json.Get(data, "ok") is bool ? (Json.Bool(data, "ok") ? "работает" : "не работает") : "нет данных");
        }
    }
}
