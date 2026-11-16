using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;

namespace RemoteAgents.Launcher
{
    // Names of the Explorer menu items. The hint on a placeholder and the messages refer to an item by this name,
    // so the name lives in one place: the text a person reads in the menu is the text the hint tells them to click.
    internal static class DiskMenu
    {
        internal const string Download = "Скачать на компьютер", KeepServer = "Оставить только на сервере", Upload = "Загрузить на сервер";
        internal const string ServerOnlyHint = "Только на сервере. Правый клик → " + Download;
    }
    internal enum DiskExplorerKind { Local, ServerOnly, Pending, Syncing, Synced, Paused, Error, Offline, Unavailable, LocalChanges, ServerRemoved }
    internal sealed class DiskFolderState
    {
        internal string Id = "", Name = "", Path = "", Detail = "";
        internal bool ServerOnly, Paused;
        internal DiskExplorerKind Kind = DiskExplorerKind.Pending;
        internal int Percent;
        internal Dictionary<string, object> Config;
        internal DiskFolderState Copy() { return (DiskFolderState)MemberwiseClone(); }
        // Shared with the server and set to send and receive: the upload command has nothing left to do for it, so the menu does not
        // offer it. A folder that is shared but receive-only is different: «Загрузить на сервер» turns it into send and receive.
        // Without a Syncthing config (state restored from the manifest while Syncthing is unreachable) the folder counts as uploading.
        internal bool Uploads { get { return !ServerOnly && Kind != DiskExplorerKind.Local && (Config == null || Json.Str(Config, "type") == "sendreceive"); } }
        internal string Tooltip
        {
            get {
                switch (Kind) {
                    case DiskExplorerKind.ServerOnly: return DiskMenu.ServerOnlyHint;
                    case DiskExplorerKind.Synced: return "Синхронизировано с сервером";
                    case DiskExplorerKind.Syncing: return "Синхронизируется: " + Percent + "%";
                    case DiskExplorerKind.Paused: return "Синхронизация приостановлена";
                    case DiskExplorerKind.Offline: return "Нет соединения с сервером";
                    case DiskExplorerKind.Error: return "Ошибка синхронизации" + (Detail.Length > 0 ? ": " + Detail : "");
                    case DiskExplorerKind.LocalChanges: return "Есть локальные изменения. Загрузите их на сервер перед освобождением места";
                    case DiskExplorerKind.Unavailable: return "Локальный Syncthing недоступен";
                    case DiskExplorerKind.ServerRemoved: return "Удалена на сервере, локальная копия сохранена";
                    default: return "Ожидается подтверждение Syncthing";
                }
            }
        }
    }
    internal sealed class DiskSnapshot
    {
        internal readonly List<DiskFolderState> Folders = new List<DiskFolderState>();
        internal bool Connected;
        internal static double Number(Dictionary<string, object> m, string key)
        { double n; return double.TryParse(Json.Str(m, key), NumberStyles.Float, CultureInfo.InvariantCulture, out n) ? n : 0; }
        // Сервер снял папку: он на связи, но больше ею не делится (remoteState=notSharing). У Syncthing точно так же выглядит новая папка,
        // которую сервер ещё не принял, поэтому различает их только память «сервер эту папку уже подтверждал» (DiskConfirmedFolders).
        internal static bool RemovedByServer(Dictionary<string, object> remote, bool connected, bool confirmedBefore)
        { return connected && confirmedBefore && Json.Str(remote, "remoteState") == "notSharing"; }
        // Сервер подтверждает папку: делится ею (valid) или держит на паузе (paused).
        internal static bool ConfirmedByServer(Dictionary<string, object> remote)
        { string state = Json.Str(remote, "remoteState"); return state == "valid" || state == "paused"; }
        internal static DiskFolderState Status(DiskFolderState row, Dictionary<string, object> local, Dictionary<string, object> remote, bool connected, bool confirmedBefore = false)
        {
            row.Detail = Json.Str(local, "error");
            string state = Json.Str(local, "state");
            double total = Number(local, "globalBytes"), need = Number(local, "needBytes");
            double localPercent = total > 0 ? 100 * Math.Max(0, total - need) / total : Number(local, "needTotalItems") > 0 ? 0 : 100;
            double remotePercent = remote.ContainsKey("completion") ? Number(remote, "completion") : 0;
            row.Percent = (int)Math.Max(0, Math.Min(100, Math.Floor(Math.Min(localPercent, remotePercent))));
            if (row.Paused || state == "paused" || Json.Str(remote, "remoteState") == "paused") row.Kind = DiskExplorerKind.Paused;
            else if (RemovedByServer(remote, connected, confirmedBefore)) { row.Kind = DiskExplorerKind.ServerRemoved; row.Detail = ""; }
            else if (state == "error" || row.Detail.Length > 0 || Number(local, "pullErrors") > 0) row.Kind = DiskExplorerKind.Error;
            else if (Number(local, "receiveOnlyTotalItems") > 0 || Number(local, "receiveOnlyChangedBytes") > 0) { row.Kind = DiskExplorerKind.LocalChanges; row.Detail = "Есть локальные изменения"; }
            else if (!connected) row.Kind = DiskExplorerKind.Offline;
            else if (state.Length == 0 || !new[] { "needBytes", "needTotalItems", "globalBytes" }.All(local.ContainsKey) ||
                !new[] { "completion", "needItems", "needBytes", "needDeletes", "remoteState" }.All(remote.ContainsKey)) row.Kind = DiskExplorerKind.Pending;
            else if (Json.Str(remote, "remoteState") != "valid" || !new[] { "idle", "syncing", "sync-preparing", "sync-waiting", "scanning", "scan-waiting", "cleaning", "clean-waiting" }.Contains(state)) row.Kind = DiskExplorerKind.Pending;
            else if (state == "idle" && row.Percent == 100 && Number(local, "needTotalItems") == 0 && Number(local, "needBytes") == 0 &&
                Number(remote, "needItems") == 0 && Number(remote, "needBytes") == 0 && Number(remote, "needDeletes") == 0 && Json.Str(remote, "remoteState") == "valid") row.Kind = DiskExplorerKind.Synced;
            else { row.Kind = DiskExplorerKind.Syncing; row.Percent = Math.Min(99, row.Percent); }
            return row;
        }
    }
    // Папки, которые сервер уже подтверждал: id -> «сервер ими делился». Хранится в диске программы (explorer-confirmed.json) и привязано к серверу.
    // Папка с remoteState=notSharing, которой в памяти нет, ещё не принята сервером («ожидает»); которая есть — снята сервером.
    internal static class DiskConfirmedFolders
    {
        static readonly object Gate = new object();
        static string FileOf(string diskHome) { return System.IO.Path.Combine(diskHome, "explorer-confirmed.json"); }
        static HashSet<string> Read(string diskHome, string peer)
        {
            var known = new HashSet<string>(StringComparer.Ordinal);
            try {
                string file = FileOf(diskHome);
                if (!File.Exists(file)) return known;
                var data = Json.Read(file);
                if (Json.Str(data, "peer") == peer) foreach (string id in Json.Strings(Json.Get(data, "folders"))) known.Add(id);
            } catch (Exception) { known.Clear(); } // Нечитаемая память = пустая: папка просто покажется как ожидающая, не как ошибка.
            return known;
        }
        internal static HashSet<string> Load(string diskHome, string peer) { lock (Gate) return Read(diskHome, peer); }
        // configured: папки, которыми компьютер делится с сервером (остальные забываются); now: подтверждённые сервером сейчас.
        // Возвращает память после обновления. Если записать её не удалось, она живёт только до перезапуска.
        internal static HashSet<string> Update(string diskHome, string peer, IEnumerable<string> configured, IEnumerable<string> now)
        {
            lock (Gate) {
                var wanted = new HashSet<string>(configured, StringComparer.Ordinal);
                var before = Read(diskHome, peer); var known = new HashSet<string>(before, StringComparer.Ordinal);
                known.IntersectWith(wanted); foreach (string id in now) if (wanted.Contains(id)) known.Add(id);
                if (!known.SetEquals(before)) {
                    try { Json.Write(FileOf(diskHome), new Dictionary<string, object> { { "peer", peer }, { "folders", known.OrderBy(i => i, StringComparer.Ordinal).ToArray() } }); }
                    catch (Exception e) when (e is IOException || e is UnauthorizedAccessException) { }
                }
                return known;
            }
        }
    }
    internal sealed class DiskShellRequest
    {
        internal string Action, Path;
        internal static DiskShellRequest Parse(string[] args)
        {
            int at = Array.IndexOf(args, "--disk-shell");
            if (at < 0) return null;
            if (at + 2 >= args.Length || !new[] { "download", "keep-server", "add" }.Contains(args[at + 1])) throw new ArgumentException("Неизвестная команда Диска");
            return new DiskShellRequest { Action = args[at + 1], Path = DiskPaths.Full(args[at + 2]) };
        }
    }
    internal static class DiskPaths
    {
        internal static bool ValidName(string name)
        {
            return !string.IsNullOrWhiteSpace(name) && name != "." && name != ".." && name.TrimEnd(' ', '.') == name &&
                !name.Any(c => c < 32 || "<>:\"/\\|?*".IndexOf(c) >= 0) &&
                !Regex.IsMatch(name, @"^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])($|\.)", RegexOptions.IgnoreCase);
        }
        internal static string Full(string path)
        {
            if (string.IsNullOrWhiteSpace(path) || path.IndexOfAny(new[] { '"', '\r', '\n', '\0' }) >= 0 || !System.IO.Path.IsPathRooted(path) ||
                path.StartsWith(@"\\?\") || path.StartsWith(@"\\.\")) throw new IOException("Нужен обычный абсолютный путь к папке");
            string full;
            try { full = System.IO.Path.GetFullPath(path); }
            catch (Exception e) when (e is ArgumentException || e is NotSupportedException) { throw new IOException("Не удалось разрешить путь папки", e); }
            return full == System.IO.Path.GetPathRoot(full) ? full : full.TrimEnd(System.IO.Path.DirectorySeparatorChar, System.IO.Path.AltDirectorySeparatorChar);
        }
        internal static bool TryFull(string path, out string full)
        { try { full = Full(path); return true; } catch (IOException) { full = null; return false; } }
        internal static bool Overlaps(string path, string configured)
        { string full; return TryFull(configured, out full) && (Within(path, full) || Within(full, path)); }
        internal static bool Same(string a, string b) { return string.Equals(Full(a), Full(b), StringComparison.OrdinalIgnoreCase); }
        internal static bool Within(string path, string parent)
        { return Same(path, parent) || Full(path).StartsWith(Full(parent).TrimEnd(System.IO.Path.DirectorySeparatorChar) + System.IO.Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase); }
        internal static void Plain(string path)
        {
            for (string p = System.IO.Path.GetFullPath(path); !string.IsNullOrEmpty(p); p = System.IO.Path.GetDirectoryName(p))
                if ((Directory.Exists(p) || File.Exists(p)) && (File.GetAttributes(p) & FileAttributes.ReparsePoint) != 0) throw new IOException("Папка или её родитель является ссылкой");
        }
        internal static void Available(string path, string root, IEnumerable<DiskFolderState> configured)
        {
            Plain(path);
            if (Same(path, root) || Within(root, path) || Same(path, System.IO.Path.GetPathRoot(path))) throw new IOException("Нельзя подключить корень диска или родителя Disk");
            if (File.Exists(path)) throw new IOException("Путь занят файлом");
            foreach (var row in configured.Where(f => !f.ServerOnly))
                if (Within(path, row.Path) || Within(row.Path, path)) throw new IOException("Путь пересекается с папкой Syncthing");
        }
    }
}
