using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace RemoteAgents.Launcher
{
    internal static class TrayExtrasTests
    {
        static int count;
        static void Check(bool ok, string name) { if (!ok) throw new Exception("Tray extras: " + name); count++; }
        static Dictionary<string, object> Data(string json) { return Json.Map(Json.Parse(json)); }
        static Dictionary<string, object> Health(double diskFree, double memoryFree)
        {
            return Data(Json.Encode(new { ok = true, disk = new { totalBytes = 100000, freeBytes = diskFree, usedBytes = 100000 - diskFree },
                memory = new { totalBytes = 100000, availableBytes = memoryFree, usedBytes = 100000 - memoryFree },
                load = new { one = 1.2, five = 0.8, fifteen = 0.5, cores = 4 }, uptimeSec = 90061 }));
        }
        internal static void Run()
        {
            var empty = Data("{}"); var transport = Data("{\r\n\"ok\":true,\"active\":\"vless-relay-fixture\",\"kbps\":96.8,\"candidates\":[{\"tag\":\"vless-relay-fixture\",\"state\":\"ok\",\"kbps\":96.8},{\"tag\":\"vless-direct\",\"state\":\"fail\"}]\r\n}");
            var health = Health(40000, 50000); var menu = TrayMenuModel.Build(empty, empty, transport, health);
            Check(string.Join(",", menu.Select(x => x.Id)) == "open,folders,happier,separator,connection,server,separator,exit", "exact menu order");
            Check(menu[0].Text == "Открыть" && menu[1].Text == "Папки синхронизации" && menu[2].Text == "Открыть Happier" && menu[7].Text == "Выход", "human labels");
            Check(menu[0].Enabled && menu[1].Enabled && menu[7].Enabled, "window and exit remain accessible");
            Check(!menu[2].Enabled && menu[2].Hint.Contains("happier.webappUrl"), "missing Happier URL disabled with explanation");
            Check(!menu[4].Enabled && !menu[5].Enabled, "information rows disabled");
            Check(menu[4].Text.Contains("VLESS через fixture") && menu[4].Text.Contains("КБ/с"), "friendly active route and speed");
            Check(menu[5].Text.Contains("диск") && menu[5].Text.Contains("память") && menu[5].Text.Contains("нагрузка"), "server metrics in menu");
            foreach (string url in new[] { "https://first.example.invalid/path", "https://second.example.invalid:8443/", "http://local.example.invalid/" }) {
                var config = Data(Json.Encode(new { happier = new { webappUrl = url } }));
                Check(TrayMenuModel.HappierUrl(config, empty) == url, "URL comes from each supplied config");
                Check(TrayMenuModel.Build(config, empty, transport, health)[2].Enabled, "configured URL enables item");
            }
            var account = Data("{\"webappUrl\":\"https://account.example.invalid/\"}");
            Check(TrayMenuModel.HappierUrl(empty, account) == "https://account.example.invalid/", "fallback to account state");
            Check(TrayMenuModel.HappierUrl(Data("{\"happier\":{\"webappUrl\":\"https://config.example.invalid/\"}}"), account) == "https://config.example.invalid/", "config takes priority");
            foreach (string url in new[] { "", "not a url", "file:///tmp/app", "javascript:alert(1)", "https://user:pass@example.invalid" })
                Check(!TrayMenuModel.Build(Data(Json.Encode(new { happier = new { webappUrl = url } })), empty, transport, health)[2].Enabled, "invalid URL cannot launch: " + url);
            Check(TrayMenuModel.Connection(empty).Contains("ожидается"), "missing transport unknown");
            transport["ok"] = false;
            Check(!TrayMenuModel.Connection(transport).Contains("КБ/с") && TrayMenuModel.Connection(transport).Contains("не подтверждена"), "failed transport does not claim a working path/speed");
            Check(!TrayMenuModel.CandidateLine(StatusView.Candidates(transport)[0], transport).Contains("используется"), "failed transport has no confirmed active path");
            transport["ok"] = true;
            Check(TrayMenuModel.CandidateLine(StatusView.Candidates(transport)[0], transport).Contains("работает · используется"), "active candidate marked with speed");
            Check(TrayMenuModel.CandidateLine(StatusView.Candidates(transport)[1], transport).Contains("не работает"), "failed candidate translated");
            Check(TrayMenuModel.CandidateLine(Data("{\"tag\":\"vless-direct\",\"enabled\":false,\"state\":\"ok\"}"), transport).Contains("отключён"), "disabled candidate visible");
            Check(TrayMenuModel.CandidateLine(Data("{\"tag\":\"vless-direct\",\"state\":\"checking\"}"), transport).Contains("проверяется"), "checking candidate translated");
            Check(TrayMenuModel.CandidateLine(Data("{\"tag\":\"vless-direct\"}"), transport).Contains("не проверен"), "unknown candidate translated");
            foreach (var state in new[] { new[] { "slow", "медленный" }, new[] { "frozen", "завис" }, new[] { "remembered", "ранее работал" }, new[] { "pending", "проверяется" }, new[] { "disabled", "отключён" } })
                Check(TrayMenuModel.CandidateLine(Data(Json.Encode(new { tag = "vless-direct", state = state[0], kbps = 42 })), transport).Contains(state[1]), "real daemon state: " + state[0]);
            var selection = new PathSelection();
            var pinned = Data("{\"mode\":\"pinned\",\"pinnedTag\":\"vless-direct\"}");
            Check(selection.Update(pinned) == "vless-direct", "initial choice follows pinned mode");
            Check(selection.Update(empty) == "vless-direct", "temporarily missing status preserves chosen mode");
            selection.Choose(""); pinned["kbps"] = 20;
            Check(selection.Update(pinned) == "", "unsubmitted auto choice survives speed refresh");
            pinned["pinnedTag"] = "vless-relay-fixture";
            Check(selection.Update(pinned) == "vless-relay-fixture", "choice follows external path change");
            Check(selection.Update(Data("{\"mode\":\"auto\",\"active\":\"vless-direct\"}")) == "", "auto mode is distinct from active path");
            selection.Choose("vless-direct");
            Check(selection.Update(Data("{\"mode\":\"auto\",\"active\":\"vless-relay-fixture\"}")) == "vless-direct", "unsubmitted choice survives auto failover");
            foreach (var percentages in new[] { new[] { 9.99, 50.0 }, new[] { 50.0, 9.99 }, new[] { 0.0, 0.0 }, new[] { 10.0, 10.0 }, new[] { 100.0, 100.0 } }) {
                var h = Health(percentages[0] * 1000, percentages[1] * 1000); bool warning = percentages[0] < 10 || percentages[1] < 10;
                Check(ServerHealthView.Warning(h) == warning, "warning boundary " + string.Join("/", percentages));
                Check(ServerHealthView.Summary(h).StartsWith("⚠") == warning, "warning in menu/window");
                Check(TrayMenuModel.Tooltip(transport, h).Contains("⚠") == warning, "warning in icon tooltip");
            }
            Check(!ServerHealthView.Warning(empty) && !ServerHealthView.Known(empty), "missing counters do not look healthy or low");
            Check(!ServerHealthView.Known(Health(-1, 1000)) && !ServerHealthView.Known(Health(100001, 1000)), "invalid counters rejected");
            health["ok"] = false;
            Check(!ServerHealthView.Known(health) && !ServerHealthView.Summary(health).Contains("ГиБ"), "error hides old success metrics");
            health = Health(40000, 50000);
            Check(ServerHealthView.Detail(health).Contains("1 / 5 / 15") && ServerHealthView.Detail(health).Contains("ядер: 4") && ServerHealthView.Detail(health).Contains("1 д 1 ч 1 мин"), "details include load/core/uptime");
            foreach (var h in new[] { health, empty, Health(0, 0) }) {
                string tip = TrayMenuModel.Tooltip(transport, h);
                Check(tip.Length <= 63 && tip.Contains("диск") || tip.Length <= 63 && tip.Contains("сервер"), "bounded tooltip includes server status");
            }
            Check(TrayMenuModel.Short(new string('x', 60) + "😀abcdef", 63).Length <= 63 && !char.IsHighSurrogate(TrayMenuModel.Short(new string('x', 61) + "😀abcdef", 63)[61]), "tooltip cut preserves Unicode");
            var now = DateTime.UtcNow; var schedule = new ServerHealthSchedule();
            Check(!schedule.Due(now, false, false), "no poll without confirmed route");
            Check(!schedule.Due(now, true, true), "busy poll deferred");
            Check(schedule.Due(now, true, false), "first read due immediately"); schedule.Started(now);
            Check(!schedule.Due(now.AddSeconds(299), true, false), "no poll before five minutes");
            Check(schedule.Due(now.AddMinutes(5), true, false), "poll every five minutes including errors");
            Check(WizardStep.Timeout("ServerHealth") == 10000, "outer wizard budget ten seconds");
            string dir = Path.Combine(Path.GetTempPath(), "health-tests-" + Guid.NewGuid().ToString("N"));
            try {
                Directory.CreateDirectory(Path.Combine(dir, "state")); string path = Path.Combine(dir, "state/server-health.json");
                Check(!ServerHealthView.Known(ServerHealthView.Read(dir, now)), "missing health file");
                health["updatedUtc"] = now.ToString("o"); Files.Atomic(path, Json.Encode(health).Replace("{", "{\r\n"));
                Check(ServerHealthView.Known(ServerHealthView.Read(dir, now)), "CRLF state file is read");
                Check(!ServerHealthView.Known(ServerHealthView.Read(dir, now.AddSeconds(361))), "stale health not shown as current");
                Check(!ServerHealthView.Known(ServerHealthView.Read(dir, now.AddSeconds(-10))), "future stamp rejected");
                Files.Atomic(path, "BROKEN"); Check(!ServerHealthView.Known(ServerHealthView.Read(dir, now)), "corrupt state safe");
            } finally { Directory.Delete(dir, true); }
            Console.WriteLine("PASS: " + count + " tray menu/server health/path/schedule checks");
        }
    }
}
