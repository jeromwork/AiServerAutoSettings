using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Threading;

namespace RemoteAgents.Launcher
{
    // Durable intent precedes every config mutation. Recovery never repeats recycling.
    internal sealed class DiskOperationJournal
    {
        readonly string file, peer;
        internal DiskOperationJournal(string home, string peer) { file = Path.Combine(home, "disk-operations.json"); this.peer = peer; }
        internal static void Write(string file, object value)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(file));
            string temp = file + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try {
                byte[] bytes = Files.Utf8.GetBytes(Json.Encode(value));
                using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { stream.Write(bytes, 0, bytes.Length); stream.Flush(true); }
                if (File.Exists(file)) File.Replace(temp, file, null); else File.Move(temp, file);
            } finally { if (File.Exists(temp)) File.Delete(temp); }
        }
        internal IDisposable Lock()
        {
            string key;
            using (var sha = SHA256.Create()) key = BitConverter.ToString(sha.ComputeHash(Files.Utf8.GetBytes(Path.GetFullPath(file).ToUpperInvariant()))).Replace("-", "");
            return new Lease("RemoteDiskOperations-" + key);
        }
        sealed class Lease : IDisposable
        {
            readonly Mutex mutex;
            internal Lease(string key) { mutex = new Mutex(false, key); try { if (!mutex.WaitOne(DiskTiming.Milliseconds("OPERATION_LOCK", 35000))) throw new IOException("Диск занят другой операцией"); } catch (AbandonedMutexException) { } }
            public void Dispose() { mutex.ReleaseMutex(); mutex.Dispose(); }
        }
        Dictionary<string, object> Load()
        {
            try {
                if (!File.Exists(file)) return new Dictionary<string, object>();
                var data = Json.Read(file);
                if (Json.Str(data, "peer") != peer) {
                    if (Json.Map(Json.Get(data, "operations")).Count > 0) throw new IOException("Есть незавершённые операции прежнего сервера Диска");
                    return new Dictionary<string, object>();
                }
                if (!(Json.Get(data, "operations") is Dictionary<string, object>)) throw new IOException("Повреждён журнал операций Диска");
                return Json.Map(Json.Get(data, "operations")).ToDictionary(p => DiskPaths.Full(p.Key), p => p.Value, StringComparer.OrdinalIgnoreCase);
            } catch (Exception e) when (!(e is IOException)) { throw new IOException("Журнал операций Диска недоступен; изменения остановлены", e); }
        }
        void Save(Dictionary<string, object> operations) { Write(file, new { peer, operations }); }
        internal string UploadId(string path)
        {
            path = DiskPaths.Full(path);
            var ops = Load(); var previous = Json.Map(Json.Get(ops, path));
            if (Json.Str(previous, "kind") == "accept") {
                string existing = Json.Str(previous, "id");
                if (System.Text.RegularExpressions.Regex.IsMatch(existing, "^rd-upload-v1-[0-9a-f]{32}$")) return existing;
                throw new IOException("Ожидает сервер: сначала завершите прежний приём папки по её серверному ID");
            }
            string id = "rd-upload-v1-" + Guid.NewGuid().ToString("N");
            ops[path] = new { kind = "accept", phase = "reserved", id, path, name = Path.GetFileName(path), config = (object)null }; Save(ops); return id;
        }
        internal void Begin(string kind, DiskFolderState row, object config, Dictionary<string, string> inventory = null)
        {
            string path = DiskPaths.Full(row.Path);
            var ops = Load(); ops[path] = new { kind, phase = "prepared", id = row.Id, path, name = row.Name, config, inventory }; Save(ops);
        }
        internal void Phase(string path, string phase)
        {
            path = DiskPaths.Full(path);
            var ops = Load(); if (!ops.ContainsKey(path)) throw new IOException("Операция не записана в журнал");
            var op = Json.Map(ops[path]); op["phase"] = phase; Save(ops);
        }
        internal void Complete(string path)
        {
            path = DiskPaths.Full(path);
            var ops = Load(); if (!ops.ContainsKey(path)) return;
            var op = Json.Map(ops[path]);
            string history = Path.Combine(Path.GetDirectoryName(file), "disk-operation-results.jsonl");
            byte[] bytes = Files.Utf8.GetBytes(Json.Encode(new { time = DateTime.UtcNow.ToString("o"), peer, id = Json.Str(op, "id"), kind = Json.Str(op, "kind"), result = "reconciled" }) + "\n");
            using (var stream = new FileStream(history, FileMode.Append, FileAccess.Write, FileShare.Read)) { stream.Write(bytes, 0, bytes.Length); stream.Flush(true); }
            ops.Remove(path); Save(ops);
        }
        internal void Recover(IDiskRest rest, string root, DiskExplorerService metadata, DiskPlaceholderCatalog catalog, CancellationToken token)
        {
            foreach (var pair in Load().ToArray()) {
                var op = Json.Map(pair.Value); string path = Json.Str(op, "path"), id = Json.Str(op, "id"), kind = Json.Str(op, "kind");
                if (id.Length == 0 || !DiskPaths.Same(path, pair.Key) || (kind != "accept" && kind != "keep")) throw new IOException("Повреждена запись операции Диска");
                DiskPaths.Location(path, root); DiskPaths.Plain(path);
                DiskPaths.Plain(root); Directory.GetFileSystemEntries(root);
                var rows = Json.Array(rest.Request("GET", "config/folders", null, token)).Select(Json.Map).ToArray();
                var same = rows.SingleOrDefault(f => Json.Str(f, "id") == id);
                if (same != null && (!DiskPaths.Same(Json.Str(same, "path"), path) || !Json.Array(Json.Get(same, "devices")).Any(d => Json.Str(Json.Map(d), "deviceID") == peer)))
                    throw new IOException("Регистрация незавершённой операции изменилась; файлы сохранены");
                if (new DiskRetiredFolders(Path.GetDirectoryName(file), peer).Load().ContainsKey(id)) {
                    if (same != null) rest.Request("DELETE", "config/folders/" + Uri.EscapeDataString(id), null, token);
                    catalog.Forget(peer, id); Complete(path); continue;
                }
                if (kind == "accept") {
                    // An absent registration is an unconfirmed intent. Reuse its ID only on an explicit retry.
                    if (same != null) Complete(path);
                    continue;
                }
                var row = new DiskFolderState { Id = id, Name = Json.Str(op, "name"), Path = path, Config = Json.Map(Json.Get(op, "config")) };
                if (Directory.Exists(path) && !metadata.IsPlaceholder(path)) {
                    var saved = Json.Map(Json.Get(op, "inventory"));
                    var inventory = saved.ToDictionary(p => p.Key, p => Json.Str(saved, p.Key));
                    bool changed = saved.Count == 0;
                    try { DiskLocalInventory.Unchanged(path, inventory, id); }
                    catch (Exception e) when (e is IOException || e is UnauthorizedAccessException) { changed = true; }
                    var restore = new Dictionary<string, object>(row.Config);
                    if (changed) restore["paused"] = true;
                    if (same == null) {
                        if (rows.Any(f => DiskPaths.Overlaps(path, Json.Str(f, "path")))) throw new IOException("Восстановлению мешает другая регистрация; файлы сохранены");
                        if (row.Config.Count == 0) throw new IOException("В журнале нет исходной регистрации; файлы сохранены");
                        rest.Request("POST", "config/folders", restore, token);
                    }
                    else if (changed) rest.Request("PATCH", "config/folders/" + Uri.EscapeDataString(id), new { paused = true }, token);
                    catalog.Forget(peer, id); Complete(path);
                } else if (same == null) {
                    catalog.Remember(peer, row);
                    if (!metadata.MarkPlaceholder(path)) throw new IOException("Не удалось восстановить заглушку после освобождения места");
                    Complete(path);
                } else throw new IOException("Операция прервана при недоступной папке; восстановите доступ к Диску");
            }
        }
    }
    internal sealed class DiskLocalInventory
    {
        // Only program-owned control files are disposable. All other entries require an indexed server copy.
        internal static Dictionary<string, string> Capture(string root, string id)
        {
            var result = new Dictionary<string, string>(StringComparer.Ordinal);
            Walk(root, "", result, id); return result;
        }
        static void Walk(string root, string relative, Dictionary<string, string> result, string id)
        {
            foreach (string path in Directory.EnumerateFileSystemEntries(Path.Combine(root, relative))) {
                string name = Path.GetFileName(path), rel = relative.Length == 0 ? name : relative + "/" + name;
                try { DiskPaths.Plain(path); } catch (IOException) { result[rel] = "local-only"; continue; }
                if (relative.Length == 0 && name == ".stignore" && File.ReadAllText(path).TrimStart('\uFEFF').Trim() != "#include .stignore-remoteagents") { result[rel] = "local-only"; continue; }
                if (relative.Length == 0 && (name == ".stignore" || name == ".stignore-remoteagents")) {
                    // Preserve changes to control rules during the transaction as well.
                    result[rel] = "control:" + Hash(path); continue;
                }
                if (relative.Length == 0 && name == "desktop.ini" && File.ReadAllText(path).Contains("Owner=" + DiskExplorerService.Owner)) { result[rel] = "control:" + Hash(path); continue; }
                if (relative.Length == 0 && name == ".stfolder" && Directory.Exists(path)) {
                    string marker;
                    using (var sha = SHA256.Create()) marker = "syncthing-folder-" + BitConverter.ToString(sha.ComputeHash(Files.Utf8.GetBytes(id)), 0, 3).Replace("-", "").ToLowerInvariant() + ".txt";
                    var entries = Directory.GetFileSystemEntries(path);
                    bool owned = entries.Length == 0;
                    if (entries.Length == 1 && Path.GetFileName(entries[0]) == marker) {
                        DiskPaths.Plain(entries[0]);
                        string prefix = "# This directory is a Syncthing folder marker.\n# Do not delete.\n\nfolderID: " + id + "\ncreated: ";
                        string text = File.ReadAllText(entries[0]); DateTime stamp;
                        owned = text.StartsWith(prefix, StringComparison.Ordinal) && DateTime.TryParse(text.Substring(prefix.Length).Trim(), out stamp);
                    }
                    if (owned) continue;
                }
                if (new[] { ".git", "vendor", "node_modules", ".venv", "venv", ".stversions" }.Contains(name, StringComparer.OrdinalIgnoreCase)) { result[rel] = "local-only"; continue; }
                if (Directory.Exists(path)) { result[rel] = "directory"; Walk(root, rel, result, id); }
                else result[rel] = Hash(path);
            }
        }
        static string Hash(string path)
        {
            using (var sha = SHA256.Create()) using (var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
                return Convert.ToBase64String(sha.ComputeHash(file));
        }
        internal static void Unchanged(string root, Dictionary<string, string> before, string id)
        {
            var now = Capture(root, id); var changed = before.Keys.Union(now.Keys).Where(k => !before.ContainsKey(k) || !now.ContainsKey(k) || before[k] != now[k]).ToArray();
            if (changed.Length > 0) throw new IOException("Папка сохранена: появились поздние локальные изменения:\n" + string.Join("\n", changed));
        }
        internal static void Prove(IDiskRest rest, DiskFolderState row, Dictionary<string, string> inventory, CancellationToken token)
        {
            var unique = new List<string>();
            foreach (var entry in inventory.Where(e => !e.Value.StartsWith("control:", StringComparison.Ordinal))) {
                if (entry.Value == "local-only" || entry.Key.Contains(".sync-conflict-") || entry.Key == ".stversions" || entry.Key.StartsWith(".stversions/")) { unique.Add(entry.Key); continue; }
                try {
                    var data = Json.Map(rest.Request("GET", "db/file?folder=" + Uri.EscapeDataString(row.Id) + "&file=" + Uri.EscapeDataString(entry.Key), null, token));
                    var local = Json.Map(Json.Get(data, "local")); var global = Json.Map(Json.Get(data, "global"));
                    bool safe = new[] { local, global }.All(f => Json.Str(f, "name") == entry.Key && !Json.Bool(f, "deleted") && !Json.Bool(f, "ignored") && !Json.Bool(f, "invalid") && !Json.Bool(f, "mustRescan") && DiskSnapshot.Number(f, "localFlags") == 0);
                    safe &= Json.Array(Json.Get(local, "version")).Length > 0 && Json.Encode(Json.Get(local, "version")) == Json.Encode(Json.Get(global, "version"));
                    safe &= Json.Array(Json.Get(data, "availability")).Any(a => Json.Str(Json.Map(a), "id") == rest.Peer && !Json.Bool(Json.Map(a), "fromTemporary"));
                    safe &= entry.Value == "directory" ? Json.Str(global, "type") == "FILE_INFO_TYPE_DIRECTORY" : Json.Str(global, "type") == "FILE_INFO_TYPE_FILE" && DiskSnapshot.Number(global, "size") == new FileInfo(Path.Combine(row.Path, entry.Key)).Length;
                    if (!safe) unique.Add(entry.Key);
                } catch (IOException) { unique.Add(entry.Key); }
            }
            if (unique.Count > 0) throw new IOException("Нельзя оставить только на сервере: для этих локальных данных нет подтверждённой серверной копии:\n" + string.Join("\n", unique));
        }
    }
    internal sealed class DiskRetiredFolders
    {
        readonly string file, peer;
        internal DiskRetiredFolders(string home, string peer) { file = Path.Combine(home, "explorer-retired-" + peer + ".json"); this.peer = peer; }
        internal Dictionary<string, object> Load()
        {
            if (!File.Exists(file)) return new Dictionary<string, object>();
            try { var data = Json.Read(file); if (Json.Str(data, "peer") != peer || !(Json.Get(data, "removed") is Dictionary<string, object>)) throw new IOException("Повреждена память снятых папок"); return Json.Map(Json.Get(data, "removed")); }
            catch (Exception e) { throw new IOException("Память снятых папок недоступна; изменения остановлены", e); }
        }
        internal void Remember(DiskFolderState row)
        {
            var removed = Load(); removed[row.Id] = new { path = row.Path, name = row.Name };
            DiskOperationJournal.Write(file, new { peer, removed });
        }
    }
}
