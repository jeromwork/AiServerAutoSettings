using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace RemoteAgents.Launcher
{
    // The window, background apply and copy buttons share the same redaction boundary.
    internal static class DiagnosticReport
    {
        static readonly object gate = new object();
        static readonly Dictionary<string, HashSet<string>> remembered = new Dictionary<string, HashSet<string>>(StringComparer.OrdinalIgnoreCase);
        static string Version {
            get {
#if PORTABLE_TEST
                return typeof(DiagnosticReport).Assembly.GetName().Version.ToString();
#else
                return Program.Version;
#endif
            }
        }

        static IEnumerable<string> Expand(string value)
        {
            if (string.IsNullOrEmpty(value) || value.Length < 4) yield break;
            yield return value;
            // Also cover credentials inside a JSON relay/export, and multiline values after LF conversion.
            string lf = Files.LF(value);
            if (lf != value) yield return lf;
            foreach (string line in lf.Split('\n')) if (line.Length >= 4) yield return line;
            object parsed = null;
            try { parsed = Json.Parse(value); } catch (Exception) { }
            if (parsed is Dictionary<string, object> || parsed is object[])
                foreach (string child in Strings(parsed)) foreach (string secret in Expand(child)) yield return secret;
        }
        static IEnumerable<string> Strings(object value)
        {
            if (value is string) { yield return (string)value; yield break; }
            var map = value as Dictionary<string, object>;
            foreach (object child in map != null ? map.Values.AsEnumerable() : Json.Array(value))
                foreach (string text in Strings(child)) yield return text;
        }
        internal static void RememberSecrets(string home, IEnumerable<string> values)
        {
            var expanded = (values ?? Enumerable.Empty<string>()).SelectMany(Expand).ToArray();
            lock (gate) {
                HashSet<string> known;
                string key = Path.GetFullPath(home);
                if (!remembered.TryGetValue(key, out known)) remembered[key] = known = new HashSet<string>(StringComparer.Ordinal);
                foreach (string value in expanded) known.Add(value);
            }
        }
        internal static IEnumerable<string> KnownSecrets(string home)
        {
            // Keep secrets already seen during this process too: root credentials can be removed after bootstrap.
            try { RememberSecrets(home, SecretVault.Load(home).Values); } catch (Exception) { }
            lock (gate) {
                HashSet<string> known;
                return remembered.TryGetValue(Path.GetFullPath(home), out known) ? known.ToArray() : new string[0];
            }
        }
        internal static string Clean(string text, IEnumerable<string> secretValues)
        {
            text = text ?? "";
            var known = (secretValues ?? Enumerable.Empty<string>()).SelectMany(Expand).Distinct(StringComparer.Ordinal).OrderByDescending(v => v.Length);
            foreach (string value in known) {
                text = text.Replace(value, "<secret>");
                // State JSON and wizard output can contain the escaped spelling of a credential.
                string encoded = Json.Encode(value);
                if (encoded.Length >= 2) text = text.Replace(encoded.Substring(1, encoded.Length - 2), "<secret>");
            }
            return Regex.Replace(CleanFields(text), "[A-Za-z0-9+/_=-]{32,}", RedactLongToken);
        }
        static string RedactLongToken(Match match)
        {
            string token = match.Value;
            // Mixed-case alphanumeric segments can be unpadded base64, not names.
            bool secretSegment = token.Split('/').Any(segment => segment.Length >= 12 &&
                Regex.IsMatch(segment, "[A-Z]") && Regex.IsMatch(segment, "[a-z]") && Regex.IsMatch(segment, "[0-9]"));
            bool base64 = !token.StartsWith("/", StringComparison.Ordinal) &&
                Regex.IsMatch(token, "^[A-Za-z0-9+/]+={0,2}$") && token.IndexOfAny(new[] { '+', '=' }) >= 0;
            if (token.Contains("/") && !(base64 || secretSegment))
                return Regex.Replace(token, "[A-Za-z0-9+=_-]{32,}", "<secret>");
            return "<secret>";
        }
        static bool IsSecretField(string name)
        {
            // Exception names can appear inside a JSON cause string, followed by more sections.
            if (Regex.IsMatch(name, @"^\w*(?:Error|Exception)$")) return false;
            if (Regex.IsMatch(name, "token|password|passwd|secret|uuid|authorization", RegexOptions.IgnoreCase)) return true;
            // Recognize key, apiKey, private_key, etc., without treating monkey as a credential.
            string words = Regex.Replace(name, "([a-z0-9])([A-Z])", "$1_$2");
            return Regex.IsMatch(words, @"(?:^|[_.-])key(?:$|[_.-])", RegexOptions.IgnoreCase) ||
                Regex.IsMatch(name, "^(?:api|ssh|private|public|access|auth|encryption|signing)key$", RegexOptions.IgnoreCase);
        }
        static string CleanFields(string value)
        {
            value = Files.LF(value).Replace('\r', '\n');
            value = Regex.Replace(value, @"-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?(?:-----END [^-]*PRIVATE KEY-----|$)",
                "[скрыто]", RegexOptions.IgnoreCase);
            // Reuse the shared URL handling, including encoded query names and user info.
            value = Regex.Replace(value, @"\b[a-z][a-z0-9+.-]*://[^\s<>""']+",
                m => MainScreenModel.CleanSecrets(m.Value), RegexOptions.IgnoreCase);
            var fields = new Regex(@"(?<![\w.-])[""']?(?<name>[\w.-]+)[""']?\s*[:=]\s*");
            var clean = new StringBuilder();
            int position = 0;
            for (Match field = fields.Match(value); field.Success; field = fields.Match(value, position)) {
                clean.Append(value, position, field.Index - position).Append(field.Value);
                position = field.Index + field.Length;
                if (!IsSecretField(field.Groups["name"].Value)) continue;
                clean.Append("\"[скрыто]\"");
                position = SecretValueEnd(value, position);
            }
            return clean.Append(value, position, value.Length - position).ToString();
        }
        static int SecretValueEnd(string value, int start)
        {
            // Match the shared boundary: quoted/structured values end precisely; an
            // unquoted credential may contain punctuation, so hide the rest of its line.
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
                } else if (ch == '"' || ch == '\'') quote = ch;
                else if (ch == '{' || ch == '[') closers.Push(ch == '{' ? '}' : ']');
                else if (closers.Count > 0 && ch == closers.Peek()) { closers.Pop(); if (closers.Count == 0) return i + 1; }
                else if (closers.Count == 0 && (ch == '\n' || ch == ',' || ch == ';' || ch == '&' || ch == '}' || ch == ']')) return i;
            }
            return value.Length;
        }
        internal static string WriteWindowLog(string logsDir, string text, IEnumerable<string> secretValues)
        {
            string cleaned = Clean(text, secretValues);
            string stamp = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture) + " ";
            string line = stamp + cleaned.Replace("\n", "\r\n" + stamp) + "\r\n";
            // Файл ведёт общий писатель (формат, ротация .1…5, BOM); на экран уходит прежняя строка.
            foreach (string part in Files.LF(cleaned).Split('\n'))
                RaLog.WriteTo(logsDir, "config-window", LogLevel.Info, "config", "window.text", new[] { new KeyValuePair<string, string>("msg", part) });
            return line;
        }

        internal static string FormatServerApply(string jsonText, string version, string exitCode, string error = "", string mode = "")
        {
            var text = new StringBuilder("=== Диагностика серверного применения ===\n");
            Dictionary<string, object> result = null;
            try { if (!string.IsNullOrWhiteSpace(jsonText)) result = Json.Map(Json.Parse(jsonText)); }
            catch (Exception) { text.AppendLine("server-apply.json не удалось разобрать"); }
            var code = Json.Map(Json.Get(result, "code"));
            text.AppendLine("Программа: RemoteAgents " + version + "; сервер-код: sha=" + Json.Text(code, "sha", "неизвестно") + " python=" + Json.Text(code, "python", "неизвестно") +
                "; режим: " + Json.Text(result, "clientMode", mode.Length > 0 ? mode : Json.Str(result, "command")));
            var rows = Json.Array(Json.Get(result, "parts")).Select(Json.Map).ToArray();
            text.AppendLine("Секции: " + (rows.Length == 0 ? "нет данных" : string.Join(", ", rows.Select(r => Json.Str(r, "part") + "=" + Json.Str(r, "state")))));
            if (result == null) text.AppendLine("server-apply.json нет");
            else {
                text.AppendLine("Итог: ok=" + Json.Bool(result, "ok").ToString().ToLowerInvariant() + "; degraded=" + string.Join(", ", Json.Strings(Json.Get(result, "degraded"))) + "; summary=" + Json.Str(result, "summary"));
                if (Json.Str(result, "error").Length > 0) text.AppendLine("Ошибка сервера: " + Json.Str(result, "error"));
                foreach (var row in rows.Where(r => Json.Get(r, "diag") != null || Json.Str(r, "state") == "error" || Json.Str(r, "state") == "blocked")) {
                    text.AppendLine(Json.Str(row, "part") + ": " + Json.Str(row, "state") + " — " + Json.Str(row, "summary"));
                    AppendDiag(text, Json.Map(Json.Get(row, "diag")));
                }
                AppendDiag(text, Json.Map(Json.Get(result, "diag")));
            }
            if (error.Length > 0) text.AppendLine("Ошибка шага: " + error);
            text.AppendLine("Код выхода: " + (string.IsNullOrEmpty(exitCode) ? "неизвестно" : exitCode) +
                (Json.Get(result, "sshExit") != null ? "; SSH " + Json.Str(result, "sshExit") : ""));
            text.Append("=== конец диагностики ===");
            return text.ToString();
        }
        static void AppendDiag(StringBuilder text, Dictionary<string, object> diag)
        {
            if (diag.Count == 0) return;
            text.AppendLine("  запись=" + Json.Str(diag, "id") + " тип=" + Json.Str(diag, "type"));
            text.AppendLine("  сообщение: " + Json.Str(diag, "message"));
            text.AppendLine("  место: " + string.Join(" > ", Json.Strings(Json.Get(diag, "where"))));
            text.AppendLine("  причина: " + Json.Str(diag, "cause"));
            if (Json.Get(diag, "journal") is bool && !Json.Bool(diag, "journal")) text.AppendLine("  журнал сервера недоступен");
        }
        static string Tail(string path, int maxBytes)
        {
            try {
                using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
                    bool truncated = stream.Length > maxBytes;
                    if (truncated) stream.Seek(-maxBytes, SeekOrigin.End);
                    using (var reader = new StreamReader(stream, Encoding.UTF8, true)) {
                        // Do not copy a partial first line (or the middle of a UTF-8 character).
                        if (truncated) reader.ReadLine();
                        return reader.ReadToEnd();
                    }
                }
            } catch (Exception) { return "[нет данных или файл недоступен]"; }
        }
        internal static string BuildCopyText(string logsDir, string stateDir)
        {
            string home = Path.GetDirectoryName(Path.GetFullPath(stateDir));
            var secrets = KnownSecrets(home).ToArray();
            var report = new StringBuilder("RemoteAgents " + Version + "\nWindows: " + Environment.OSVersion +
                "; " + (Environment.Is64BitOperatingSystem ? "x64" : "x86") + "; UTC: " + DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture) + "\n");
            report.AppendLine("=== config-window.log (последние 200 КБ) ===").AppendLine(Tail(Path.Combine(logsDir, "config-window.log"), 200 * 1024));
            // Bound I/O too; 200 KiB covers far more than 200 ordinary launcher event lines.
            string launcher = Files.LF(Tail(Path.Combine(logsDir, "launcher.log"), 200 * 1024));
            report.AppendLine("=== launcher.log (последние 200 строк) ===").AppendLine(string.Join("\n", launcher.TrimEnd('\n').Split('\n').Reverse().Take(200).Reverse()));
            report.AppendLine("=== state/server-apply.json (до 50 КБ) ===").AppendLine(Tail(Path.Combine(stateDir, "server-apply.json"), 50 * 1024));
            try {
                var latest = new DirectoryInfo(logsDir).GetFiles("wizard-*.out").OrderByDescending(f => f.LastWriteTimeUtc).ThenBy(f => f.Name, StringComparer.Ordinal).FirstOrDefault();
                if (latest != null) report.AppendLine("=== " + latest.Name + " (последние 20 КБ) ===").AppendLine(Tail(latest.FullName, 20 * 1024));
            } catch (Exception) { report.AppendLine("wizard-*.out недоступен"); }
            return Clean(report.ToString(), secrets);
        }
    }
}
