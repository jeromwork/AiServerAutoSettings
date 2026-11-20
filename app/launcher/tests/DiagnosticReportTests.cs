using System;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;

namespace RemoteAgents.Launcher
{
    // ConfigTests keeps the existing config suite and adds the portable diagnostic boundary.
    internal static class DiagnosticReportTests
    {
        static int count;
        static void Check(bool value, string message)
        { if (!value) throw new Exception("DiagnosticReport: " + message); count++; }
        static void NoSecrets(string text, params string[] secrets)
        { foreach (string secret in secrets) Check(!text.Contains(secret), "credential removed: length " + secret.Length); }
        internal static void Run()
        {
            const string stored = "S3cr3t-Value-For-Test-123", requested = "request-only-pass", nested = "nested-relay-pass";
            string key = new string('A', 40), pem = "-----BEGIN PRIVATE KEY-----\nprivate-material\n-----END PRIVATE KEY-----";
            string clean = DiagnosticReport.Clean(stored + "\npassword=abc123\n" + key + "\n" + pem, new[] { stored });
            NoSecrets(clean, stored, "abc123", key, "private-material", "BEGIN PRIVATE KEY");
            Check(clean.Contains("<secret>"), "known values use the shared placeholder");
            NoSecrets(DiagnosticReport.Clean("short pwd", new[] { "pwd" }), "<secret>");
            Check(DiagnosticReport.Clean("short pwd", new[] { "pwd" }) == "short pwd", "values below four characters are ignored");
            string multiline = "line-one\r\nline-two", punctuation = "pass\"with\\slash";
            NoSecrets(DiagnosticReport.Clean(Json.Encode(new { message = punctuation }), new[] { punctuation }), "pass", "with", "slash");
            NoSecrets(DiagnosticReport.Clean("line-one\nline-two", new[] { multiline }), "line-one", "line-two");
            string path = "/usr/local/lib/remoteagents/lan_pc_access.py";
            string longMessage = string.Concat(Enumerable.Repeat("The server could not finish applying the requested configuration because a required helper file is missing. ", 2));
            var details = new[] { "KeyError: 'lan_pc_access.py'", path, path.TrimStart('/'), "path=" + path,
                "/home/remoteagents/.local/share/remoteagents/happier-web/config.json",
                "server_apply.py:1061:part", "sha=012345abcdef", longMessage,
                "monkey: banana", "причина: MissingKeyException: 'lan_pc_access.py'" };
            clean = DiagnosticReport.Clean(string.Join("\n", details), null);
            foreach (string detail in details) Check(clean.Contains(detail), "clean retains " + detail);
            string inline = Json.Encode(ConfigBundle.D("cause", "KeyError: 'lan_pc_access.py'", "parts",
                new[] { ConfigBundle.D("part", "lan:share", "state", "ready", "summary", longMessage) }));
            Check(DiagnosticReport.Clean(inline, null) == inline, "inline JSON cause retains following sections");
            inline = Json.Encode(ConfigBundle.D("cause", "MissingKeyException: file unavailable", "parts", new[] { "agent", "lan:share" }));
            Check(DiagnosticReport.Clean(inline, null) == inline, "unquoted exception message retains inline sections");

            string token37 = new string('T', 37), rootPassword = "root-json-password", shortSecret = "q7Z!";
            string base64 = new string('A', 16) + "/" + new string('B', 16) + "==";
            string rootJson = Json.Encode(ConfigBundle.D("root", ConfigBundle.D("password", rootPassword), "public", "kept"));
            clean = DiagnosticReport.Clean(token37 + "\npassword=fixture-password\n" + rootJson + "\n" + shortSecret +
                "\n" + base64 + "\n/usr/" + token37 + "/lan_pc_access.py", new[] { shortSecret });
            NoSecrets(clean, token37, "fixture-password", rootPassword, shortSecret, base64);
            Check(clean.Contains("/usr/<secret>/lan_pc_access.py") && clean.Contains("kept"), "redaction retains surrounding paths and JSON");
            string shortSegments = new string('A', 31) + "/" + new string('B', 31);
            Check(DiagnosticReport.Clean(shortSegments, null) == shortSegments, "31-character path segments retained");
            Check(DiagnosticReport.Clean("/usr/" + new string('A', 32) + "/file", null) == "/usr/<secret>/file", "32-character path segment hidden");
            foreach (string token in new[] { "Q2xpZW50U2VjcmV0/S2V5MTIzNDU2Nzg5MGFiY2Rl",
                "aGVsbG8gd29ybGQ/dGhpcyBpcyBhIHNlY3JldA/xyzABC",
                new string('a', 10) + "A1/" + new string('b', 20),
                "/" + new string('b', 20) + "/" + new string('a', 10) + "A1" })
                Check(DiagnosticReport.Clean("v " + token + " end", null) == "v <secret> end", "unpadded base64 hidden as a whole token");
            // Below 12 characters, or missing any character class, still looks like a name.
            foreach (string segment in new[] { new string('a', 9) + "A1", new string('a', 11) + "A",
                new string('a', 11) + "1", new string('A', 11) + "1" }) {
                string message = "v " + segment + "/" + new string('b', 20) + " end";
                Check(DiagnosticReport.Clean(message, null) == message, "name-like path segment retained");
            }
            foreach (string field in new[] { "key", "apiKey", "apikey", "private_key", "clientKey", "keyMaterial", "API_KEY" })
                NoSecrets(DiagnosticReport.Clean(field + "=field-credential", null), "field-credential");
            clean = DiagnosticReport.Clean("{\"apiKey\":\"escaped\\\"value\\\\tail\",\"public\":42}\nauthorization: Bearer auth-value\nvless://url-uuid@example.invalid:443", null);
            NoSecrets(clean, "escaped", "value", "tail", "auth-value", "url-uuid");
            Check(clean.Contains("\"public\":42"), "escaped credential retains next JSON field");
            clean = DiagnosticReport.Clean("key=[\"array-value\",{\"child\":\"child-value\"}]\npublic=ok", null);
            NoSecrets(clean, "array-value", "child-value");
            Check(clean.EndsWith("public=ok"), "structured credential retains next line");
            clean = DiagnosticReport.Clean("https://token:part-one;part-two@example.invalid/path?%61piKey=query-one;query-two&mode=auto", null);
            NoSecrets(clean, "part-one", "part-two", "query-one", "query-two");
            Check(clean.Contains("mode=auto"), "URL retains public query");
            string home = Path.Combine(Path.GetTempPath(), "ra-diagnostic-" + Guid.NewGuid().ToString("N"));
            string logs = Path.Combine(home, "logs"), state = Path.Combine(home, "state");
            try {
                Directory.CreateDirectory(logs); Directory.CreateDirectory(state);
                SecretVault.Set(home, "fixture-password", stored);
                // This is the same registration used for request values before creating a PasswordRelay.
                DiagnosticReport.RememberSecrets(home, new[] { requested, Json.Encode(ConfigBundle.D("password", nested)) });
                string missed = stored + " " + requested + " " + nested;
                var diag = ConfigBundle.D("id", "1234abcd", "type", "RuntimeError", "message", path + " " + longMessage + missed,
                    "cause", "KeyError: 'lan_pc_access.py' " + missed,
                    "where", new[] { "server_apply.py:1061:part " + missed }, "journal", false);
                var result = ConfigBundle.D("ok", true, "degraded", new[] { "happierWeb" }, "summary", missed,
                    "clientMode", "delegated", "sshExit", 0, "code", ConfigBundle.D("sha", "012345abcdef", "python", "3.13.1"),
                    "parts", new[] {
                        ConfigBundle.D("part", "agent", "state", "ready", "summary", "готово"),
                        ConfigBundle.D("part", "happierWeb", "state", "error", "summary", missed, "diag", diag),
                        ConfigBundle.D("part", "lan:share", "state", "ready", "summary", "готово") });
                string reportPath = Path.Combine(state, "server-apply.json");
                Json.Write(reportPath, result);
                string block = DiagnosticReport.FormatServerApply(File.ReadAllText(reportPath), "1.4.1.0", "1");
                string screen = DiagnosticReport.WriteWindowLog(logs, block, DiagnosticReport.KnownSecrets(home));
                string onDisk = File.ReadAllText(Path.Combine(logs, "config-window.log"));
                NoSecrets(screen, stored, requested, nested);
                NoSecrets(onDisk, stored, requested, nested);
                foreach (string expected in new[] { "тип=RuntimeError", "запись=1234abcd", "Программа: RemoteAgents 1.4.1.0", "сервер-код: sha=012345abcdef", "Секции: agent=ready, happierWeb=error, lan:share=ready", "Код выхода: 1; SSH 0", "журнал сервера недоступен" })
                    Check(onDisk.Contains(expected), "file retains " + expected);
                foreach (string expected in new[] { "KeyError: 'lan_pc_access.py'", path, longMessage, "server_apply.py:1061:part" })
                    Check(onDisk.Contains(expected), "window log retains diagnostic detail " + expected);
                Check(Regex.IsMatch(onDisk, @"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z "), "log includes calendar date");
                Check(File.ReadAllText(reportPath).Contains(stored), "fixture models a real server redaction miss");
                File.WriteAllLines(Path.Combine(logs, "launcher.log"), Enumerable.Range(0, 220).Select(i => "event-" + i.ToString("000")));
                string oldWizard = Path.Combine(logs, "wizard-old.out"), newWizard = Path.Combine(logs, "wizard-latest.out");
                File.WriteAllText(oldWizard, "OLD-WIZARD-MARKER"); File.SetLastWriteTimeUtc(oldWizard, DateTime.UtcNow.AddMinutes(-1));
                File.WriteAllText(newWizard, "LATEST-WIZARD-MARKER " + missed);
                string copied = DiagnosticReport.BuildCopyText(logs, state);
                NoSecrets(copied, stored, requested, nested);
                Check(copied.Contains("тип=RuntimeError") && copied.Contains("запись=1234abcd") && copied.Contains("Секции:"), "copy preserves actionable diagnostics");
                foreach (string expected in new[] { "KeyError: 'lan_pc_access.py'", path, longMessage, "server_apply.py:1061:part", "sha=012345abcdef", "lan:share" })
                    Check(copied.Contains(expected), "copy retains diagnostic detail " + expected);
                Check(copied.Contains("event-219") && !copied.Contains("event-019") && copied.Contains("event-020"), "copy uses only the last 200 launcher lines");
                Check(copied.Contains("wizard-latest.out") && copied.Contains("LATEST-WIZARD-MARKER") && !copied.Contains("OLD-WIZARD-MARKER"), "copy includes only the newest wizard output");
                Check(copied.Contains("UTC:") && copied.Contains("RemoteAgents ") && copied.Contains("Windows:"), "copy includes version, OS and time");
                Console.WriteLine(DiagnosticReport.Clean(block, DiagnosticReport.KnownSecrets(home)));

                // Rotation and I/O failures use the exact writer called by ConfigWindow.Log.
                File.WriteAllText(Path.Combine(logs, "config-window.log"), new string('x', 2097153));
                DiagnosticReport.WriteWindowLog(logs, "after rotation " + missed, DiagnosticReport.KnownSecrets(home));
                Check(File.Exists(Path.Combine(logs, "config-window.log.1")), "oversized log rotated");
                Check(new FileInfo(Path.Combine(logs, "config-window.log")).Length < 1024, "new log is small");
                NoSecrets(File.ReadAllText(Path.Combine(logs, "config-window.log")), stored, requested, nested);
                File.WriteAllText(Path.Combine(logs, "config-window.log"), "OLD-LARGE-PREFIX\n" + new string('x', 210 * 1024) + "\nWINDOW-TAIL\n");
                File.WriteAllText(reportPath, "OLD-STATE-PREFIX\n" + new string('y', 60 * 1024) + "\nSTATE-TAIL\n");
                File.WriteAllText(newWizard, "OLD-WIZARD-PREFIX\n" + new string('z', 30 * 1024) + "\nWIZARD-TAIL\n");
                copied = DiagnosticReport.BuildCopyText(logs, state);
                Check(!copied.Contains("OLD-LARGE-PREFIX") && !copied.Contains("OLD-STATE-PREFIX") && !copied.Contains("OLD-WIZARD-PREFIX"), "file byte limits exclude old data");
                Check(copied.Contains("WINDOW-TAIL") && copied.Contains("STATE-TAIL") && copied.Contains("WIZARD-TAIL") && copied.Length < 260 * 1024, "bounded tails retained");
                string unusable = Path.Combine(home, "not-a-directory"); File.WriteAllText(unusable, "fixture");
                NoSecrets(DiagnosticReport.WriteWindowLog(unusable, missed, DiagnosticReport.KnownSecrets(home)), stored, requested, nested);
                Check(DiagnosticReport.BuildCopyText(unusable, Path.Combine(home, "missing")).Contains("нет данных"), "missing/unreadable files do not break copy");
                // A vault that cannot be read must not prevent logging; request values remain protected.
                File.WriteAllText(SecretVault.VaultPath(home), "invalid fixture");
                NoSecrets(DiagnosticReport.Clean(missed, DiagnosticReport.KnownSecrets(home)), stored, requested, nested);
                Check(!DiagnosticReport.KnownSecrets(Path.Combine(home, "empty")).Any(), "unavailable vault without prior values returns empty");

                string missing = DiagnosticReport.FormatServerApply(null, "1.4.1.0", "неизвестно", "fixture transport failure");
                Check(missing.Contains("server-apply.json нет") && missing.Contains("fixture transport failure") && missing.Contains("Секции:"), "missing state keeps exception and sections line");
                string main = DiagnosticReport.FormatServerApply(Json.Encode(ConfigBundle.D("ok", false, "error", "E-TEXT", "diag", diag)), "1.4.1.0", "1");
                Check(main.Contains("E-TEXT") && main.Contains("запись=1234abcd"), "top-level diagnostic rendered");
                string ready = DiagnosticReport.FormatServerApply(Json.Encode(ConfigBundle.D("ok", true, "parts", new[] { ConfigBundle.D("part", "agent", "state", "ready", "summary", "готово") })), "1.4.1.0", "0");
                Check(ready.Contains("Секции: agent=ready") && !ready.Contains("сообщение:"), "success always lists sections without error details");
            } finally { if (Directory.Exists(home)) Directory.Delete(home, true); }
            Console.WriteLine("PASS: DiagnosticReport " + count + " checks (redaction miss, copy, rotation, failures)");
        }
        public static int Main(string[] args)
        {
            int code = ConfigBundleTests.Main(args);
            if (code == 0 && args.Length == 0) Run();
            return code;
        }
    }
}
