using System;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Text.RegularExpressions;

namespace RemoteAgents.Launcher
{
    // Portable regression: inspect the actual Windows call sites, execute the shared journal path.
    // No NotifyIcon, asynchronous boot loop, real clock, network or Windows is needed.
    internal static class TrayNotificationTests
    {
        static void Check(bool ok, string name) { if (!ok) throw new Exception("Tray notifications: " + name); }
        static string Section(string source, string start, string end)
        {
            int first = source.IndexOf(start, StringComparison.Ordinal);
            int last = first < 0 ? -1 : source.IndexOf(end, first + start.Length, StringComparison.Ordinal);
            if (last < 0) throw new Exception("Tray source section missing: " + start);
            return source.Substring(first, last - first);
        }
        static bool SilentNetworkPaths(string source)
        {
            return !Section(source, "void Tick()", "bool Step(").Contains("ShowBalloonTip") &&
                !Section(source, "async void WatchHealth()", "void ReloadSettings()").Contains("ShowBalloonTip");
        }
        static bool ActionBalloonsPreserved(string source, string update)
        {
            return ActionBalloons.All(source.Contains) &&
                Regex.Matches(source, @"\.ShowBalloonTip\s*\(").Count == ActionBalloons.Length &&
                update.Contains(UpdateBalloon) && Regex.Matches(update, @"\.ShowBalloonTip\s*\(").Count == 1;
        }

        internal static void Run([CallerFilePath] string caller = "")
        {
            string launcher = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(caller), ".."));
            string source = File.ReadAllText(Path.Combine(launcher, "TrayContext.cs"));
            string update = File.ReadAllText(Path.Combine(launcher, "TrayContext.Update.cs"));
            Check(SilentNetworkPaths(source), "loss/recovery/conflict in Tick and unconfirmed boot in WatchHealth are silent");
            Check(ActionBalloonsPreserved(source, update), "installation, account, disk, action errors, update and tray hint balloons remain");
            string tick = Section(source, "void Tick()", "bool Step(");
            string health = Section(source, "async void WatchHealth()", "void ReloadSettings()");
            Check(tick.Contains("if (!closing && icon.Icon != shown)") &&
                tick.Contains("string previous = icon.Icon == green ? \"ok\" : icon.Icon == red ? \"error\" : \"warn\";") &&
                tick.Contains("icon.Icon = shown;") &&
                tick.Contains("TrayStatusLog.Write(log, previous, shown == green ? \"ok\" : shown == red ? \"error\" : \"warn\");") &&
                Regex.Matches(tick, @"TrayStatusLog\.Write\(").Count == 1,
                "Tick journals the actual previous/final icon colours through the tested writer once");
            Check(health.Contains("if(!closing)log.Write(\"setup.health.unconfirmed\");"), "unconfirmed boot remains in journal");

