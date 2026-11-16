using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;

namespace RemoteAgents.Launcher
{
    // Remember a Keep result while the new pending offer is in flight. This is UI metadata, never admission.
    internal sealed class DiskPlaceholderCatalog
    {
        readonly string file;
        internal string Home { get { return Path.GetDirectoryName(file); } }
        internal DiskPlaceholderCatalog(string diskHome) { file = Path.Combine(diskHome, "explorer-placeholders.json"); }
        Dictionary<string, object> Read() { return File.Exists(file) ? Json.Read(file) : new Dictionary<string, object>(); }
        internal void Remember(string peer, DiskFolderState row)
        {
            var data = Read(); if (Json.Str(data, "peer") != peer) data = new Dictionary<string, object> { { "peer", peer } };
            var rows = Json.Array(Json.Get(data, "folders")).Select(Json.Map).Where(f => Json.Str(f, "id") != row.Id).ToList();
            rows.Add(new Dictionary<string, object> { { "id", row.Id }, { "name", row.Name }, { "path", row.Path } }); data["folders"] = rows; Json.Write(file, data);
        }
        internal void Forget(string peer, string id)
        {
            var data = Read(); if (Json.Str(data, "peer") != peer) return;
            data["folders"] = Json.Array(Json.Get(data, "folders")).Where(f => Json.Str(Json.Map(f), "id") != id).ToArray(); Json.Write(file, data);
        }
        internal void Merge(string peer, DiskSnapshot snapshot, string root)
        {
            var data = Read(); if (Json.Str(data, "peer") != peer) return;
            foreach (var item in Json.Array(Json.Get(data, "folders"))) {
                var saved = Json.Map(item); string id = Json.Str(saved, "id"), name = Json.Str(saved, "name"), path = Json.Str(saved, "path");
                if (id.Length == 0 || !DiskPaths.ValidName(name)) continue;
                try { path = DiskPaths.Full(path); DiskPaths.Plain(path); DiskPaths.Location(path, root); } catch (IOException) { continue; }
                var configured = snapshot.Folders.FirstOrDefault(f => f.Id == id && !f.ServerOnly);
                if (configured != null) continue;
                var row = snapshot.Folders.FirstOrDefault(f => f.Id == id);
                if (row == null) { row = new DiskFolderState { Id = id, Name = name, ServerOnly = true, Kind = DiskExplorerKind.ServerOnly }; snapshot.Folders.Add(row); }
                row.Path = path;
            }
        }
    }
    internal sealed class DiskShellCommands
    {
        readonly IDiskRest rest; readonly string root, ignoreRules;
        readonly DiskExplorerService metadata; readonly DiskPlaceholderCatalog catalog;
        readonly DiskOperationJournal journal;
        readonly Action<string> recycle; readonly int readyTimeout; readonly string diskHome;
        internal DiskShellCommands(IDiskRest rest, string root, DiskExplorerService metadata, DiskPlaceholderCatalog catalog, string ignoreRules, Action<string> recycle, int readyTimeout = 30000, string diskHome = null)
        { this.rest = rest; this.root = root; this.metadata = metadata; this.catalog = catalog; this.ignoreRules = ignoreRules; this.recycle = recycle; this.readyTimeout = readyTimeout; this.diskHome = diskHome ?? catalog.Home; journal = new DiskOperationJournal(this.diskHome, rest.Peer); }
        internal DiskSnapshot Read(CancellationToken token)
        { using (journal.Lock()) { journal.Recover(rest, root, metadata, catalog, token); Migrate(token); var value = new DiskRestModel(rest, diskHome).Read(root, token); catalog.Merge(rest.Peer, value, root); metadata.ClassifyLocalCopies(value.Folders); return value; } }
        internal string Execute(DiskShellRequest request, CancellationToken token)
        {
            using (journal.Lock()) return ExecuteLocked(request, token);
        }
        string ExecuteLocked(DiskShellRequest request, CancellationToken token)
        {
            DiskPaths.Plain(request.Path);
            DiskPaths.Location(request.Path, root);
            var snapshot = Read(token);
            var matches = snapshot.Folders.Where(f => DiskPaths.Same(f.Path, request.Path)).ToArray();
            if (matches.Length > 1) throw new IOException("Имя занято на сервере: путь соответствует нескольким папкам Syncthing");
            var row = matches.SingleOrDefault();
            if (row != null && row.Kind == DiskExplorerKind.ServerRemoved) throw new IOException("Папка удалена на сервере. Локальная копия отсоединена и сохранена");
            if (request.Action == "keep-server") {
                if (row == null || row.ServerOnly || row.Config == null || row.Kind != DiskExplorerKind.Synced || !DiskPaths.ValidName(row.Name)) throw new IOException("Сначала дождитесь подтверждённой синхронизации с сервером и проверьте имя папки");
                Keep(row, token); return "Локальные файлы в Корзине. Папка оставлена только на сервере";
            }
            if (request.Action == "sync") {
                if (row == null || !row.ServerOnly || row.Kind != DiskExplorerKind.LocalCopy || !Directory.Exists(request.Path)) throw new IOException("Нужна локальная копия предложенной сервером папки");
                // The same send/receive acceptance used by download and the wizard: Syncthing
                // merges the existing files, with unlimited conflict copies and versioning.
                Accept(row, snapshot, token); return "Локальная копия подключена к серверу. Слияние и синхронизация запущены";
            }
            if (request.Action == "download") {
                if (row == null || !row.ServerOnly || row.Kind != DiskExplorerKind.ServerOnly || !metadata.IsPlaceholder(request.Path)) throw new IOException("Нужна пустая заглушка предложенной сервером папки");
                Accept(row, snapshot, token); return "Папка скачивается на компьютер. Синхронизация запущена";
            }
            if (request.Action != "add") throw new IOException("Неизвестная команда Диска");
            if (!Directory.Exists(request.Path)) throw new IOException("Папка не найдена");
            if (row != null && !row.ServerOnly) {
                if (row.Kind == DiskExplorerKind.Local) throw new IOException("Регистрация не предложена сервером; снимите её в Syncthing перед явной новой загрузкой");
                if (row.Uploads) return row.Kind == DiskExplorerKind.Pending || row.Kind == DiskExplorerKind.Offline
                    ? "Папка предложена серверу. Ожидает сервер" : "Папка уже синхронизируется с сервером";
                if (!DiskPaths.ValidName(row.Name) || snapshot.Folders.Any(f => f != row && string.Equals(f.Name, row.Name, StringComparison.OrdinalIgnoreCase))) throw new IOException("Имя папки уже занято или недопустимо на сервере");
                // Share a pre-existing Syncthing registration and enable uploads without replacing its other options or devices.
                var devices = Json.Array(Json.Get(row.Config, "devices")).ToList();
                if (!devices.Any(d => Json.Str(Json.Map(d), "deviceID") == rest.Peer)) devices.Add(new Dictionary<string, object> { { "deviceID", rest.Peer } });
                using (var rules = new DiskIgnoreChange(row.Path, ignoreRules)) {
                    try { rest.Request("PATCH", "config/folders/" + Uri.EscapeDataString(row.Id), new { devices, type = "sendreceive" }, token); }
                    catch { rules.Commit(); throw; } // A lost reply must never remove exclusions from an already-shared source.
                    rules.Commit();
                }
                return "Папка предложена серверу. Ожидает сервер";
            }
            string name = Path.GetFileName(request.Path);
            if (!DiskPaths.ValidName(name)) throw new IOException("Имя папки недопустимо на сервере");
            if (snapshot.Folders.Any(f => string.Equals(f.Name, name, StringComparison.OrdinalIgnoreCase))) throw new IOException("Имя занято на сервере; используйте «" + DiskMenu.Download + "»");
            // Server auto-accept uses the label as the top-level directory name. An ID must not collide locally.
            row = new DiskFolderState { Id = journal.UploadId(request.Path), Name = name, Path = request.Path };
            if (snapshot.Folders.Any(f => string.Equals(f.Id, row.Id, StringComparison.OrdinalIgnoreCase))) throw new IOException("ID папки уже занят в Syncthing");
            Accept(row, snapshot, token); return "Папка предложена серверу. Ожидает сервер";
        }
        void Accept(DiskFolderState row, DiskSnapshot snapshot, CancellationToken token)
        {
            DiskPaths.Available(row.Path, root, snapshot.Folders);
            var config = Json.Map(rest.Request("GET", "config/defaults/folder", null, token));
            var local = Json.Map(rest.Request("GET", "system/status", null, token)); string localId = Json.Str(local, "myID");
            if (localId.Length == 0) throw new IOException("Syncthing не сообщил ID компьютера");
            config["id"] = row.Id; config["label"] = row.Name; config["path"] = row.Path; config["type"] = "sendreceive";
            config["paused"] = false; config["fsWatcherEnabled"] = true; config["fsWatcherDelayS"] = 2; config["maxConflicts"] = -1;
            config["versioning"] = new { type = "staggered", @params = new { maxAge = "2592000", cleanInterval = "3600" } };
            config["devices"] = new[] { new { deviceID = localId }, new { deviceID = rest.Peer } };
            journal.Begin("accept", row, config);
            // Install exclusions before registering the folder, so the first scan cannot upload .git or secrets.
            using (var rules = new DiskIgnoreChange(row.Path, ignoreRules)) {
                journal.Phase(row.Path, "ignores-ready");
                try { rest.Request("POST", "config/folders", config, token); }
                catch (Exception e) when (e is IOException || e is OperationCanceledException) {
                    // The writer may still apply a timed-out POST after our GET. A negative
                    // read is not permission to remove first-scan exclusions from that source.
                    rules.Commit();
                    bool applied;
                    try { applied = Json.Array(rest.Request("GET", "config/folders", null, CancellationToken.None)).Select(Json.Map).Any(f => Json.Str(f, "id") == row.Id && DiskPaths.Same(Json.Str(f, "path"), row.Path)); }
                    catch { rules.Commit(); throw new IOException("Ответ Syncthing потерян. Исключения сохранены; проверьте регистрацию в Syncthing Tray"); }
                    if (!applied) throw;
                }
                rules.Commit();
            }
            journal.Complete(row.Path);
            catalog.Forget(rest.Peer, row.Id);
            row.ServerOnly = false; row.Kind = DiskExplorerKind.Syncing; row.Percent = 0;
            metadata.Reconcile(root, snapshot.Folders.Where(f => f.Id != row.Id).Concat(new[] { row }));
        }
        void Migrate(CancellationToken token)
        {
            foreach (var value in Json.Array(rest.Request("GET", "config/folders", null, token))) {
                var config = Json.Map(value); string path = Json.Str(config, "path"), id = Json.Str(config, "id");
                if (!Json.Array(Json.Get(config, "devices")).Any(d => Json.Str(Json.Map(d), "deviceID") == rest.Peer)) continue;
                try { DiskPaths.Location(path, root); DiskPaths.Plain(path); } catch (IOException) { continue; }
                if (!Directory.Exists(path)) continue;
                // Stop the scanner while upgrading an existing (including manually accepted) registration.
                bool paused = Json.Bool(config, "paused"); string route = "config/folders/" + Uri.EscapeDataString(id);
                bool changed;
                try { changed = DiskIgnoreChange.NeedsChange(path, ignoreRules); }
                catch (Exception e) when (e is IOException || e is UnauthorizedAccessException) {
                    if (!paused) rest.Request("PATCH", route, new { paused = true }, token);
                    throw new IOException("Папка приостановлена: не удалось безопасно проверить обязательные исключения", e);
                }
                var versioning = Json.Map(Json.Get(config, "versioning"));
                bool options = Json.Str(versioning, "type") != "staggered" || Json.Str(Json.Map(Json.Get(versioning, "params")), "maxAge") != "2592000" || Json.Str(Json.Map(Json.Get(versioning, "params")), "cleanInterval") != "3600" || Json.Int(config, "maxConflicts", 0) != -1;
                if (!changed && !options) continue;
                if (!paused) rest.Request("PATCH", route, new { paused = true }, token);
                using (var rules = new DiskIgnoreChange(path, ignoreRules)) rules.Commit();
                var migrated = new Dictionary<string, object>(versioning);
                var parameters = new Dictionary<string, object>(Json.Map(Json.Get(versioning, "params")));
                parameters["maxAge"] = "2592000"; parameters["cleanInterval"] = "3600";
                migrated["type"] = "staggered"; migrated["params"] = parameters;
                rest.Request("PATCH", route, new { paused, maxConflicts = -1, versioning = migrated }, token);
            }
        }
        void ConfirmForRemoval(DiskFolderState row, CancellationToken token)
        {
            // POST /db/scan waits for the full scan. An idle snapshot taken before the watcher
            // runs is not evidence that the user's latest edits reached the server.
            using (var deadline = CancellationTokenSource.CreateLinkedTokenSource(token)) {
                deadline.CancelAfter(readyTimeout); var check = deadline.Token;
                string folder = Uri.EscapeDataString(row.Id);
                try {
                    rest.Request("POST", "db/scan?folder=" + folder, null, check, readyTimeout);
                    while (true) {
                        check.ThrowIfCancellationRequested();
                        var before = Json.Map(rest.Request("GET", "db/status?folder=" + folder, null, check));
                        var remote = Json.Map(rest.Request("GET", "db/completion?folder=" + folder + "&device=" + Uri.EscapeDataString(rest.Peer), null, check));
                        var connections = Json.Map(Json.Get(Json.Map(rest.Request("GET", "system/connections", null, check)), "connections"));
                        var after = Json.Map(rest.Request("GET", "db/status?folder=" + folder, null, check));
                        var status = DiskSnapshot.Status(row.Copy(), after, remote, Json.Bool(Json.Map(Json.Get(connections, rest.Peer)), "connected"));
                        if (status.Kind == DiskExplorerKind.LocalChanges) throw new IOException(status.Tooltip);
                        long first, last;
                        bool stable = long.TryParse(Json.Str(before, "sequence"), out first) && long.TryParse(Json.Str(after, "sequence"), out last) && first == last;
                        // completion.sequence belongs to the REMOTE index, not our local sequence.
                        // Its zero needs must be measured between two reads of the same post-scan local index.
                        if (stable && status.Kind == DiskExplorerKind.Synced && Json.Str(before, "state") == "idle") { check.ThrowIfCancellationRequested(); return; }
                        if (!stable) rest.Request("POST", "db/scan?folder=" + folder, null, check, readyTimeout);
                        if (check.WaitHandle.WaitOne(200)) check.ThrowIfCancellationRequested();
                    }
                } catch (OperationCanceledException) when (!token.IsCancellationRequested) {
                    throw new IOException("Сервер не подтвердил свежие изменения вовремя. Папка сохранена на компьютере; дождитесь синхронизации и повторите действие");
                } catch (IOException e) when (!token.IsCancellationRequested) {
                    throw new IOException("Не удалось подтвердить свежие изменения на сервере. Папка сохранена на компьютере. " + e.Message, e);
                }
            }
        }
        void Keep(DiskFolderState row, CancellationToken token)
        {
            if (!Directory.Exists(row.Path)) throw new IOException("Локальная папка не найдена");
            DiskPaths.Available(row.Path, root, new DiskFolderState[0]);
            var inventory = DiskLocalInventory.Capture(row.Path, row.Id);
            ConfirmForRemoval(row, token);
            DiskLocalInventory.Prove(rest, row, inventory, token);
            DiskLocalInventory.Unchanged(row.Path, inventory, row.Id);
            journal.Begin("keep", row, row.Config, inventory);
            // Write the recovery mapping before detaching: a crash cannot lose an external folder's original location.
            catalog.Remember(rest.Peer, row);
            bool detached = false;
            try {
                rest.Request("DELETE", "config/folders/" + Uri.EscapeDataString(row.Id), null, token);
                var configured = Json.Array(rest.Request("GET", "config/folders", null, token)).Select(Json.Map).ToArray();
                if (configured.Any(f => Json.Str(f, "id") == row.Id || DiskPaths.Overlaps(row.Path, Json.Str(f, "path")))) throw new IOException("Syncthing ещё использует эту папку");
                detached = true;
                journal.Phase(row.Path, "detached");
                DiskLocalInventory.Unchanged(row.Path, inventory, row.Id);
                DiskPaths.Plain(row.Path);
                recycle(row.Path);
                journal.Phase(row.Path, "recycled");
                if (Directory.Exists(row.Path) || File.Exists(row.Path)) throw new IOException("Перенос папки в Корзину не подтверждён");
            } catch (Exception failure) {
                string changes = "";
                // Restore registration after a cancelled/failed recycle while the local data still exists.
                if (Directory.Exists(row.Path)) {
                    try {
                        try { DiskLocalInventory.Unchanged(row.Path, inventory, row.Id); }
                        catch (Exception e) when (e is IOException || e is UnauthorizedAccessException) { changes = e.Message; }
                        var restore = new Dictionary<string, object>(row.Config);
                        if (changes.Length > 0) restore["paused"] = true;
                        var current = Json.Array(rest.Request("GET", "config/folders", null, CancellationToken.None)).Select(Json.Map).ToArray();
                        var same = current.FirstOrDefault(f => Json.Str(f, "id") == row.Id);
                        if (same == null) {
                            if (current.Any(f => DiskPaths.Overlaps(row.Path, Json.Str(f, "path")))) throw new IOException("Путь уже занят другой регистрацией");
                            rest.Request("POST", "config/folders", restore, CancellationToken.None);
                        } else if (!DiskPaths.Same(Json.Str(same, "path"), row.Path)) throw new IOException("Регистрация папки изменена");
                        else if (changes.Length > 0) rest.Request("PATCH", "config/folders/" + Uri.EscapeDataString(row.Id), new { paused = true }, CancellationToken.None);
                        catalog.Forget(rest.Peer, row.Id);
                        journal.Complete(row.Path);
                    }
                    catch (Exception) { throw new IOException("Локальные файлы сохранены. Не удалось подтвердить восстановление синхронизации; проверьте папку в Syncthing Tray"); }
                } else if (!detached) catalog.Forget(rest.Peer, row.Id);
                if (changes.Length > 0) throw new IOException(changes + "\nРегистрация восстановлена на паузе. Проверьте локальную папку и Корзину перед возобновлением", failure);
                throw;
            }
            if (!metadata.MarkPlaceholder(row.Path)) throw new IOException("Файлы в Корзине; не удалось оформить заглушку");
            journal.Complete(row.Path);
        }
    }
    // Preserve user rules verbatim. On a rejected registration only our unchanged additions are rolled back.
    internal sealed class DiskIgnoreChange : IDisposable
    {
        readonly string include, managed; readonly byte[] oldInclude, oldManaged; readonly byte[] newInclude, newManaged;
        bool committed;
        internal DiskIgnoreChange(string path, string rules)
        {
            if (string.IsNullOrWhiteSpace(rules)) throw new IOException("Шаблон исключений Диска не найден");
            Directory.CreateDirectory(path); include = Path.Combine(path, ".stignore"); managed = Path.Combine(path, ".stignore-remoteagents");
            DiskPaths.Plain(include); DiskPaths.Plain(managed);
            if (Directory.Exists(include) || Directory.Exists(managed)) throw new IOException("Путь правил занят каталогом");
            oldInclude = File.Exists(include) ? File.ReadAllBytes(include) : null; oldManaged = File.Exists(managed) ? File.ReadAllBytes(managed) : null;
            newManaged = Files.Utf8.GetBytes(rules.Replace("\r", ""));
            newInclude = Include(oldInclude);
            try { File.WriteAllBytes(managed, newManaged); File.WriteAllBytes(include, newInclude); }
            catch { Dispose(); throw; }
        }
        static byte[] Include(byte[] old)
        {
            string current = old == null ? "" : Files.Utf8.GetString(old); bool bom = current.StartsWith("\uFEFF", StringComparison.Ordinal);
            if (bom) current = current.Substring(1);
            const string line = "#include .stignore-remoteagents";
            string nl = current.Contains("\r\n") ? "\r\n" : "\n";
            string user = string.Concat(System.Text.RegularExpressions.Regex.Split(current, "(?<=\n)").Where(l => l.Trim() != line));
            return Files.Utf8.GetBytes((bom ? "\uFEFF" : "") + line + nl + user);
        }
        internal static bool NeedsChange(string path, string rules)
        {
            DiskPaths.Plain(Path.Combine(path, ".stignore")); DiskPaths.Plain(Path.Combine(path, ".stignore-remoteagents"));
            string include = Path.Combine(path, ".stignore"), managed = Path.Combine(path, ".stignore-remoteagents");
            byte[] old = File.Exists(include) ? File.ReadAllBytes(include) : null;
            return old == null || !old.SequenceEqual(Include(old)) || !File.Exists(managed) || File.ReadAllText(managed) != rules.Replace("\r", "");
        }
        internal void Commit() { committed = true; }
        public void Dispose()
        {
            if (committed) return;
            Restore(include, oldInclude, newInclude); Restore(managed, oldManaged, newManaged);
        }
        static void Restore(string path, byte[] old, byte[] written)
        {
            DiskPaths.Plain(path);
            if (!File.Exists(path) || !File.ReadAllBytes(path).SequenceEqual(written)) return;
            if (old == null) File.Delete(path); else File.WriteAllBytes(path, old);
        }
    }
}
