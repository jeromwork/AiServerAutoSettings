using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace RemoteAgents.Launcher
{
    internal static class DiskFoldersModelTests
    {
        static int count;
        static void Check(bool ok, string message) { if (!ok) throw new Exception("Folders: " + message); count++; }
        static Dictionary<string, object> Profile(string disk) { return Json.Map(Json.Parse("{\"disk\":" + disk + "}")); }
        static DiskFoldersModel Model(string disk) { return new DiskFoldersModel(DiskChoice.FromProfile(Profile(disk))); }
        static Dictionary<string, object> Level(string rows, bool truncated = false)
        { return Json.Map(Json.Parse("{\"rows\":[" + rows + "],\"truncated\":" + (truncated ? "true" : "false") + "}")); }
        static string Row(string path, string direction = "both", int changes = 0)
        { return "{\"path\":" + Json.Encode(path) + ",\"kind\":\"directory\",\"presence\":\"both\",\"direction\":" + Json.Encode(direction) + ",\"localChanges\":" + changes + "}"; }
        static DiskChoice Roundtrip(DiskFoldersModel model)
        { return DiskChoice.FromProfile(model.ToChoice().WriteTo(new Dictionary<string, object>(), "C:\\Disk")); }
        static bool Refused(Action action) { try { action(); return false; } catch (IOException) { return true; } catch (InvalidDataException) { return true; } }
        static void TransferChecks()
        {
            var m = Model("{\"folders\":[]}");
            m.Level("", Level(Row("Local").Replace("both", "local") + "," + Row("Remote").Replace("both", "server")));
            Check(m.OnComputer("Local") && !m.OnServer("Local"), "local-only folder belongs on computer");
            Check(!m.OnComputer("Remote") && m.OnServer("Remote"), "server-only folder belongs on server");
            m.TakeToComputer("Remote");
            Check(m.OnComputer("Remote") && m.Includes("Remote") && Roundtrip(m).Folders.Count == 1, "take creates pending local row and config choice");
            m.SetDirection("Remote", DiskChoice.Send); m.TakeToComputer("Remote");
            Check(m.DirectionOf("Remote") == DiskChoice.Both, "take enables receiving when previously send only");
            m.SendToServer("Local"); m.SetDirection("Local", DiskChoice.Receive); m.SendToServer("Local");
            Check(m.DirectionOf("Local") == DiskChoice.Both, "send enables sending when previously receive only");
            m.StopSynchronizing("Remote");
            Check(!m.Includes("Remote") && !m.OnComputer("Remote") && m.OnServer("Remote"), "stop removes pending download without inventing local presence");
            m.StopSynchronizing("Local");
            Check(m.OnComputer("Local") && !m.Includes("Local"), "stop keeps observed local folder visible");
            m.AddExternal("C:\\Other", "Other", DiskChoice.Receive);
            m.StopSynchronizing("Other"); m.SendToServer("Other");
            Check(m.External.Count == 1 && m.DirectionOf("Other") == DiskChoice.Both, "send restores detached external choice and enables upload");
            m.SetMode(DiskFoldersMode.All); m.StopSynchronizing("Remote");
            Check(m.Mode == DiskFoldersMode.Selected && m.Includes("Local") && !m.Includes("Remote"), "stop in all mode preserves other loaded roots");
            Check(Refused(() => m.TakeToComputer("")) && Refused(() => m.SendToServer("")) && Refused(() => m.StopSynchronizing("")), "empty actions refused");
            var partial = Model("{\"folders\":[{\"path\":\"Remote/Keep\",\"direction\":\"receive\"}]}");
            partial.TakeToComputer("Remote/New"); partial.StopSynchronizing("Remote/New");
            Check(Roundtrip(partial).Folders.Single().Path == "Remote/Keep" && partial.DirectionOf("Remote") == DiskChoice.Receive, "unloaded siblings and directions survive transfers");
            var incomplete = Model("{\"folders\":\"all\"}");
            incomplete.Level("", Level(Row("Local"), true));
            Check(Refused(() => incomplete.StopSynchronizing("Local")) && incomplete.Mode == DiskFoldersMode.All, "incomplete all inventory cannot silently discard hidden selections");
        }
        static Dictionary<string, object> Map(string text) { return Json.Map(Json.Parse(text)); }
        static DiskSyncSnapshot Snapshot(string state = "idle", long files = 0, long bytes = 0, long total = 100, long synced = 100)
        {
            var paths = new Dictionary<string, string> { { "Фото", "C:\\Disk\\Фото" } };
            return DiskSyncSnapshot.Parse(paths, "peer", Json.Parse("[{\"id\":\"photo/id\",\"path\":\"C:/Disk/Фото\",\"devices\":[{\"deviceID\":\"peer\"}]}]"),
                Map("{\r\n\"connections\":{\"peer\":{\"connected\":true}}\r\n}"), Map("{}"),
                new Dictionary<string, Dictionary<string, object>> { { "photo/id", new Dictionary<string, object> {
                    { "state", state }, { "needFiles", files }, { "needBytes", bytes }, { "globalBytes", total }, { "inSyncBytes", synced }, { "errors", 0 }, { "pullErrors", 0 } } } },
                new Dictionary<string, Dictionary<string, object>>());
        }
        static void StatusChecks()
        {
            foreach (string presence in new[] { "both", "server", "local", "" }) foreach (bool applied in new[] { false, true })
            foreach (string direction in DiskChoice.Directions) foreach (bool truncated in new[] { false, true }) {
                Check(!DiskFoldersModel.FolderStatus(true, presence, applied, direction, truncated, true).Contains("✓"), "presence and Apply never prove sync");
                Check(DiskFoldersModel.FolderStatus(false, presence, applied, direction, truncated, false).StartsWith("Не синхронизируется"), "unchecked copy facts never imply transfer");
                Check(DiskFoldersModel.FolderStatus(false, presence, applied, direction, truncated, true).Contains("файлы на компьютере останутся"), "pending removal preserves files");
            }
            var s = Snapshot(); var f = s.Folders["Фото"];
            Check(DiskSyncStatus.Text(s, f) == "✓ Синхронизирована" && DiskSyncStatus.Complete(s, f), "idle and zero need are complete");
            foreach (string state in new[] { "syncing", "sync-preparing", "scanning", "scan-waiting", "sync-waiting", "idle", "cleaning", "clean-waiting" }) {
                s = Snapshot(state, 120, 30L * 1048576, 100L * 1048576, 45L * 1048576); f = s.Folders["Фото"];
                string text = DiskSyncStatus.Text(s, f);
                Check(text.StartsWith("⟳ 45% · осталось 120 файлов, 30 МБ") && !DiskSyncStatus.Complete(s, f), "real byte ratio and remaining counts: " + state);
            }
            s = Snapshot("scanning", 0, 0, 0, 0); f = s.Folders["Фото"];
            Check(DiskSyncStatus.Text(s, f).Contains("сканирование") && !DiskSyncStatus.Complete(s, f), "empty scanning folder never completes early or divides by zero");
            s = Snapshot("idle", 0, 0, 0, 0); f = s.Folders["Фото"];
            Check(DiskSyncStatus.Complete(s, f), "empty idle folder completes");
            s = Snapshot("syncing", 1, 1, 100000000000, 45678900000); f = s.Folders["Фото"];
            Check(DiskSyncStatus.Text(s, f).StartsWith("⟳ 45%"), "large files use 64-bit counters and floor percentages");
            foreach (string field in new[] { "needBytes", "needFiles" }) {
                s = Snapshot(); f = s.Folders["Фото"]; f.Status.Remove(field);
                Check(!DiskSyncStatus.Complete(s, f), "missing counters are unknown, never zero: " + field);
            }
            s = Snapshot(); f = s.Folders["Фото"]; f.Status["needTotalItems"] = 1;
            Check(!DiskSyncStatus.Complete(s, f), "pending empty directories/deletes are not complete");
            f.Errors = Map("{\"errors\":[{\"path\":\"src/a.cs\",\"error\":\"доступ запрещён\\r\\nподробности\"},{\"error\":\"вторая\"}]}");
            Check(DiskSyncStatus.Text(s, f) == "⚠ src/a.cs: доступ запрещён" && !DiskSyncStatus.Complete(s, f), "first folder error keeps path, normalizes CRLF");
            foreach (string field in new[] { "errors", "pullErrors" }) {
                s = Snapshot(); f = s.Folders["Фото"]; f.Status[field] = 2;
                Check(DiskSyncStatus.Text(s, f).StartsWith("⚠") && !DiskSyncStatus.Complete(s, f), "error counters cannot complete: " + field);
            }
            s = Snapshot("error"); f = s.Folders["Фото"];
            Check(DiskSyncStatus.Text(s, f).Contains("из-за ошибки"), "state error has a plain explanation");
            f.Status["error"] = "папка исчезла\r\nподробности";
            Check(DiskSyncStatus.Text(s, f) == "⚠ папка исчезла", "state error detail retained");
            s = Snapshot(); f = s.Folders["Фото"]; f.Paused = true;
            Check(DiskSyncStatus.Text(s, f).Contains("приостановлена") && !DiskSyncStatus.Complete(s, f), "paused config is not complete");
            f.Paused = false; s.Connected = false; s.DisconnectedFor = "40 с";
            Check(DiskSyncStatus.Text(s, f) == "⏸ Нет связи с сервером · 40 с" && !DiskSyncStatus.Complete(s, f), "disconnected server overrides even idle/zero need");
            s.Connected = true; f.Pending = true;
            Check(DiskSyncStatus.Text(s, f) == "⏳ Ждёт подключения" && !DiskSyncStatus.Complete(s, f), "pending share cannot complete");
            f.Pending = false; f.Shared = false;
            Check(DiskSyncStatus.Text(s, f) == "⏳ Ждёт подключения" && !DiskSyncStatus.Complete(s, f), "local folder shared with another server is not ours");
            Check(DiskSyncStatus.Text(s, null) == "⏳ Сервер ещё не открыл папку", "missing config awaits server");
            s = DiskSyncSnapshot.Unavailable("локальный REST не отвечает\r\ntrace");
            Check(DiskSyncStatus.Text(s, f) == "Состояние Syncthing недоступно: локальный REST не отвечает" && !DiskSyncStatus.Complete(s, f), "REST failure replaces stale success");
            s = Snapshot("new-state"); f = s.Folders["Фото"];
            Check(!DiskSyncStatus.Complete(s, f) && !DiskSyncStatus.Text(s, f).Contains("✓"), "unknown state is not a success");

            var calls = new Dictionary<string, int>();
            var config = Json.Parse("[{\"id\":\"photo/id\",\"path\":\"C:/Disk/Фото\",\"devices\":[{\"deviceID\":\"peer\"}]} , {\"id\":\"other\",\"path\":\"C:/Other\"}]");
            Func<string, object> get = route => {
                calls[route] = calls.ContainsKey(route) ? calls[route] + 1 : 1;
                if (route == "config/folders") return config;
                if (route == "system/connections") return Map("{\"connections\":{\"unrelated\":{\"connected\":true}}}");
                if (route == "cluster/pending/folders") return Map("{\"pending-id\":{\"offeredBy\":{\"peer\":{\"label\":\"Работа\"}}}}");
                if (route == "db/status?folder=photo%2Fid") return Snapshot().Folders["Фото"].Status;
                if (route == "folder/errors?folder=photo%2Fid") return Map("{}");
                throw new Exception("Unexpected REST route: " + route);
            };
            var wanted = new Dictionary<string, string> { { "Фото", "C:\\Disk\\Фото\\" }, { "Работа", "C:\\Disk\\Работа" } };
            s = DiskSyncReader.Collect(wanted, "peer", get, System.Threading.CancellationToken.None);
            Check(!s.Connected && s.Folders["Работа"].Pending, "connection/pending belong to the specific server");
            Check(calls.Count == 5 && calls.Values.All(n => n == 1), "one shared collection per cycle, one query per configured project, no unrelated folders");
            s.Connected = true;
            Check(DiskSyncStatus.Text(s, s.Folders["Работа"]) == "⏳ Ждёт подключения", "pending offer before local config is visible");
            wanted["Фото"] = "C:/Disk/Other"; calls.Clear();
            s = DiskSyncReader.Collect(wanted, "peer", get, System.Threading.CancellationToken.None);
            Check(s.Folders["Фото"].Id.Length == 0 && calls.Count == 3, "same label at another path cannot confirm the selected folder");
            s = new DiskSyncReader().Read(Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N")), wanted, System.Threading.CancellationToken.None);
            Check(s.Failure.Contains("конфигурация") && !s.Connected, "missing config yields unavailable snapshot");

            var m = Model("{\"folders\":[\"Фото\",\"Работа\"]}");
            m.Level("", Level(Row("Фото") + "," + Row("Работа")));
            Check(m.Status("Фото").StartsWith("Состояние Syncthing недоступно"), "presence cannot initialize successful status");
            m.MarkApplied(); Check(!m.Status("Фото").Contains("✓"), "Apply cannot initialize successful status");
            m.Sync = Snapshot();
            Check(m.Status("Фото") == "✓ Синхронизирована" && m.SyncSummary == "Синхронизировано: 1 из 2 папок", "header and folder use the same complete predicate");
            foreach (string icon in new[] { "✅ ", "❌ ", "⏳ ", "" }) Check(m.MainStatusLine(icon + "Диск: Синхронизировано: 99 папок") == "Диск: Синхронизировано: 1 из 2 папок", "header replaces monitor counts even behind a status icon");
            Check(m.MainStatusLine("Связь: работает") == "Связь: работает", "folder observation does not change other service rows");
            Check(m.ServerFact("Фото") == "Есть на сервере", "server panel has only the server fact");
            m.Level("Фото", Level(Row("Фото/А"))); Check(m.Status("Фото/А") == m.Status("Фото"), "lazy descendants share one project observation");
            Check(LocalFolders.State(m, "C:\\Disk\\Фото", "C:\\Disk", new string[0]).Status == m.Status("Фото"), "whole-computer browser uses the same REST status for a Disk folder");
            m.Set("Фото", false); Check(m.Status("Фото").Contains("файлы на компьютере останутся") && m.SyncSummary == "Синхронизировано: 0 из 1 папок", "header follows pending deselection");
            m.MarkApplied(); Check(m.Status("Фото") == "Не синхронизируется; копии на компьютере и сервере", "unchecked folders show only copy facts");
            m.Set("Фото", true); m.Sync.Connected = false;
            Check(m.SyncSummary == "Синхронизировано: 0 из 2 папок" && m.Status("Фото").Contains("Нет связи"), "offline header never counts stale idle states");
            m.Sync = DiskSyncSnapshot.Unavailable("таймаут"); Check(m.SyncSummary.Contains("недоступно: таймаут") && m.MainStatusLine("✅ Диск: Синхронизировано").Contains("недоступно: таймаут"), "header exposes REST failure instead of old success");
            m.SetDirection("Фото", DiskChoice.Receive); m.Level("", Level(Row("Фото", "receive", 2)));
            Check(m.CanRevert("Фото"), "receive-only local changes still expose revert");
            m.SetDirection("Фото", DiskChoice.Both); Check(!m.CanRevert("Фото"), "both direction never exposes receive-only revert");
            var all = Model("{\"folders\":\"all\"}"); all.Level("", Level(Row("Gone"))); all.Level("", Level(""));
            Check(!all.SelectedProjects.Any() && !all.OnServer("Gone"), "complete inventory refresh removes stale presence and header totals");
            var unseen = Model("{\"folders\":[\"Missing/Child\"]}"); unseen.Level("", Level(""));
            Check(unseen.SelectedProjects.Single() == "Missing" && unseen.SyncPaths("C:\\Disk").ContainsKey("Missing"), "persisted selection stays observable even before the folder exists");
            m.AddExternal("D:\\Camera", "Камера", DiskChoice.Both); var e = m.External.Single();
            m.ExternalState(e, "idle"); Check(!m.ExternalStatus(e).Contains("✓"), "legacy external inventory idle has no completion counters");
            var observed = Snapshot(); observed.Folders["Камера"] = observed.Folders["Фото"]; m.Sync = observed;
            Check(m.ExternalStatus(e) == "✓ Синхронизирована", "external folders use the same REST status function");
            m.SetExternal(e, false); Check(m.ExternalStatus(e).StartsWith("Не синхронизируется"), "unapplied external removal never invents a previous connection");
        }
        static void RestReaderChecks()
        {
            string home = Path.Combine(Path.GetTempPath(), "disk-rest-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(Path.Combine(home, "state"));
            var listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0); listener.Start();
            int port = ((System.Net.IPEndPoint)listener.LocalEndpoint).Port;
            var requests = new List<string>();
            var worker = System.Threading.Tasks.Task.Run(() => {
                try {
                    for (int i = 0; i < 5; i++) using (var client = listener.AcceptTcpClient()) {
                        client.ReceiveTimeout = client.SendTimeout = 5000;
                        using (var stream = client.GetStream()) using (var input = new StreamReader(stream, System.Text.Encoding.ASCII, false, 1024, true)) {
                            string request = input.ReadLine(), line; var headers = new List<string>();
                            while (!string.IsNullOrEmpty(line = input.ReadLine())) headers.Add(line);
                            if (!headers.Any(h => h.Equals("X-API-Key: fixture-api-key", StringComparison.OrdinalIgnoreCase))) throw new Exception("Missing Syncthing API key header");
                            string route = request.Split(' ')[1]; requests.Add(route);
                            string body = route == "/rest/config/folders" ? "[{\"id\":\"photo/id\",\"path\":\"C:/Disk/Фото\",\"devices\":[{\"deviceID\":\"peer\"}]}]" :
                                route == "/rest/system/connections" ? "{\"connections\":{\"peer\":{\"connected\":true}}}" :
                                route == "/rest/db/status?folder=photo%2Fid" ? "{\"state\":\"idle\",\"needFiles\":0,\"needBytes\":0}" : "{}";
                            byte[] bytes = System.Text.Encoding.UTF8.GetBytes(body.Replace("{", "{\r\n"));
                            byte[] head = System.Text.Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nConnection: close\r\nContent-Length: " + bytes.Length + "\r\n\r\n");
                            stream.Write(head, 0, head.Length); stream.Write(bytes, 0, bytes.Length);
                        }
                    }
                } finally { listener.Stop(); }
            });
            try {
                File.WriteAllText(Path.Combine(home, "state", "config.xml"), "<configuration>\r\n<gui><address>127.0.0.1:" + port + "</address><apikey>fixture-api-key</apikey></gui>\r\n</configuration>");
                File.WriteAllText(Path.Combine(home, "server.txt"), "peer\r\n");
                var paths = new Dictionary<string, string> { { "Фото", "C:\\Disk\\Фото" } };
                var reader = new DiskSyncReader(); var s = reader.Read(home, paths, System.Threading.CancellationToken.None);
                Check(s.Failure == "" && DiskSyncStatus.Complete(s, s.Folders["Фото"]), "actual HTTP client reads XML GUI/key and CRLF peer/JSON");
                Check(worker.Wait(5000) && requests.Count == 5 && requests.Contains("/rest/folder/errors?folder=photo%2Fid"), "one HTTP collection includes the escaped folder ID and error endpoint");
                s = reader.Read(home, paths, System.Threading.CancellationToken.None);
                Check(s.Failure.Contains("REST не отвечает") && !s.Failure.Contains("fixture-api-key") && !s.Connected, "unreachable HTTP replaces old success without exposing key");
                var cancelled = new System.Threading.CancellationTokenSource(); cancelled.Cancel();
                bool stopped = false; try { reader.Read(home, paths, cancelled.Token); } catch (OperationCanceledException) { stopped = true; }
                Check(stopped, "closed window cancels polling before another request"); cancelled.Dispose();
            } finally { listener.Stop(); worker.Wait(5000); Directory.Delete(home, true); }
        }
        static void ReviewRegressions()
        {
            foreach (bool truncated in new[] { false, true }) {
                var m = Model("{\"folders\":[{\"path\":\"Фото/Архив\",\"direction\":\"receive\"},\"Невидимый/Путь\"]}");
                m.Level("", Level(Row("Фото") + "," + Row("Работа"), truncated));
                string before = Json.Encode(m.ToChoice().WriteTo(new Dictionary<string, object>(), "C:\\Disk"));
                m.SetMode(DiskFoldersMode.All);
                Check(m.ToChoice().All && m.DirectionOf("Фото") == DiskChoice.Both, "all applies both temporarily");
                // A refresh in All must not overwrite the saved manual directions or unloaded paths.
                m.Level("", Level(Row("Фото", "send") + "," + Row("Работа"), truncated));
                m.SetMode(DiskFoldersMode.Selected);
                Check(Json.Encode(m.ToChoice().WriteTo(new Dictionary<string, object>(), "C:\\Disk")) == before,
                    "all toggle restores exact manual subtrees and directions, truncated=" + truncated);
            }
            var fresh = Model("{\"folders\":[]}");
            fresh.Level("", Level(Row("Фото").Replace("both", "server")));
            fresh.Set("Фото", true); fresh.Set("Фото", false);
            Check(fresh.Status("Фото") == "Не синхронизируется; копия на сервере", "cancelled uncommitted check never stages a disconnection");
            fresh.SetMode(DiskFoldersMode.All); fresh.SetMode(DiskFoldersMode.Selected);
            Check(fresh.Status("Фото") == "Не синхронизируется; копия на сервере", "cancelled all never stages a disconnection");
            var external = Model("{\"folders\":\"all\",\"external\":[{\"path\":\"D:\\\\Фото\",\"remote\":\"Фото\",\"direction\":\"send\"}]}");
            external.Level("", Level(Row("Фото").Replace("both", "server") + "," + Row("Работа")));
            var entry = external.External.Single();
            Check(external.DirectionOf("Фото") == DiskChoice.Send, "server alias uses external direction even in All");
            Check(external.ExternalFor("фото/Архив") == entry && external.Includes("фото/Архив"), "external aliases resolve project names case-insensitively for lazy children");
            external.SetDirection("Фото", DiskChoice.Receive);
            Check(entry.Direction == DiskChoice.Receive && Roundtrip(external).External.Single().Direction == DiskChoice.Receive && external.Mode == DiskFoldersMode.All,
                "server alias changes the actual external choice without expanding All");
            external.MarkApplied(); external.ExternalState(entry, "syncing");
            Check(external.Status("Фото") == external.ExternalStatus(entry), "server and external aliases share observed status");
            external.Set("Фото", false);
            Check(!external.Includes("Фото") && !external.IncludesExternal(entry) && !external.Partial("Фото") && external.Mode == DiskFoldersMode.All,
                "unchecking server alias disables external only and overrides All");
            Check(external.Status("Фото") == external.ExternalStatus(entry) && external.Status("Фото").Contains("Перестанет"), "both rows show pending removal");
            external.SetExternal(entry, true);
            Check(external.Includes("Фото") && external.DirectionOf("Фото") == DiskChoice.Receive, "external alias rechecks server alias without losing direction");
            external.SetExternal(entry, false); external.MarkApplied();
            Check(!external.Includes("Фото") && !external.Status("Фото").Contains("Скачивается") && !external.Status("Фото").Contains("Перестанет"),
                "applied external removal remains excluded from All without claiming an imminent stop");
            // An inventory outage / missing applied hash must not hide the handler's confirmed exclusion.
            var withoutInventory = Model("{\"folders\":\"all\",\"external\":[{\"path\":\"D:\\\\Фото\",\"remote\":\"Фото\",\"direction\":\"send\"}]}");
            withoutInventory.Level("", Level(Row("Фото").Replace("both", "server")));
            withoutInventory.SetExternal(withoutInventory.External.Single(), false);
            withoutInventory.MarkApplied(new[] { "Фото" });
            Check(!withoutInventory.Includes("Фото") && withoutInventory.Status("Фото") == "Не синхронизируется; копия на сервере", "actual exclusion wins without a previous inventory or hash");
            var cancelledExternal = Model("{\"folders\":\"all\"}");
            cancelledExternal.AddExternal("D:\\Фото", "Фото", DiskChoice.Send);
            cancelledExternal.SetExternal(cancelledExternal.External.Single(), false);
            cancelledExternal.MarkApplied(new string[0]);
            Check(cancelledExternal.Includes("Фото"), "cancelled external addition does not invent an exclusion");
            external.SetMode(DiskFoldersMode.Selected);
            Check(!Roundtrip(external).Paths.Contains("Фото"), "leaving All cannot implicitly reconnect the excluded external project");
        }
        static void RestartRegressions()
        {
            string home = Path.Combine(Path.GetTempPath(), "folders-restart-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(home);
            try {
                var profile = Profile("{\"folders\":[{\"path\":\"Фото\",\"direction\":\"receive\"},{\"path\":\"Работа\",\"direction\":\"send\"}]}");
                ConfigProfile.Update(home, p => p["disk"] = profile["disk"]);
                Action<DiskFoldersModel, string, string> verify = (model, photo, work) => {
                    model.Level("", Level(Row("Фото", "receive").Replace("\"presence\":\"both\"", "\"presence\":\"server\"") + "," +
                        Row("Работа", "send").Replace("\"presence\":\"both\"", "\"presence\":\"local\"")));
                    Check(model.Status("Фото") == photo && model.Status("Работа") == work, "restart status: " + photo + "/" + work);
                };
                Func<DiskFoldersModel> reopen = () => {
                    var p = ConfigProfile.Load(home);
                    return new DiskFoldersModel(DiskChoice.FromProfile(p), ConfigProfile.AppliedDiskChoice(home, p));
                };
                verify(reopen(), "Состояние Syncthing недоступно: ожидаю ответ", "Состояние Syncthing недоступно: ожидаю ответ");
                ConfigProfile.MarkApplied(home, ConfigSections.Disk, ConfigSections.Hash(profile, ConfigSections.Disk));
                verify(reopen(), "Состояние Syncthing недоступно: ожидаю ответ", "Состояние Syncthing недоступно: ожидаю ответ");
                var confirmed = reopen(); verify(confirmed, "Состояние Syncthing недоступно: ожидаю ответ", "Состояние Syncthing недоступно: ожидаю ответ"); confirmed.Set("Фото", false);
                Check(confirmed.Status("Фото").Contains("Перестанет"), "confirmed selection stages removal after restart");
                ConfigProfile.Update(home, p => p["disk"] = Profile("{\"folders\":[\"Фото\",\"Работа\"]}")["disk"]);
                verify(reopen(), "Состояние Syncthing недоступно: ожидаю ответ", "Состояние Syncthing недоступно: ожидаю ответ");
                ConfigProfile.MarkApplied(home, ConfigSections.Disk, null);
                var unconfirmed = reopen(); verify(unconfirmed, "Состояние Syncthing недоступно: ожидаю ответ", "Состояние Syncthing недоступно: ожидаю ответ"); unconfirmed.Set("Фото", false);
                Check(unconfirmed.Status("Фото") == "Не синхронизируется; копия на сервере", "unapplied saved selection does not invent a previous connection");
                ConfigProfile.Update(home, p => p["disk"] = Profile("{\"folders\":\"all\"}")["disk"]);
                ConfigProfile.MarkApplied(home, ConfigSections.Disk, ConfigSections.Hash(ConfigProfile.Load(home), ConfigSections.Disk));
                var diskHome = Path.Combine(home, "disk"); Directory.CreateDirectory(diskHome);
                Files.Atomic(Path.Combine(diskHome, "server.txt"), "peer-a\n");
                Json.Write(Path.Combine(diskHome, "external-exclusions.json"), new { schema = 1, peer = "peer-a", names = new[] { "Фото" } });
                var all = ConfigProfile.Load(home);
                var excluded = new DiskFoldersModel(DiskChoice.FromProfile(all), ConfigProfile.AppliedDiskChoice(home, all), ConfigProfile.DiskExclusions(diskHome));
                excluded.Level("", Level(Row("Фото").Replace("both", "server") + "," + Row("Работа")));
                Check(!excluded.Includes("Фото") && excluded.Status("Фото") == "Не синхронизируется; копия на сервере" && excluded.Includes("Работа"), "restart respects removed external exclusion in All");
                excluded.Set("Фото", true);
                Check(!excluded.ToChoice().All && excluded.Includes("Фото") && excluded.Status("Фото") == "Состояние Syncthing недоступно: ожидаю ответ", "explicit reconnect under Disk stays pending until apply");
                Files.Atomic(Path.Combine(diskHome, "server.txt"), "peer-b\n");
                Check(ConfigProfile.DiskExclusions(diskHome).Length == 0, "another server does not inherit external exclusions");
            } finally { Directory.Delete(home, true); }
        }
        internal static void Run()
        {
            ReviewRegressions(); RestartRegressions(); RestReaderChecks();
            StatusChecks(); TransferChecks();
            var absent = new Dictionary<string, object>();
            var c = DiskChoice.FromProfile(absent); var m = new DiskFoldersModel(c);
            Check(!c.Chosen && m.Mode == DiskFoldersMode.Selected, "missing choice prompts for folders");
            Check(!absent.ContainsKey("disk") && !c.Chosen, "display/skip does not mutate profile or choose empty folders");
            m.SetMode(DiskFoldersMode.None); c = Roundtrip(m);
            Check(c.Chosen && !c.All && c.Folders.Count == 0 && c.External.Count == 0, "explicit none roundtrips as chosen empty array");
            m = Model("{\"folders\":\"all\"}");
            Check(m.Mode == DiskFoldersMode.All && m.Includes("unloaded/deep") && Roundtrip(m).All, "all includes unloaded and future folders");
            m.Level("", Level(Row("Фото") + "," + Row("Работа")));
            m.Level("Фото", Level(Row("Фото/Альбом") + "," + Row("Фото/Скрытое")));
            m.Set("Фото/Альбом", false); c = Roundtrip(m);
            Check(!c.All && c.Paths.SequenceEqual(new[] {"Работа", "Фото/Скрытое"}.OrderBy(x => x, StringComparer.Ordinal)), "unchecking from all preserves sibling and other project");
            Check(m.Partial("Фото") && !m.Includes("Фото/Альбом") && m.Includes("Фото/Скрытое/новое"), "partial and recursive display");
            m = Model("{\"folders\":[{\"path\":\"Фото/Архив/2024\",\"direction\":\"receive\"},\"НетНаСервере/Пока\"]}");
            m.Level("", Level(Row("Фото", "send", 7)));
            c = Roundtrip(m);
            Check(c.Paths.Contains("НетНаСервере/Пока") && c.Paths.Contains("Фото/Архив/2024"), "unloaded and missing selections survive inventory");
            Check(m.Partial("Фото") && m.DirectionOf("Фото/Архив") == DiskChoice.Receive && c.DirectionOf("Фото") == DiskChoice.Receive, "profile direction wins over stale tree metadata");
            Check(m.Items["Фото"].LocalChanges == 7 && m.Items["Фото"].Presence == "both", "receive changes and presence exposed to display");
            m.SetDirection("Фото", DiskChoice.Send);
            Check(Roundtrip(m).Folders.Single(f => f.Path.StartsWith("Фото")).Direction == DiskChoice.Send, "direction applies to top-level project including deep selection");
            m.Set("Фото", true); m.SetDirection("Фото", DiskChoice.Both);
            Check(Roundtrip(m).Folders.Single(f => f.Path == "Фото").Direction == DiskChoice.Both && !Roundtrip(m).Paths.Any(p => p.StartsWith("Фото/")), "parent replaces descendants and both remains simple");
            m = Model("{\"folders\":[\"Фото\"]}"); m.Level("", Level(Row("Фото", "receive", 3)));
            Check(m.DirectionOf("Фото") == DiskChoice.Both, "explicit default direction is not replaced by tree direction");
            m = Model("{}"); m.Level("", Level(Row("Фото", "receive", 3))); m.Set("Фото", true);
            Check(Roundtrip(m).DirectionOf("Фото") == DiskChoice.Receive, "new choice can reuse existing local direction");
            m = Model("{\"folders\":\"all\"}"); m.Level("", Level(Row("Фото") + "," + Row("Работа")));
            m.SetDirection("Фото", DiskChoice.Receive); c = Roundtrip(m);
            Check(!c.All && c.Paths.Length == 2 && c.DirectionOf("Фото") == DiskChoice.Receive && c.DirectionOf("Работа") == DiskChoice.Both, "direction from all serializes a complete explicit choice");
            m.SetMode(DiskFoldersMode.All); m.SetMode(DiskFoldersMode.Selected);
            Check(Roundtrip(m).DirectionOf("Фото") == DiskChoice.Receive, "all toggle restores project-specific directions");
            m = Model("{\"folders\":\"all\"}"); m.Level("", Level(Row("Фото", "receive")));
            Check(m.DirectionOf("Фото") == DiskChoice.Both && Roundtrip(m).All, "all displays the direction that its profile will actually apply");
            m = Model("{\"folders\":\"all\"}"); m.Level("", Level(Row("Фото"), true));
            Check(Refused(() => m.Set("Фото", false)) && Roundtrip(m).All, "incomplete inventory cannot silently lose folders when unchecking all");
            Check(Refused(() => m.SetDirection("Фото", DiskChoice.Send)) && Roundtrip(m).All, "incomplete all direction edit is refused without loss");
            m.SetMode(DiskFoldersMode.Selected); m.Set("Фото", true);
            Check(Roundtrip(m).Paths.SequenceEqual(new[] {"Фото"}), "explicit selective mode can choose from a truncated list");
            m = Model("{\"folders\":[\"Фото\"]}"); m.Level("Фото", Level(Row("Фото/А"), true));
            Check(Refused(() => m.Set("Фото/А", false)) && Roundtrip(m).Paths.SequenceEqual(new[] {"Фото"}), "partial child edit refuses to lose unlisted siblings");
            m = Model("{\"folders\":[\"Фото\"]}"); m.Level("Фото", Level(Row("Фото/А") + "," + Row("Фото/Б")));
            m.SetMode(DiskFoldersMode.None); m.Set("Фото", true); m.Set("Фото/А", false);
            Check(Roundtrip(m).Paths.SequenceEqual(new[] {"Фото/Б"}), "changing quick mode keeps loaded sibling information");
            m = Model("{\"folders\":[],\"external\":[{\"path\":\"D:\\\\Отчёты\",\"remote\":\"Отчёты\",\"direction\":\"send\"}]}");
            Check(m.Mode == DiskFoldersMode.Selected && Roundtrip(m).External[0].Direction == DiskChoice.Send, "external-only choice roundtrips");
            m.AddExternal("E:\\Фото", "Фото с камеры", DiskChoice.Receive); c = Roundtrip(m);
            Check(c.External.Count == 2 && c.External[1].Remote == "Фото с камеры" && c.External[1].Direction == DiskChoice.Receive, "external path, remote name and direction roundtrip");
            c.External[0].Direction = DiskChoice.Receive;
            Check(m.External[0].Direction == DiskChoice.Send, "export does not alias mutable UI entries");
            Check(Refused(() => m.AddExternal("e:\\фото\\", "Другое", DiskChoice.Both)), "duplicate local path rejected ignoring case and trailing separator");
            Check(Refused(() => m.AddExternal("F:\\Иное", "отчёты", DiskChoice.Both)), "duplicate server name rejected");
            Check(Refused(() => m.AddExternal("F:\\Иное", "../опасно", DiskChoice.Both)), "server name cannot escape a project");
            var profile = Profile("{\"base\":\"D:\\\\Disk\",\"folders\":[],\"extra\":true}"); profile["device"] = "kept";
            var written = m.ToChoice().WriteTo(profile, "X:\\Other");
            Check(Json.Str(Json.Map(written["disk"]), "base") == "D:\\Disk" && Json.Bool(Json.Map(written["disk"]), "extra") && (string)written["device"] == "kept", "profile update preserves base and unrelated settings");
            Check(DiskChoice.FromProfile(profile).External.Count == 0, "profile export leaves source unchanged");
            m.External.RemoveAt(0); Check(Roundtrip(m).External.Count == 1, "stop synchronizing exports removal only");
            m.SetMode(DiskFoldersMode.None); c = Roundtrip(m);
            Check(c.Folders.Count == 0 && c.External.Count == 0 && !c.All && c.Chosen, "none clears disk and external synchronization");
            m.AddExternal("C:\\Пример", "Пример", DiskChoice.Both);
            Check(m.Mode == DiskFoldersMode.Selected && Roundtrip(m).External.Count == 1, "adding external after none re-enables synchronization");
            Check(Refused(() => m.SetDirection("НеОтмечена", DiskChoice.Send)), "cannot change unchecked project direction");
            Check(Refused(() => m.Level("", Level(Row("wrong/level")))), "wrong tree level refused");
            var crlf = Model("{\r\n\"folders\":[{\"path\":\"Фото/Архив\",\"direction\":\"receive\"}]}\r\n");
            Check(Roundtrip(crlf).DirectionOf("Фото") == DiskChoice.Receive, "CRLF profile input supported");
            Console.WriteLine("OK: " + count + " folder display / choice checks (pure model; no WinForms)");
        }
    }
}
