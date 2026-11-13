using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Threading;
using System.Xml;

namespace RemoteAgents.Launcher
{
    // One observation for both panes and the header. Syncthing remains the source of transfer state.
    internal sealed class DiskSyncFolder
    {
        internal string Id = "", Path = "";
        internal bool Pending, Paused, Shared;
        internal Dictionary<string, object> Status = new Dictionary<string, object>();
        internal Dictionary<string, object> Errors = new Dictionary<string, object>();
    }
    internal sealed class DiskSyncSnapshot
    {
        internal string Failure = "ожидаю ответ", DisconnectedFor = "";
        internal bool Connected;
        internal string[] ConfiguredPaths = new string[0];
        internal decimal InBytesTotal = -1, OutBytesTotal = -1;
        internal DateTime ObservedUtc = DateTime.UtcNow;
        internal readonly Dictionary<string, DiskSyncFolder> Folders = new Dictionary<string, DiskSyncFolder>(StringComparer.OrdinalIgnoreCase);
        internal static DiskSyncSnapshot Unavailable(string reason) { return new DiskSyncSnapshot { Failure = reason.Replace("\r", "").Split('\n')[0] }; }

        // Pure projection of parsed REST responses, including config path and the specific saved server ID.
        internal static DiskSyncSnapshot Parse(Dictionary<string, string> paths, string peer, object config,
            Dictionary<string, object> connections, Dictionary<string, object> pending,
            IDictionary<string, Dictionary<string, object>> statuses, IDictionary<string, Dictionary<string, object>> errors)
        {
            var result = new DiskSyncSnapshot { ConfiguredPaths = Json.Array(config).Select(Json.Map).Select(f => Json.Str(f, "path")).Where(p => p.Length > 0).ToArray(), Failure = "", Connected = Json.Bool(Json.Map(Json.Get(Json.Map(Json.Get(connections, "connections")), peer)), "connected") };
            var totals = Json.Map(Json.Get(connections, "total"));
            result.InBytesTotal = DiskSyncStatus.Number(totals, "inBytesTotal"); result.OutBytesTotal = DiskSyncStatus.Number(totals, "outBytesTotal");
            foreach (var pair in paths) {
                var matches = Json.Array(config).Select(Json.Map).Where(f => SamePath(Json.Str(f, "path"), pair.Value)).ToArray();
                var folder = new DiskSyncFolder(); result.Folders[pair.Key] = folder;
                if (matches.Length != 1) {
                    folder.Pending = pending.Values.Select(Json.Map).Any(p => Json.Str(Json.Map(Json.Get(Json.Map(Json.Get(p, "offeredBy")), peer)), "label") == pair.Key);
                    continue;
                }
                var c = matches[0]; folder.Id = Json.Str(c, "id"); folder.Path = Json.Str(c, "path"); folder.Paused = Json.Bool(c, "paused");
                folder.Shared = Json.Array(Json.Get(c, "devices")).Select(Json.Map).Any(d => Json.Str(d, "deviceID") == peer);
                folder.Pending = Json.Map(Json.Get(Json.Map(Json.Get(pending, folder.Id)), "offeredBy")).ContainsKey(peer);
                Dictionary<string, object> value;
                if (statuses.TryGetValue(folder.Id, out value)) folder.Status = value;
                if (errors.TryGetValue(folder.Id, out value)) folder.Errors = value;
            }
            return result;
        }
        internal static bool SamePath(string a, string b)
        { return a.Length > 0 && b.Length > 0 && string.Equals(a.Replace('\\', '/').TrimEnd('/'), b.Replace('\\', '/').TrimEnd('/'), StringComparison.OrdinalIgnoreCase); }
    }
    internal static class DiskSyncStatus
    {
        internal static decimal Number(Dictionary<string, object> data, string key, decimal fallback = -1)
        { decimal n; return decimal.TryParse(Json.Str(data, key), NumberStyles.Number, CultureInfo.InvariantCulture, out n) ? n : fallback; }
        static string Line(string value) { return value.Replace("\r", "").Split('\n')[0]; }
        internal static string FirstError(DiskSyncFolder folder)
        {
            foreach (var value in Json.Array(Json.Get(folder.Errors, "errors"))) {
                var error = Json.Map(value); string text = Json.Str(error, "error");
                if (text.Length > 0) return (Json.Str(error, "path").Length > 0 ? Line(Json.Str(error, "path")) + ": " : "") + Line(text);
            }
            return "";
        }
        internal static bool HasLocalChanges(DiskSyncFolder folder)
        { return folder != null && new[] { "receiveOnlyChangedFiles", "receiveOnlyChangedBytes", "receiveOnlyTotalItems" }.Any(k => Number(folder.Status, k, 0) != 0); }
        internal static bool Complete(DiskSyncSnapshot snapshot, DiskSyncFolder folder)
        {
            return snapshot.Failure.Length == 0 && snapshot.Connected && folder != null && folder.Id.Length > 0 && folder.Shared && !folder.Pending && !folder.Paused && !HasLocalChanges(folder) &&
                Json.Str(folder.Status, "state") == "idle" && Number(folder.Status, "needFiles") == 0 && Number(folder.Status, "needBytes") == 0 &&
                Number(folder.Status, "needTotalItems", 0) == 0 && Number(folder.Status, "errors", 0) == 0 && Number(folder.Status, "pullErrors", 0) == 0 && Json.Str(folder.Status, "error").Length == 0 && FirstError(folder).Length == 0;
        }
        internal static string Text(DiskSyncSnapshot snapshot, DiskSyncFolder folder)
        {
            if (snapshot.Failure.Length > 0) return "Состояние Syncthing недоступно: " + snapshot.Failure;
            if (folder != null) {
                string error = FirstError(folder);
                if (error.Length > 0) return "⚠ " + error;
                if (Json.Str(folder.Status, "state") == "error" || Json.Str(folder.Status, "error").Length > 0) return "⚠ " + Line(Json.Text(folder.Status, "error", "Syncthing остановил папку из-за ошибки"));
                if (Number(folder.Status, "errors", 0) > 0 || Number(folder.Status, "pullErrors", 0) > 0) return "⚠ Syncthing не смог обработать часть файлов";
                if (HasLocalChanges(folder)) return "⚠ Есть локальные изменения, не отправленные на сервер";
                if (folder.Paused || Json.Str(folder.Status, "state") == "paused") return "⏸ Синхронизация приостановлена";
            }
            if (!snapshot.Connected) return "⏸ Нет связи с сервером" + (snapshot.DisconnectedFor.Length > 0 ? " · " + snapshot.DisconnectedFor : "");
            if (folder != null && folder.Pending) return "⏳ Ждёт подключения";
            if (folder == null || folder.Id.Length == 0) return "⏳ Сервер ещё не открыл папку";
            if (!folder.Shared) return "⏳ Ждёт подключения";
            if (Complete(snapshot, folder)) return "✓ Синхронизирована";
            string state = Json.Str(folder.Status, "state");
            if (new[] { "syncing", "sync-preparing", "scanning", "scan-waiting", "sync-waiting", "idle", "cleaning", "clean-waiting" }.Contains(state)) {
                decimal total = Number(folder.Status, "globalBytes"), synced = Number(folder.Status, "inSyncBytes");
                // Flooring avoids promising 100% while bytes or zero-byte files are still needed.
                string percent = total > 0 && synced >= 0 ? Math.Floor(Math.Min(100, Math.Max(0, synced / total * 100))).ToString(CultureInfo.InvariantCulture) + "%" : "обработка";
                decimal files = Number(folder.Status, "needFiles"), bytes = Number(folder.Status, "needBytes");
                return "⟳ " + percent + (files >= 0 && bytes >= 0 ? " · осталось " + files.ToString(CultureInfo.InvariantCulture) + " файлов, " + Size(bytes) : " · объём ещё не известен") +
                    (state == "scanning" || state == "scan-waiting" ? " · сканирование" : "");
            }
            return "⏳ Ждёт подключения";
        }
        static string Size(decimal bytes)
        { return bytes >= 1048576 ? (bytes / 1048576).ToString("0.#", CultureInfo.GetCultureInfo("ru-RU")) + " МБ" : bytes >= 1024 ? (bytes / 1024).ToString("0.#", CultureInfo.GetCultureInfo("ru-RU")) + " КБ" : bytes.ToString(CultureInfo.InvariantCulture) + " Б"; }
    }