            // The checks must reject the original regressions, without modifying the source tree.
            foreach (string message in new[] { "Связь потеряна", "Связь восстановлена", "Конфликт VPN" }) {
                string injected = source;
                int body = injected.IndexOf('{', injected.IndexOf("void Tick()", StringComparison.Ordinal));
                injected = injected.Insert(body + 1, "icon.ShowBalloonTip(8000, Product.Name, \"" + message + "\", ToolTipIcon.Warning);");
                Check(!SilentNetworkPaths(injected), "restored Tick balloon rejected: " + message);
            }
            Check(!SilentNetworkPaths(source.Replace("if(!closing)log.Write(\"setup.health.unconfirmed\");",
                "if(!closing)icon.ShowBalloonTip(10000,Product.Name,\"Связь не подтверждена\",ToolTipIcon.Warning);")),
                "restored WatchHealth balloon rejected");
            foreach (string balloon in ActionBalloons)
                Check(!ActionBalloonsPreserved(source.Replace(balloon, ""), update), "removing an action balloon is rejected");
            Check(!ActionBalloonsPreserved(source, update.Replace(UpdateBalloon, "")), "removing the update balloon is rejected");
            JournalTransitions();
            Console.WriteLine("PASS: silent Tick/WatchHealth; 12 action balloons preserved; status.changed transitions without duplicates");
        }

        static void JournalTransitions()
        {
            string home = Path.Combine(Path.GetTempPath(), "tray-notifications-" + Guid.NewGuid().ToString("N"));
            var oldClock = RaLog.Clock;
            var oldLimits = RaLog.Limits;
            RaLog.Clock = () => new DateTimeOffset(2026, 11, 21, 12, 0, 0, TimeSpan.Zero);
            RaLog.Limits = new LogLimits();
            try {
                var journal = new Journal(home);
                string path = Path.Combine(home, "logs", "launcher.log");
                string previous = "warn";
                var expected = new System.Collections.Generic.List<string>();
                // Startup, healthy, loss, recovery, VPN conflict, failed, recovered; each repeated.
                foreach (string current in new[] { "warn", "ok", "ok", "warn", "warn", "ok", "ok", "warn", "warn", "error", "error", "ok", "ok" }) {
                    if (previous != current) expected.Add("from=" + previous + " to=" + current);
                    TrayStatusLog.Write(journal, previous, current);
                    string[] lines = File.Exists(path) ? File.ReadAllLines(path) : new string[0];
                    Check(lines.Length == expected.Count, "one entry per transition, none for repeated " + current);
                    for (int i = 0; i < lines.Length; i++)
                        Check(lines[i].Contains("status.changed") && lines[i].Contains(expected[i]), "ordered from/to journal fields");
                    previous = current;
                }
            } finally {
                RaLog.Clock = oldClock; RaLog.Limits = oldLimits;
                if (Directory.Exists(home)) Directory.Delete(home, true);
            }
        }

        // Existing user-action notifications are an explicit allowlist, not a blanket balloon ban.
        static readonly string[] ActionBalloons = {
            "icon.ShowBalloonTip(5000, Product.Name, \"Happier: \" + Json.Text(account, \"summary\", \"аккаунт подключён\"), ToolTipIcon.Info);",
            "icon.ShowBalloonTip(10000, Product.Name, \"Happier: аккаунт не подключён. Откройте «Настройки» → Happier.\", ToolTipIcon.Warning);",
            "icon.ShowBalloonTip(5000, Product.Name, \"Готово: установка на сервере завершена\", ToolTipIcon.Info);",
            "icon.ShowBalloonTip(10000, Product.Name, failed[0].Title + \": \" + ServerOperations.Line(failed[0]) + \". «Повторить» — в «Настройки» → «Установка».\", ToolTipIcon.Warning);",
            "icon.ShowBalloonTip(8000, Product.Name, \"Значок в трее: клик открывает Happier, если адрес задан. Окно программы: пункт «Настройки».\", ToolTipIcon.Info);",
            "icon.ShowBalloonTip(4000, \"Диск\", message, ok ? ToolTipIcon.Info : ToolTipIcon.Warning);",
            "icon.ShowBalloonTip(10000, Product.Name, bridgeError, ToolTipIcon.Warning);",
            "icon.ShowBalloonTip(4000, \"Диск\", \"Идёт обновление программы; повторите действие после перезапуска\", ToolTipIcon.Info);",
            "icon.ShowBalloonTip(4000, \"Диск\", \"Диск ещё не установлен или отключён\", ToolTipIcon.Warning);",
            "icon.ShowBalloonTip(5000, Product.Name, \"Диск: \" + last.Summary, ToolTipIcon.Info);",
            "icon.ShowBalloonTip(10000, Product.Name, \"Диск не подключён: \" + last.Summary + \". Повторите: «Настройки» → «Дополнительно» → «Редактор конфига» → «Применить».\", ToolTipIcon.Warning);",
        };
        const string UpdateBalloon = "icon.ShowBalloonTip(8000, Product.Name, message, reason.Length == 0 ? ToolTipIcon.Info : ToolTipIcon.Warning);";
    }
}
