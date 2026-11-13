using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Security.Cryptography;
using System.Threading;
using System.Xml;

namespace RemoteAgents.Launcher
{
    // The fast Explorer integration cannot infer that ignored or unindexed files reached the server.
    // Therefore eviction requires per-file REST evidence and an unchanged local inventory in addition
    // to the server's folder completion. Unknown evidence always leaves the local data in place.
    internal interface IDiskEvictionRest
    {
        string PeerId { get; }
        bool IsDetached(string path);
        DiskSyncSnapshot Read(Dictionary<string, string> paths, CancellationToken token);
        void Scan(string folder);
        Dictionary<string, object> Completion(string folder);
        Dictionary<string, object> File(string folder, string relative);
    }
    internal interface IDiskRecycle
    {
        void File(string path);
        void Directory(string path);
    }
    internal sealed class DiskNativeRecycle : IDiskRecycle
    {
        public void File(string path) { Microsoft.VisualBasic.FileIO.FileSystem.DeleteFile(path, Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs, Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin, Microsoft.VisualBasic.FileIO.UICancelOption.ThrowException); }
        public void Directory(string path) { Microsoft.VisualBasic.FileIO.FileSystem.DeleteDirectory(path, Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs, Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin, Microsoft.VisualBasic.FileIO.UICancelOption.ThrowException); }
    }
    internal sealed class DiskEvictionCandidate
    {
        internal string Project = "", Reason = "";
        string path; Dictionary<string, string> inventory; IDiskEvictionRest evidence;
        internal static DiskEvictionCandidate Prepare(string home, string project, string path, CancellationToken token)
        {
            try { return Prepare(new DiskLocalRest(home, token), project, path, token); }
            catch (OperationCanceledException) { throw; }
            catch (Exception) { return new DiskEvictionCandidate { Project = project, path = path, Reason = "Не удалось надёжно проверить серверную копию" }; }
        }
        internal static DiskEvictionCandidate Prepare(IDiskEvictionRest rest, string project, string path, CancellationToken token)
        {
            var result = new DiskEvictionCandidate { Project = project, path = path, evidence = rest };
            try {
                var paths = new Dictionary<string, string> { { project, path } };
                var before = rest.Read(paths, token); DiskSyncFolder folder;
                if (!before.Folders.TryGetValue(project, out folder) || folder.Id.Length == 0) throw new IOException("Папка не найдена в конфигурации Syncthing");
                rest.Scan(folder.Id);
                var snapshot = rest.Read(paths, token);
                if (!snapshot.Folders.TryGetValue(project, out folder)) throw new IOException("Состояние папки изменилось");
                var completion = rest.Completion(folder.Id);
                result.Reason = DiskEvictionProof.Refusal(snapshot, folder, completion);
                if (result.Reason.Length > 0) return result;
                result.inventory = Inventory(path, token);
                foreach (string relative in result.inventory.Keys) {
                    token.ThrowIfCancellationRequested();
                    string full = Path.Combine(path, relative.Replace('/', Path.DirectorySeparatorChar)); bool directory = Directory.Exists(full);
                    var response = rest.File(folder.Id, relative);
                    if (!DiskEvictionProof.FileConfirmed(response, rest.PeerId, directory, directory ? 0 : new FileInfo(full).Length))
                        throw new IOException("Сервер не подтвердил файл «" + relative + "»; возможно, он исключён из синхронизации или изменён локально");
                    if (!directory) {
                        var local = Json.Map(Json.Get(response, "local"));
                        using (var stream = new FileStream(full, FileMode.Open, FileAccess.Read, FileShare.Read))
                            if (!DiskEvictionProof.ContentConfirmed(stream, local, token)) throw new IOException("Содержимое файла «" + relative + "» не подтверждено индексом Syncthing");
                        var realMtime = Json.Map(Json.Get(Json.Map(Json.Get(response, "mtime")), "value"));
                        string modified = Json.Text(realMtime, "real", Json.Str(local, "modified")); DateTime stamp;
                        if (!DateTime.TryParse(modified, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out stamp) || stamp.Year < 1980) modified = Json.Str(local, "modified");
                        if (!DateTime.TryParse(modified, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out stamp) || Math.Abs((stamp.ToUniversalTime() - File.GetLastWriteTimeUtc(full)).TotalMilliseconds) >= 1)
                            throw new IOException("Файл «" + relative + "» изменён после проверки Syncthing");
                    }
                }
                // Remote index may advance while the per-file checks run; require a fresh complete view.
                snapshot = rest.Read(paths, token); snapshot.Folders.TryGetValue(project, out folder);
                result.Reason = DiskEvictionProof.Refusal(snapshot, folder, rest.Completion(folder == null ? "" : folder.Id));
                if (result.Reason.Length == 0) result.Reason = result.Revalidate();
            } catch (OperationCanceledException) { throw; }
            catch (Exception e) { result.Reason = e is IOException ? e.Message : "Не удалось надёжно проверить серверную копию"; }
            return result;
        }
        internal string Revalidate()
        {
            try {
                if (inventory == null) return "Нет подтверждения серверной копии";
                var current = Inventory(path, CancellationToken.None);
                return current.Count == inventory.Count && current.All(p => inventory.ContainsKey(p.Key) && inventory[p.Key] == p.Value) ? "" : "После проверки появились локальные изменения";
            } catch (Exception) { return "Локальную папку не удалось повторно проверить"; }
        }
        internal void Recycle(IDiskRecycle recycle = null)
        {
            if (Reason.Length > 0) throw new IOException(Reason);
            if (evidence == null || !evidence.IsDetached(path)) throw new IOException("Syncthing ещё не подтвердил отключение локальной папки; файлы сохранены");
            if (recycle == null) recycle = new DiskNativeRecycle();
            string refusal = Revalidate(); if (refusal.Length > 0) throw new IOException(refusal);
            foreach (string item in Directory.EnumerateFileSystemEntries(path)) {
                if (Path.GetFileName(item).Equals("desktop.ini", StringComparison.OrdinalIgnoreCase) && System.IO.File.ReadAllText(item).Contains("Owner=RemoteAgents.Disk.v1")) continue;
                // Shell customization is replaced by the placeholder after the user data has gone.
                // Microsoft's FileSystem uses the user's Recycle Bin; cancellation never falls back to deletion.
                if (Directory.Exists(item)) recycle.Directory(item);
                else recycle.File(item);
            }
        }
        static Dictionary<string, string> Inventory(string root, CancellationToken token)
        {
            var result = new Dictionary<string, string>(StringComparer.Ordinal); var stack = new Stack<string>(); stack.Push(root);
            for (var ancestor = new DirectoryInfo(root); ancestor != null; ancestor = ancestor.Parent)
                if ((ancestor.Attributes & FileAttributes.ReparsePoint) != 0) throw new IOException("Соединение каталога нельзя очищать");
            while (stack.Count > 0) {
                string directory = stack.Pop();
                foreach (string item in Directory.EnumerateFileSystemEntries(directory)) {
                    token.ThrowIfCancellationRequested(); var attributes = File.GetAttributes(item);
                    if ((attributes & FileAttributes.ReparsePoint) != 0) throw new IOException("В папке есть соединение каталога; файлы сохранены");
                    string relative = item.Substring(root.TrimEnd('\\', '/').Length + 1).Replace('\\', '/');
                    if (directory == root && relative == ".stfolder") {
                        if (!Directory.Exists(item) || Directory.EnumerateFileSystemEntries(item).Any()) throw new IOException("Служебная папка .stfolder содержит неизвестные файлы");
                        continue;
                    }
                    if (directory == root && relative == ".stignore") continue;
                    if (directory == root && relative.Equals("desktop.ini", StringComparison.OrdinalIgnoreCase) && File.ReadAllText(item).Contains("Owner=RemoteAgents.Disk.v1")) continue;
                    bool isDirectory = (attributes & FileAttributes.Directory) != 0;
                    if (isDirectory) { result[relative] = "D"; stack.Push(item); }
                    else using (var sha = SHA256.Create()) using (var stream = new FileStream(item, FileMode.Open, FileAccess.Read, FileShare.Read))
                        result[relative] = new FileInfo(item).Length.ToString(CultureInfo.InvariantCulture) + ":" + File.GetLastWriteTimeUtc(item).Ticks + ":" + BitConverter.ToString(sha.ComputeHash(stream));
                }
            }
            return result;
        }
    }
    internal sealed class DiskLocalRest : IDiskEvictionRest
    {
        readonly Uri endpoint; readonly string key, home; readonly CancellationToken token; internal readonly string Peer;
        public string PeerId { get { return Peer; } }
        public DiskSyncSnapshot Read(Dictionary<string, string> paths, CancellationToken token)
        {
            if (Files.ReadLine(Path.Combine(home, "server.txt")) != Peer) return DiskSyncSnapshot.Unavailable("Настройка сервера изменилась");
            return new DiskSyncReader().Read(home, paths, token);
        }
        public bool IsDetached(string path)
        {
            if (Files.ReadLine(Path.Combine(home, "server.txt")) != Peer) return false;
            object configured = Json.Parse(Request("GET", "config/folders", 2500));
            if (!(configured is System.Collections.IEnumerable) || configured is string || configured is System.Collections.IDictionary) return false;
            return !Json.Array(configured).Select(Json.Map).Any(f => DiskSyncSnapshot.SamePath(Json.Str(f, "path"), path));
        }
        internal DiskLocalRest(string home, CancellationToken token)
        {
            this.token = token; this.home = home;
            var xml = new XmlDocument { XmlResolver = null }; xml.Load(Path.Combine(home, "state", "config.xml"));
            var gui = xml.SelectSingleNode("/configuration/gui");
            if (gui == null || gui.SelectSingleNode("address") == null || gui.SelectSingleNode("apikey") == null) throw new IOException("Локальный REST не настроен");
            bool tls = gui.Attributes["tls"] != null && gui.Attributes["tls"].Value == "true";
            endpoint = new Uri((tls ? "https://" : "http://") + gui.SelectSingleNode("address").InnerText + "/rest/"); key = gui.SelectSingleNode("apikey").InnerText;
            Peer = System.IO.File.ReadAllText(Path.Combine(home, "server.txt")).Replace("\r", "").Trim();
            if (Peer.Length == 0 || key.Length == 0 || !endpoint.IsLoopback) throw new IOException("Нет подтверждённого локального REST Syncthing");
        }
        public void Scan(string folder) { Request("POST", "db/scan?folder=" + Uri.EscapeDataString(folder), 120000); }
        public Dictionary<string, object> Completion(string folder) { return Json.Map(Json.Parse(Request("GET", "db/completion?folder=" + Uri.EscapeDataString(folder) + "&device=" + Uri.EscapeDataString(Peer), 2500))); }
        public Dictionary<string, object> File(string folder, string relative) { return Json.Map(Json.Parse(Request("GET", "db/file?folder=" + Uri.EscapeDataString(folder) + "&file=" + Uri.EscapeDataString(relative), 2500))); }
        string Request(string method, string route, int timeout)
        {
            token.ThrowIfCancellationRequested(); var request = (HttpWebRequest)WebRequest.Create(new Uri(endpoint, route));
            request.Method = method; request.Proxy = null; request.AllowAutoRedirect = false; request.Timeout = request.ReadWriteTimeout = timeout; request.Headers["X-API-Key"] = key;
            if (method == "POST") request.ContentLength = 0;
            try { using (token.Register(request.Abort)) using (var response = request.GetResponse()) using (var reader = new StreamReader(response.GetResponseStream())) { token.ThrowIfCancellationRequested(); return reader.ReadToEnd().Replace("\r", ""); } }
            catch (WebException) { token.ThrowIfCancellationRequested(); throw new IOException("Локальный REST не подтвердил безопасное освобождение папки"); }
        }
    }
}
