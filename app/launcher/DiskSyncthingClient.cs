using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Xml;

namespace RemoteAgents.Launcher
{
    internal interface IDiskRest
    {
        string Peer { get; }
        object Request(string method, string route, object body, CancellationToken token, int timeout = 3000);
    }
    // The Explorer has no transport of its own. Only the installed loopback Syncthing API is reachable here.
    internal sealed class DiskSyncthingClient : IDiskRest
    {
        readonly Uri endpoint; readonly string apiKey, diskHome;
        public string Peer { get; private set; }
        internal DiskSyncthingClient(string diskHome)
        {
            this.diskHome = diskHome;
            using (var reader = XmlReader.Create(System.IO.Path.Combine(diskHome, "state", "config.xml"), new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null })) {
                var xml = new XmlDocument { XmlResolver = null }; xml.Load(reader);
                var gui = xml.SelectSingleNode("/configuration/gui");
                string address = gui == null ? "" : gui.SelectSingleNode("address") == null ? "" : gui.SelectSingleNode("address").InnerText.Trim();
                apiKey = gui == null || gui.SelectSingleNode("apikey") == null ? "" : gui.SelectSingleNode("apikey").InnerText.Trim();
                bool tls = gui != null && gui.Attributes["tls"] != null && gui.Attributes["tls"].Value == "true";
                if (!Uri.TryCreate((tls ? "https://" : "http://") + address + "/rest/", UriKind.Absolute, out endpoint) || endpoint.Host != "127.0.0.1" ||
                    endpoint.UserInfo.Length > 0 || endpoint.AbsolutePath != "/rest/" || endpoint.Query.Length > 0 || endpoint.Fragment.Length > 0 || apiKey.Length == 0)
                    throw new IOException("Локальный REST Syncthing должен слушать 127.0.0.1");
            }
            Peer = File.ReadAllText(System.IO.Path.Combine(diskHome, "server.txt")).TrimStart('\uFEFF').Replace("\r", "").Trim();
            if (Peer.Length == 0 || Peer.Any(char.IsWhiteSpace)) throw new IOException("Сервер Диска ещё не подключён");
        }
        public object Request(string method, string route, object body, CancellationToken token, int timeout = 3000)
        {
            token.ThrowIfCancellationRequested();
            if (method != "GET" && File.ReadAllText(System.IO.Path.Combine(diskHome, "server.txt")).TrimStart('\uFEFF').Replace("\r", "").Trim() != Peer)
                throw new IOException("Сервер Диска изменился. Повторите действие");
            var uri = new Uri(endpoint, route);
            if (uri.Host != endpoint.Host || uri.Port != endpoint.Port || uri.Scheme != endpoint.Scheme || !uri.AbsolutePath.StartsWith("/rest/", StringComparison.Ordinal)) throw new IOException("Недопустимый локальный запрос");
            var request = (HttpWebRequest)WebRequest.Create(uri);
            request.Method = method; request.Proxy = null; request.AllowAutoRedirect = false;
            request.Timeout = request.ReadWriteTimeout = timeout; request.Headers["X-API-Key"] = apiKey;
            request.ServicePoint.ConnectionLimit = Math.Max(8, request.ServicePoint.ConnectionLimit);
            try {
                using (token.Register(request.Abort)) {
                    if (body != null) {
                        byte[] data = new UTF8Encoding(false).GetBytes(Json.Encode(body)); request.ContentType = "application/json"; request.ContentLength = data.Length;
                        using (var stream = Await(request.GetRequestStreamAsync(), request, timeout, token)) stream.Write(data, 0, data.Length);
                    } else if (method == "POST" || method == "PUT" || method == "PATCH") request.ContentLength = 0;
                    using (var response = Await(request.GetResponseAsync(), request, timeout, token)) using (var reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8)) {
                        int status = (int)((HttpWebResponse)response).StatusCode;
                        if (status < 200 || status >= 300) throw new IOException("Локальный Syncthing отклонил запрос");
                        string value = Await(reader.ReadToEndAsync(), request, timeout, token).Replace("\r", ""); token.ThrowIfCancellationRequested();
                        if (string.IsNullOrWhiteSpace(value)) return null;
                        try { return Json.Parse(value); }
                        catch (Exception e) when (e is ArgumentException || e is InvalidOperationException) { throw new IOException("Syncthing вернул неожиданный ответ"); }
                    }
                }
            } catch (WebException e) {
                if (e.Response != null) e.Response.Dispose(); token.ThrowIfCancellationRequested();
                // Never include request headers, the XML, or a server response in journals/notifications.
                throw new IOException("Локальный Syncthing не подтвердил действие", e);
            }
        }
        static T Await<T>(Task<T> task, HttpWebRequest request, int timeout, CancellationToken token)
        {
            try {
                try { if (!task.Wait(timeout, token)) throw new IOException("Локальный Syncthing не ответил вовремя"); }
                catch (AggregateException) { return task.GetAwaiter().GetResult(); }
                return task.GetAwaiter().GetResult();
            } catch {
                request.Abort();
                // A cancelled GetResponseAsync may still finish: dispose that response rather than leak its connection.
                task.ContinueWith(done => { if (done.Status == TaskStatus.RanToCompletion) { var value = done.Result as IDisposable; if (value != null) value.Dispose(); } else { var ignored = done.Exception; } }, TaskScheduler.Default);
                throw;
            }
        }
    }
    internal sealed class DiskRestModel
    {
        readonly IDiskRest rest;
        internal DiskRestModel(IDiskRest rest) { this.rest = rest; }
        internal DiskSnapshot Read(string root, CancellationToken token)
        {
            var snapshot = new DiskSnapshot();
            var connections = Json.Map(Json.Get(Json.Map(rest.Request("GET", "system/connections", null, token)), "connections"));
            snapshot.Connected = Json.Bool(Json.Map(Json.Get(connections, rest.Peer)), "connected");
            foreach (var item in Json.Array(rest.Request("GET", "config/folders", null, token))) {
                var config = Json.Map(item); string id = Json.Str(config, "id"), path = Json.Str(config, "path");
                if (id.Length == 0 || path.Length == 0) continue;
                // A foreign registration may use Syncthing's ~/ syntax or an invalid Windows path.
                // Skip only unresolvable paths; keep every resolvable foreign path for overlap guards.
                if (!DiskPaths.TryFull(path, out path)) continue;
                var row = new DiskFolderState { Id = id, Name = Json.Text(config, "label", id), Path = path, Config = config, Paused = Json.Bool(config, "paused") };
                bool shared = Json.Array(Json.Get(config, "devices")).Any(d => Json.Str(Json.Map(d), "deviceID") == rest.Peer);
                if (shared && row.Paused) row.Kind = DiskExplorerKind.Paused;
                else if (shared) {
                    try {
                        var local = Json.Map(rest.Request("GET", "db/status?folder=" + Uri.EscapeDataString(id), null, token));
                        var remote = Json.Map(rest.Request("GET", "db/completion?folder=" + Uri.EscapeDataString(id) + "&device=" + Uri.EscapeDataString(rest.Peer), null, token));
                        DiskSnapshot.Status(row, local, remote, snapshot.Connected);
                    } catch (IOException) { row.Kind = DiskExplorerKind.Unavailable; }
                } else row.Kind = DiskExplorerKind.Local;
                snapshot.Folders.Add(row);
            }
            var pending = Json.Map(rest.Request("GET", "cluster/pending/folders?device=" + Uri.EscapeDataString(rest.Peer), null, token));
            foreach (var pair in pending) {
                var offer = Json.Map(Json.Get(Json.Map(Json.Get(Json.Map(pair.Value), "offeredBy")), rest.Peer));
                string name = Json.Text(offer, "label", pair.Key);
                if (offer.Count == 0 || !DiskPaths.ValidName(name) || Json.Bool(offer, "receiveEncrypted") || Json.Bool(offer, "remoteEncrypted") || snapshot.Folders.Any(f => f.Id == pair.Key)) continue;
                snapshot.Folders.Add(new DiskFolderState { Id = pair.Key, Name = name, Path = System.IO.Path.Combine(root, name), ServerOnly = true, Kind = DiskExplorerKind.ServerOnly });
            }
            // Ambiguous labels on Windows must never choose an offer arbitrarily.
            foreach (var group in snapshot.Folders.GroupBy(f => f.Path, StringComparer.OrdinalIgnoreCase).Where(g => g.Count() > 1))
                foreach (var row in group) { row.Kind = DiskExplorerKind.Error; row.Detail = "Несколько папок с одинаковым именем"; }
            return snapshot;
        }
        internal object[] Events(long since, CancellationToken token, bool tail = false)
        { return Json.Array(rest.Request("GET", tail ? "events?since=0&limit=1&timeout=0" : "events?since=" + since + "&timeout=25", null, token, tail ? 3000 : 30000)); }
        internal static long EventId(object value) { long n; return long.TryParse(Json.Str(Json.Map(value), "id"), out n) ? n : 0; }
        internal static bool ChangesFolders(object value)
        {
            return new[] { "ConfigSaved", "PendingFoldersChanged", "DeviceConnected", "DeviceDisconnected", "StateChanged", "FolderSummary", "FolderCompletion", "FolderErrors", "LocalIndexUpdated", "RemoteIndexUpdated", "DownloadProgress", "ItemFinished", "Starting", "StartupComplete" }.Contains(Json.Str(Json.Map(value), "type"));
        }
    }
}
