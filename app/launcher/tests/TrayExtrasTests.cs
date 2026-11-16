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
        static void DiskRest()
        {
            var folder = Data("{\"id\":\"disk a/б\",\"devices\":[{\"deviceID\":\"PEER\"}]}"); var idle = Data("{\"state\":\"idle\",\"globalBytes\":2048,\"needBytes\":0,\"needTotalItems\":0}");
            var folders = new[] { folder }; var states = new[] { idle };
            var complete = new[] { Data("{\"completion\":100,\"needItems\":0,\"needBytes\":0,\"needDeletes\":0,\"remoteState\":\"valid\"}") };
            Check(!DiskTraySession.Summary(folders, states, true).Contains("синхронизирован"), "missing server completion cannot be green");
            Check(DiskTraySession.Summary(folders, states, true, complete) == "Диск: синхронизирован", "local idle and confirmed server completion means synchronized");
            Check(DiskTraySession.Summary(folders, states, false).Contains("не подключён"), "idle without server never claims synchronization");
            Check(DiskTraySession.Summary(new Dictionary<string, object>[0], states, true).Contains("нет выбранных"), "empty selection is explicit");
            folder["paused"] = true;
            Check(DiskTraySession.Summary(folders, states, true).Contains("паузе"), "paused folder cannot look synchronized"); folder.Remove("paused");
            foreach (string key in new[] { "errors", "pullErrors" }) {
                idle[key] = 1;
                Check(DiskTraySession.Summary(folders, states, true).Contains("ошибка"), "folder error " + key); idle.Remove(key);
            }
            // Ошибка одной папки не делает ошибкой весь Диск; папка, снятая сервером, не ошибка.
            var a = Data("{\"id\":\"a\",\"label\":\"Альфа\",\"devices\":[{\"deviceID\":\"PEER\"}]}"); var b = Data("{\"id\":\"b\",\"devices\":[{\"deviceID\":\"PEER\"}]}");
            var broken = Data("{\"state\":\"error\",\"error\":\"folder path missing\",\"globalBytes\":2048,\"needBytes\":0,\"needTotalItems\":0}");
            var valid = Data("{\"completion\":100,\"needItems\":0,\"needBytes\":0,\"needDeletes\":0,\"remoteState\":\"valid\"}"); var notSharing = Data("{\"completion\":100,\"needItems\":0,\"needBytes\":0,\"needDeletes\":0,\"remoteState\":\"notSharing\"}");
            string one = DiskTraySession.Summary(new[] { a, b }, new[] { broken, idle }, true, new[] { valid, valid });
            Check(one == "Диск работает; ошибка в папке Альфа: folder path missing", "one folder in error: the Disk works, the folder is named with the reason (" + one + ")");
            Check(!one.Contains("ошибка синхронизации"), "an error of one folder is never the error of the Disk");
            Check(DiskTraySession.Summary(new[] { a, b }, new[] { broken, broken }, true, new[] { valid, valid }) == "Диск работает; ошибки в 2 папках: Альфа, b", "several folders in error are listed shortly");
            Check(DiskTraySession.Summary(new[] { a, b }, new[] { Data("{\"pullErrors\":3}"), idle }, true, new[] { valid, valid }).Contains("не удалось получить файлов: 3"), "pull errors give a reason");
            Check(DiskTraySession.Summary(new[] { a, b }, new[] { broken, idle }, false, new[] { valid, valid }) == "Диск: сервер не подключён", "no connection is still a problem of the whole Disk, not of a folder");
            string gone = DiskTraySession.Summary(new[] { a, b }, new[] { idle, idle }, true, new[] { valid, notSharing }, new[] { "a", "b" });
            Check(gone == "Диск: синхронизирован · удалена на сервере: b", "a folder the server stopped sharing is not an error; the rest is counted as before (" + gone + ")");
            Check(DiskTraySession.Summary(new[] { a, b }, new[] { idle, idle }, true, new[] { valid, notSharing }, new[] { "a" }).Contains("состояние уточняется") &&
                !DiskTraySession.Summary(new[] { a, b }, new[] { idle, idle }, true, new[] { valid, notSharing }, new[] { "a" }).Contains("удален"), "a new folder the server has not accepted yet is waiting, not removed");
            Check(DiskTraySession.Summary(new[] { a, b }, new[] { idle, idle }, true, new[] { valid, notSharing }).Contains("состояние уточняется"), "without the memory nothing is called removed");
            Check(DiskTraySession.Summary(new[] { a, b }, new[] { idle, idle }, false, new[] { valid, notSharing }, new[] { "a", "b" }) == "Диск: сервер не подключён", "without a connection nothing is removed");
            Check(DiskTraySession.Summary(new[] { b }, new[] { idle }, true, new[] { notSharing }, new[] { "b" }) == "Диск: папки удалены на сервере, локальные копии сохранены", "all folders removed on the server");
            string both = DiskTraySession.Summary(new[] { a, b }, new[] { broken, idle }, true, new[] { valid, notSharing }, new[] { "a", "b" });
            Check(both == "Диск работает; ошибка в папке Альфа: folder path missing · удалена на сервере: b", "an error and a removal are told together (" + both + ")");
            Check(DiskTraySession.Summary(folders, new[] { Data("{\"state\":\"scanning\"}") }, true).Contains("проверка"), "scan is not success");
            Check(DiskTraySession.Summary(folders, new[] { Data("{\"state\":\"syncing\",\"globalBytes\":2048,\"needBytes\":1024}") }, true).Contains("50%"), "sync percentage");
            Check(DiskTraySession.Summary(folders, new[] { Data("{\"state\":\"idle\",\"needTotalItems\":1}") }, true).Contains("синхронизация"), "zero byte deletions still pending");
            Check(!DiskTraySession.Summary(folders, new[] { Data("{}") }, true).Contains("синхронизирован"), "missing state is unknown");
            Check(DiskTraySession.Rates(1024, 2048, 3072, 3072, 2) == " · ↓1 ↑0.5 КБ/с", "speed uses counter deltas and elapsed time");
            Check(DiskTraySession.Rates(100, 100, 10, 10, 1) == "" && DiskTraySession.Rates(0, 0, 100, 100, 0) == "", "restart and first sample have no invented speed");
            foreach (string value in new[] { "example.invalid:8384", "0.0.0.0:8384", "user:pass@127.0.0.1:8384", "127.0.0.1:8384/path", "127.0.0.1:8384/?x=1" }) {
                bool rejected = false; try { DiskTraySession.LocalAddress(value); } catch (InvalidDataException) { rejected = true; }
                Check(rejected, "nonlocal or unsafe REST rejected");
            }
            // Real HTTP transport: UTF-8/CRLF config, credentials in header only, cursor,
            // status refresh on events, no repeated db/status on an empty long-poll.
            string dir = Path.Combine(Path.GetTempPath(), "tray-rest-" + Guid.NewGuid().ToString("N"));
            var socket = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0); socket.Start();
            int port = ((System.Net.IPEndPoint)socket.LocalEndpoint).Port; socket.Stop();
            using (var listener = new System.Net.HttpListener()) {
                listener.Prefixes.Add("http://127.0.0.1:" + port + "/"); listener.Start();
                var requests = new List<string>(); int poll = 0, statusCalls = 0; bool headerOk = true, redirect = false, restarted = false;
                var server = System.Threading.Tasks.Task.Run(() => {
                    try {
                        while (listener.IsListening) {
                            var context = listener.GetContext(); string url = context.Request.RawUrl; requests.Add(url);
                            headerOk &= context.Request.Headers["X-API-Key"] == "fixture" && !url.Contains("fixture");
                            string json;
                            if (redirect) { context.Response.StatusCode = 302; context.Response.RedirectLocation = "http://127.0.0.1:" + port + "/redirected"; json = "{}"; }
                            else if (url == "/rest/system/status") json = Json.Encode(new { myID = "LOCAL", startTime = restarted ? "2026-01-01T00:00:10Z" : "2026-01-01T00:00:00Z", uptime = 1 });
                            else if (url.StartsWith("/rest/events?")) { poll++; json = poll == 2 ? "[]" : "[{\"id\":" + (poll * 10) + ",\"type\":\"FolderSummary\"}]"; }
                            else if (url == "/rest/system/connections") json = "{\"connections\":{\"PEER\":{\"connected\":true}},\"total\":{\"inBytesTotal\":" + poll * 1024 + ",\"outBytesTotal\":0}}";
                            else if (url == "/rest/config/folders") json = Json.Encode(new[] { folder });
                            else if (url.StartsWith("/rest/db/completion?folder=")) json = Json.Encode(complete[0]);
                            else if (url.StartsWith("/rest/db/status?folder=")) { statusCalls++; json = poll == 1 ? "{\"state\":\"syncing\",\"globalBytes\":2048,\"needBytes\":1024}" : Json.Encode(idle); }
                            else throw new Exception("Unexpected local REST request: " + url);
                            byte[] bytes = System.Text.Encoding.UTF8.GetBytes(json); context.Response.ContentType = "application/json";
                            context.Response.OutputStream.Write(bytes, 0, bytes.Length); context.Response.Close();
                        }
                    } catch (System.Net.HttpListenerException) { } catch (ObjectDisposedException) { }
                });
                try {
                    Directory.CreateDirectory(Path.Combine(dir, "state"));
                    Files.Atomic(Path.Combine(dir, "state", "config.xml"), "<configuration>\r\n<gui><address>127.0.0.1:" + port + "</address><apikey>fixture</apikey></gui>\r\n</configuration>");
                    Files.Atomic(Path.Combine(dir, "server.txt"), "PEER\r\n");
                    var client = new DiskTraySession(dir);
                    Check(client.Read(System.Threading.CancellationToken.None).Contains("50%"), "HTTP first snapshot");
                    string second = client.Read(System.Threading.CancellationToken.None);
                    Check(second.Contains("50%") && second.Contains("КБ/с") && statusCalls == 1, "empty events preserve state and refresh speed only");
                    Check(client.Read(System.Threading.CancellationToken.None).Contains("синхронизирован") && statusCalls == 2, "event refreshes folder state");
                    Check(requests.Count(r => r.Contains("since=10&timeout=2")) == 2, "event cursor advances and waits locally");
                    Check(requests.Any(r => r.Contains("disk%20a%2F%D0%B1")) && headerOk, "encoded folder ID and private header");
                    restarted = true;
                    Check(client.Read(System.Threading.CancellationToken.None).Contains("синхронизирован") && statusCalls == 3 &&
                        requests.Count(r => r.Contains("since=0&timeout=0")) == 2, "engine restart resets event cursor and refreshes folder state");
                    redirect = true; bool rejected = false;
                    try { client.Read(System.Threading.CancellationToken.None); } catch (Exception) { rejected = true; }
                    Check(rejected && !requests.Any(r => r.Contains("redirected")), "redirect never forwards API key");
                } finally { listener.Stop(); server.GetAwaiter().GetResult(); Directory.Delete(dir, true); }
            }
        }
        internal static void Run()
        {
            var empty = Data("{}"); var transport = Data("{\r\n\"ok\":true,\"active\":\"vless-relay-fixture\",\"kbps\":96.8,\"candidates\":[{\"tag\":\"vless-relay-fixture\",\"state\":\"ok\",\"kbps\":96.8},{\"tag\":\"vless-direct\",\"state\":\"fail\"}]\r\n}");
            var health = Health(40000, 50000); var menu = TrayMenuModel.Build(empty, empty, transport, health);
            // Application actions, separate synchronization window, and local REST summary.
            Check(string.Join(",", menu.Select(x => x.Id)) == "open,settings,disk,synchronization,diskStatus,separator,connection,server,separator,exit", "exact menu order");
            Check(menu[0].Text == "Открыть" && menu[1].Text == "Настройки" && menu[2].Text == "Диск" && menu[9].Text == "Выход", "human labels");
            Check(menu[1].Enabled && menu[2].Enabled && menu[9].Enabled, "settings, Disk and exit are always accessible");
            // Detailed folder actions stay in the synchronization window.
            string labels = string.Join("|", menu.Select(x => x.Text));
            Check(!labels.Contains("Папки") && !labels.Contains("Ход синхронизации") && !labels.Contains("⚠") && !menu.Any(x => x.Id == "folders" || x.Id == "progress"), "no folder state rows in the menu");
            var configured = Data("{\r\n\"profile\":{\"server\":{\"address\":\"203.0.113.10\"},\"disk\":{\"folders\":[]}}\r\n}");
            Check(string.Join(",", TrayMenuModel.Build(configured, empty, transport, health).Select(x => x.Id + ":" + x.Text)) == string.Join(",", menu.Select(x => x.Id + ":" + x.Text)), "folder choice in the profile never changes the menu");
            Check(!menu[0].Enabled && menu[0].Hint.Contains("happier.webappUrl"), "missing Happier URL disables «Открыть» with explanation");
            Check(menu[3].Text == "Синхронизация (Syncthing)…" && menu[3].Enabled, "independent synchronization window entry");
            Check(!menu[4].Enabled && menu[4].Text == "Диск: ожидается проверка", "honest unknown Disk state");
            Check(TrayMenuModel.Build(empty, empty, transport, health, "Диск: синхронизирован")[4].Text == "Диск: синхронизирован", "REST state reaches the menu");
            DiskRest();
            // «Диск» opens the root the installed Disk really uses; the configured disk.base counts until the Disk section applied it.
            var configuredBase = Data("{\"disk\":{\"base\":\"D:\\\\Work\\\\Disk\"}}");
            Check(ConfigProfile.DiskRoot(configuredBase, "C:\\Users\\u\\Disk") == "C:\\Users\\u\\Disk", "installed Disk root wins over the config");
            Check(ConfigProfile.DiskRoot(configuredBase, "") == "D:\\Work\\Disk", "configured root before the first install");
            Check(ConfigProfile.DiskRoot(empty, "") == ConfigProfile.DefaultDiskBase() && ConfigProfile.DefaultDiskBase().EndsWith("Disk"), "default root is the user's Disk folder");
            Check(!menu[6].Enabled && !menu[7].Enabled, "information rows disabled");
            Check(menu[6].Text.Contains("VLESS через fixture") && menu[6].Text.Contains("КБ/с"), "friendly active route and speed");
            Check(menu[7].Text.Contains("диск") && menu[7].Text.Contains("память") && menu[7].Text.Contains("нагрузка"), "server metrics in menu");
            foreach (string url in new[] { "https://first.example.invalid/path", "https://second.example.invalid:8443/", "http://local.example.invalid/" }) {
                var config = Data(Json.Encode(new { happier = new { webappUrl = url } }));
                Check(TrayMenuModel.HappierUrl(config, empty).GetAwaiter().GetResult() == url, "URL comes from each supplied config");
                var withUrl = TrayMenuModel.Build(config, empty, transport, health);
                Check(withUrl[0].Enabled && withUrl[0].Text == "Открыть" && withUrl[0].Hint == "Открыть веб-приложение Happier", "configured URL enables «Открыть» (Happier)");
            }
            Check(TrayMenuModel.LeftClickAction(empty, empty) == "settings", "left click without URL opens the program window");
            Check(TrayMenuModel.AcceptLeftClick(0, 501, 500), "NotifyIcon single click has Clicks=0");
            Check(!TrayMenuModel.AcceptLeftClick(0, 200, 500), "NotifyIcon repeat suppressed within double click interval");
            Check(TrayMenuModel.AcceptLeftClick(1, 501, 500), "first or later single click accepted");
            Check(!TrayMenuModel.AcceptLeftClick(1, 200, 500) && !TrayMenuModel.AcceptLeftClick(2, 200, 500), "double click cannot launch second tab");
            Check(!TrayMenuModel.AcceptLeftClick(1, 500, 500), "double click boundary suppressed");
            var account = Data("{\"webappUrl\":\"https://account.example.invalid/\"}");
            Check(TrayMenuModel.LeftClickAction(empty, account) == "happier", "left click follows account URL");
            Check(TrayMenuModel.LeftClickAction(Data("{\"happier\":{\"webappUrl\":\"file:///tmp/app\"}}"), account) == "settings", "invalid configured URL falls back to window");
            Check(TrayMenuModel.HappierUrl(empty, account).GetAwaiter().GetResult() == "https://account.example.invalid/", "fallback to account state");
            Check(TrayMenuModel.HappierUrl(Data("{\"happier\":{\"webappUrl\":\"https://config.example.invalid/\"}}"), account).GetAwaiter().GetResult() == "https://config.example.invalid/", "config takes priority");
            foreach (string url in new[] { "", "not a url", "file:///tmp/app", "javascript:alert(1)", "https://user:pass@example.invalid" })
                Check(!TrayMenuModel.Build(Data(Json.Encode(new { happier = new { webappUrl = url } })), empty, transport, health)[0].Enabled, "invalid URL cannot launch: " + url);
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
            Check(ServerHealthView.Warning(Health(0, 50000)) && ServerHealthView.Summary(Health(0, 50000)).StartsWith("⚠"), "normalized full disk warns with healthy memory");
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
            Check(!schedule.Due(now, false, false, "server-a"), "no poll without confirmed route");
            Check(!schedule.Due(now, true, true, "server-a"), "busy poll deferred");
            Check(schedule.Due(now, true, false, "server-a"), "first read due immediately"); schedule.Started(now);
            Check(!schedule.Due(now.AddSeconds(299), true, false, "server-a"), "no poll before five minutes");
            Check(schedule.Due(now.AddMinutes(5), true, false, "server-a"), "poll every five minutes including errors");
            Check(!schedule.Due(now.AddSeconds(1), true, true, "server-b"), "new server poll waits while occupied");
            Check(schedule.Due(now.AddSeconds(2), true, false, "server-b"), "new server resets five-minute poll delay"); schedule.Started(now.AddSeconds(2));
            Check(!schedule.Due(now.AddSeconds(3), true, false, "server-b"), "same server keeps poll delay");
            Check(!schedule.Due(now.AddSeconds(4), true, false, ""), "missing server identity cannot poll");
            Check(WizardStep.Timeout("ServerHealth") == 10000, "outer wizard budget ten seconds");
            string dir = Path.Combine(Path.GetTempPath(), "health-tests-" + Guid.NewGuid().ToString("N"));
            try {
                Directory.CreateDirectory(Path.Combine(dir, "state")); string path = Path.Combine(dir, "state/server-health.json");
                Check(!ServerHealthView.Known(ServerHealthView.Read(dir, now)), "missing health file");
                string profile = Path.Combine(dir, "profile.json");
                Files.Atomic(Path.Combine(dir, "config.json"), Json.Encode(new { transport = new { profilePath = profile } }));
                Files.Atomic(profile, Json.Encode(new { serverAddress = "server-a.invalid", login = "worker", arguments = new[] { "-p", "22255" } }));
                health["serverId"] = "server-a.invalid\n22255\nworker";
                health["updatedUtc"] = now.ToString("o"); Files.Atomic(path, Json.Encode(health).Replace("{", "{\r\n"));
                Check(ServerHealthView.Known(ServerHealthView.Read(dir, now)), "CRLF state file is read");
                Check(!ServerHealthView.Known(ServerHealthView.Read(dir, now.AddSeconds(361))), "stale health not shown as current");
                Check(!ServerHealthView.Known(ServerHealthView.Read(dir, now.AddSeconds(-10))), "future stamp rejected");
                Files.Atomic(path, Json.Encode(health));
                Check(ServerHealthView.Known(ServerHealthView.Read(dir, now)), "same server metrics accepted");
                Check(ServerHealthView.Identity(dir) == "server-a.invalid\n22255\nworker", "identity agrees with PowerShell state");
                foreach (var changed in new[] {
                    new { serverAddress = "server-b.invalid", login = "worker", arguments = new[] { "-p", "22255" } },
                    new { serverAddress = "server-a.invalid", login = "worker", arguments = new[] { "-p", "22" } },
                    new { serverAddress = "server-a.invalid", login = "other", arguments = new[] { "-p", "22255" } } }) {
                    Files.Atomic(profile, Json.Encode(changed));
                    Check(!ServerHealthView.Known(ServerHealthView.Read(dir, now)), "address/port/login changes hide previous metrics");
                    var stale = ServerHealthView.Read(dir, now);
                    Check(!ServerHealthView.Summary(stale).Contains("ГиБ") && !TrayMenuModel.Tooltip(transport, stale).Contains("ОЗУ"), "menu and tooltip hide previous metrics");
                }
                Files.Atomic(profile, Json.Encode(new { serverAddress = "server-b.invalid", login = "worker", arguments = new[] { "-p", "22255" } }));
                Check(!ServerHealthView.Known(ServerHealthView.Read(dir, now)), "fresh metrics of previous server hidden after profile replacement");
                health.Remove("serverId"); Files.Atomic(path, Json.Encode(health));
                Check(!ServerHealthView.Known(ServerHealthView.Read(dir, now)), "legacy state without identity is unknown");
                File.Delete(profile);
                Check(!ServerHealthView.Known(ServerHealthView.Read(dir, now)), "missing profile cannot validate metrics");
                Files.Atomic(path, "BROKEN"); Check(!ServerHealthView.Known(ServerHealthView.Read(dir, now)), "corrupt state safe");
            } finally { Directory.Delete(dir, true); }
            Console.WriteLine("PASS: " + count + " tray menu/server health/path/schedule checks");
        }
    }
}
