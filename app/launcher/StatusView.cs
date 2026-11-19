using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace RemoteAgents.Launcher
{
    // Связь: «проверяем» (нет данных, идёт проверка, модуль перезапускается) — жёлтое; красное только после свежего провала.
    internal enum LinkPhase { Checking, Ok, Failed, Searching }

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
        // Дольше этого «идёт проверка» не считается проверкой: зависшая проверка становится сбоем.
        internal const int CheckingLimitSec = 120;
        internal static LinkPhase Phase(Dictionary<string, object> transport, DateTime? utcNow = null)
        {
            if (transport == null || transport.Count == 0) return LinkPhase.Checking;
            string phase = Json.Str(transport, "phase");
            // Searching is a live waiting state, even when checkingSince is old or ok was retained.
            if (phase == "searching" || Json.Str(transport, "localNet") == "down") return LinkPhase.Searching;
            if (phase == "failed") return LinkPhase.Failed;
            if (phase == "stopped") return LinkPhase.Checking;
            if (phase != "checking" && phase != "degraded")
                return (phase == "ok" || phase.Length == 0) && Json.Bool(transport, "ok") ? LinkPhase.Ok : LinkPhase.Checking;
            DateTime since;
            if (!DateTime.TryParse(Json.Str(transport, "checkingSince"), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out since))
                return LinkPhase.Checking;
            double age = ((utcNow ?? DateTime.UtcNow) - since.ToUniversalTime()).TotalSeconds;
            return age > CheckingLimitSec ? LinkPhase.Failed : LinkPhase.Checking;
        }
        internal static string DisplayText(string value)
        { return StatusText.CleanSecrets(value).Replace("\r", " ").Replace("\n", " ").Trim(); }
        internal static string Reason(Dictionary<string, object> data)
        { return DisplayText(Json.Str(Json.Map(Json.Get(data, "reason")), "text")); }
        internal static string SearchingText(Dictionary<string, object> data)
        {
            string title = Json.Str(data, "localNet") == "down" ? "Нет интернета у вас (сеть)" : "Нет связи, ищу путь";
            string reason = Reason(data);
            if (reason.StartsWith(title, StringComparison.Ordinal)) return reason;
            return title + (reason.Length == 0 ? "" : ". " + reason);
        }
        // Провал пути из прошлой проверки (из памяти) во время новой проверки — ещё не свежий результат.
        internal static bool StaleCandidate(Dictionary<string, object> candidate, Dictionary<string, object> transport, DateTime? utcNow = null)
        {
            if (Phase(transport, utcNow) != LinkPhase.Checking) return false;
            DateTime checkedAt, since;
            if (!DateTime.TryParse(Json.Str(candidate, "checkedAt"), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out checkedAt)) return true;
            if (!DateTime.TryParse(Json.Str(transport, "checkingSince"), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out since)) return true;
            return checkedAt.ToUniversalTime() < since.ToUniversalTime();
        }
        // UI readiness comes from the same fresh files as the path/tooltip, never a second process summary.
        internal static string Line(string title, Dictionary<string, object> data, bool transport = false)
        {
            if (data.Count == 0) return "⏳ " + title + ": ожидается проверка";
            if (Json.Bool(data, "ok") && (!transport || Phase(data) == LinkPhase.Ok)) return "✅ " + title + ": " + (transport ? "подключено; " + Title(data) : Summary(data));
            if (transport && Phase(data) == LinkPhase.Searching) return "⏳ " + title + ": " + SearchingText(data);
            string state = Json.Str(data, "state");
            // Legacy diagnostics without phase keep their explicit ok result; named phases follow the current protocol.
            bool waiting = state == "starting" || state == "checking" || state == "pending" || state == "off" || Json.Get(data, "ok") == null
                || transport && Json.Str(data, "phase").Length > 0 && Phase(data) == LinkPhase.Checking;
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
            if (Phase(data) == LinkPhase.Searching) return TrayMenuModel.Short(SearchingText(data), 63);
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
    // Shared by status/tray text and the main screen, including the focused Disk build.
    // The existing masking implementation lives here so every surface uses the same rules.
    internal static class StatusText
    {
        static readonly Regex SecretField = new Regex(
            @"(?<name>[""']?[\w.-]*(?:key|token|password|passwd|secret|uuid|authorization)[\w.-]*[""']?\s*[:=]\s*)",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

        // Handles JSON fields, log-style key=value pairs, URL query credentials and multiline key material.
        // Redact entire structured values rather than exposing children of a secret object/array.
        internal static string CleanSecrets(string value)
        {
            value = (value ?? "").Replace("\r\n", "\n").Replace('\r', '\n');
            value = Regex.Replace(value, @"-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?(?:-----END [^-]*PRIVATE KEY-----|$)",
                "[скрыто]", RegexOptions.IgnoreCase);
            // Mask URLs first: a user name such as "token" must not be mistaken for a log field,
            // which could otherwise leave part of its password after a semicolon.
            value = Regex.Replace(value, @"\b[a-z][a-z0-9+.-]*://[^\s<>""']+", CleanUrl, RegexOptions.IgnoreCase);
            var clean = new StringBuilder();
            int position = 0;
            for (Match field = SecretField.Match(value); field.Success; field = SecretField.Match(value, position)) {
                clean.Append(value, position, field.Index - position);
                clean.Append(field.Groups["name"].Value).Append("\"[скрыто]\"");
                position = SecretValueEnd(value, field.Index + field.Length);
            }
            clean.Append(value, position, value.Length - position);
            return clean.ToString();
        }

        static string CleanUrl(Match match)
        {
            string url = match.Value;
            int authority = url.IndexOf("://", StringComparison.Ordinal) + 3;
            int end = url.IndexOfAny(new[] { '/', '?', '#' }, authority);
            if (end < 0) end = url.Length;
            if (end > authority) {
                int at = url.LastIndexOf('@', end - 1, end - authority);
                if (at >= authority) url = url.Substring(0, authority) + "[скрыто]@" + url.Substring(at + 1);
            }
            int query = url.IndexOf('?'), fragment = url.IndexOf('#');
            if (query < 0 || fragment >= 0 && fragment < query) return url;
            int queryEnd = fragment < 0 ? url.Length : fragment;
            string[] pairs = url.Substring(query + 1, queryEnd - query - 1).Split('&');
            for (int i = 0; i < pairs.Length; i++) {
                int equals = pairs[i].IndexOf('=');
                if (equals < 0) continue;
                string name = pairs[i].Substring(0, equals);
                // Encoded parameter names are just as sensitive as plain ones.
                try { name = Uri.UnescapeDataString(name); } catch (UriFormatException) { pairs[i] = "[скрыто]"; continue; }
                if (Regex.IsMatch(name, @"key|token|password|passwd|secret|uuid|authorization", RegexOptions.IgnoreCase))
                    pairs[i] = pairs[i].Substring(0, equals + 1) + "[скрыто]";
            }
            return url.Substring(0, query + 1) + string.Join("&", pairs) + url.Substring(queryEnd);
        }

        static int SecretValueEnd(string value, int start)
        {
            // An unquoted log value has no reliable punctuation delimiter: passwords can contain
            // commas, semicolons and brackets. Hide the rest of that line rather than guessing.
            if (start < value.Length && value[start] != '"' && value[start] != '\'' && value[start] != '{' && value[start] != '[') {
                int newline = value.IndexOf('\n', start);
                return newline < 0 ? value.Length : newline;
            }
            var closers = new Stack<char>();
            char quote = '\0';
            for (int i = start; i < value.Length; i++) {
                char ch = value[i];
                if (quote != '\0') {
                    if (ch == '\\') { i++; continue; }
                    if (ch == quote) { quote = '\0'; if (closers.Count == 0) return i + 1; }
                } else if (ch == '\"' || ch == '\'') quote = ch;
                else if (ch == '{' || ch == '[') closers.Push(ch == '{' ? '}' : ']');
                else if (closers.Count > 0 && ch == closers.Peek()) { closers.Pop(); if (closers.Count == 0) return i + 1; }
                else if (closers.Count == 0 && (ch == '\n' || ch == ',' || ch == ';' || ch == '&' || ch == '}' || ch == ']')) return i;
            }
            return value.Length;
        }
    }
}