    // Native framework HTTP/XML APIs suffice: read-only local REST, no SSH or PowerShell process per tick.
    internal sealed class DiskSyncReader
    {
        DateTime? lastConnected; string binding = "";
        internal DiskSyncSnapshot Read(string home, Dictionary<string, string> paths, CancellationToken token)
        {
            try {
                token.ThrowIfCancellationRequested();
                var xml = new XmlDocument { XmlResolver = null }; xml.Load(Path.Combine(home, "state", "config.xml"));
                var gui = xml.SelectSingleNode("/configuration/gui/address"); var apiKey = xml.SelectSingleNode("/configuration/gui/apikey");
                if (gui == null || apiKey == null || gui.InnerText.Length == 0 || apiKey.InnerText.Length == 0) throw new IOException("не заданы адрес GUI или API-ключ Syncthing");
                string address = gui.InnerText; string key = apiKey.InnerText;
                bool tls = xml.SelectSingleNode("/configuration/gui/@tls") != null && xml.SelectSingleNode("/configuration/gui/@tls").Value == "true";
                var endpoint = new Uri((tls ? "https://" : "http://") + address + "/rest/");
                string peer = File.ReadAllText(Path.Combine(home, "server.txt")).Replace("\r", "").Trim();
                if (peer.Length == 0) throw new IOException("сервер Syncthing ещё не настроен");
                string current = endpoint.AbsoluteUri + "|" + peer;
                if (binding != current) { binding = current; lastConnected = null; }
                Func<string, object> get = route => Get(new Uri(endpoint, route), key, token);
                var result = Collect(paths, peer, get, token);
                if (result.Connected) lastConnected = DateTime.UtcNow;
                else if (lastConnected.HasValue) result.DisconnectedFor = "последняя связь " + Math.Max(0, (int)(DateTime.UtcNow - lastConnected.Value).TotalSeconds).ToString(CultureInfo.InvariantCulture) + " с назад";
                return result;
            } catch (OperationCanceledException) { throw; }
            catch (Exception e) {
                // Never expose config.xml, the API key, or a request URI in the window/journal.
                var web = e as WebException; var http = web == null ? null : web.Response as HttpWebResponse;
                string reason = http != null ? "локальный REST вернул HTTP " + (int)http.StatusCode : web != null ? "локальный REST не отвечает (" + web.Status + ")" : e is UriFormatException ? "некорректный адрес GUI Syncthing" : e is UnauthorizedAccessException ? "нет доступа к локальной конфигурации Syncthing" : e is FileNotFoundException || e is DirectoryNotFoundException ? "локальная конфигурация Syncthing ещё не найдена" : e is XmlException ? "ошибка чтения конфигурации Syncthing" : e is IOException ? e.Message : "не удалось прочитать ответ Syncthing";
                if (http != null) http.Close();
                return DiskSyncSnapshot.Unavailable(reason);
            }
        }
        internal static DiskSyncSnapshot Collect(Dictionary<string, string> paths, string peer, Func<string, object> get, CancellationToken token)
        {
            object config = get("config/folders");
            var connections = Json.Map(get("system/connections")); var pending = Json.Map(get("cluster/pending/folders"));
            var statuses = new Dictionary<string, Dictionary<string, object>>(); var errors = new Dictionary<string, Dictionary<string, object>>();
            foreach (var c in Json.Array(config).Select(Json.Map).Where(c => paths.Values.Any(p => DiskSyncSnapshot.SamePath(Json.Str(c, "path"), p)))) {
                token.ThrowIfCancellationRequested(); string id = Json.Str(c, "id");
                statuses[id] = Json.Map(get("db/status?folder=" + Uri.EscapeDataString(id)));
                errors[id] = Json.Map(get("folder/errors?folder=" + Uri.EscapeDataString(id)));
            }
            return DiskSyncSnapshot.Parse(paths, peer, config, connections, pending, statuses, errors);
        }
        static object Get(Uri uri, string key, CancellationToken token)
        {
            var request = (HttpWebRequest)WebRequest.Create(uri); request.Proxy = null; request.AllowAutoRedirect = false; request.Timeout = request.ReadWriteTimeout = 1800;
            request.Headers["X-API-Key"] = key;
            using (token.Register(request.Abort)) using (var response = request.GetResponse()) using (var reader = new StreamReader(response.GetResponseStream())) {
                token.ThrowIfCancellationRequested(); return Json.Parse(reader.ReadToEnd().Replace("\r", ""));
            }
        }
    }
}
