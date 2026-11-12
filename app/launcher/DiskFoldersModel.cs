using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace RemoteAgents.Launcher
{
    internal enum DiskFoldersMode { All, Selected, None }
    internal sealed class DiskFolderInfo
    {
        internal string Path, Presence, Kind;
        internal int LocalChanges;
    }
    // Pure presentation state. Unloaded selections and project directions survive a lazy tree refresh.
    internal sealed class DiskFoldersModel
    {
        internal DiskFoldersMode Mode { get; private set; }
        internal DiskTreeSelection Selection { get; private set; }
        internal readonly List<DiskExternalChoice> External = new List<DiskExternalChoice>();
        internal readonly Dictionary<string, DiskFolderInfo> Items = new Dictionary<string, DiskFolderInfo>(StringComparer.Ordinal);
        readonly Dictionary<string, string> directions = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        string[] roots = new string[0]; bool rootLoaded, rootIncomplete;
        internal DiskFoldersModel(DiskChoice choice)
        {
            Mode = choice.All ? DiskFoldersMode.All : choice.Chosen && choice.Folders.Count == 0 && choice.External.Count == 0 ? DiskFoldersMode.None : DiskFoldersMode.Selected;
            Selection = new DiskTreeSelection(choice.Folders.Select(f => f.Path));
            foreach (var f in choice.Folders) directions[DiskChoice.Project(f.Path)] = choice.DirectionOf(f.Path);
            foreach (var e in choice.External) External.Add(Copy(e));
        }
        static DiskExternalChoice Copy(DiskExternalChoice e) { return new DiskExternalChoice { Path = e.Path, Remote = e.Remote, Direction = e.Direction }; }
        internal static string DirectionText(string value) { return value == DiskChoice.Send ? "Только отправлять на сервер" : value == DiskChoice.Receive ? "Только забирать с сервера" : "В обе стороны"; }
        internal string DirectionOf(string path) { if (Mode == DiskFoldersMode.All) return DiskChoice.Both; string d; return directions.TryGetValue(DiskChoice.Project(path), out d) ? d : DiskChoice.Both; }
        internal bool Includes(string path) { return Mode == DiskFoldersMode.All || Mode == DiskFoldersMode.Selected && Selection.Includes(path); }
        internal bool Partial(string path) { return Mode == DiskFoldersMode.Selected && Selection.Partial(path); }
        internal void Level(string parent, Dictionary<string, object> union)
        {
            var rows = Json.Array(Json.Get(union, "rows")).Select(Json.Map).ToArray();
            var children = new List<string>();
            foreach (var r in rows) {
                string path = Json.Str(r, "path"); int slash = path.LastIndexOf('/');
                if ((slash < 0 ? "" : path.Substring(0, slash)) != parent) throw new InvalidDataException("Сервер вернул другой уровень папки");
                Items[path] = new DiskFolderInfo { Path = path, Presence = Json.Str(r, "presence"), Kind = Json.Str(r, "kind"), LocalChanges = Json.Int(r, "localChanges", 0) };
                if (Mode != DiskFoldersMode.All && parent.Length == 0 && !directions.ContainsKey(path) && DiskChoice.Directions.Contains(Json.Str(r, "direction"))) directions[path] = Json.Str(r, "direction");
                if (parent.Length > 0 || Json.Str(r, "kind") != "file") children.Add(path);
            }
            bool incomplete = Json.Bool(union, "truncated");
            Selection.Level(parent, children, incomplete);
            if (parent.Length == 0) { roots = children.ToArray(); rootLoaded = true; rootIncomplete = incomplete; }
        }
        void ClearSelection() { foreach (string p in Selection.Paths) Selection.Set(p, false); }
        void SelectAllLoaded()
        {
            if (!rootLoaded || rootIncomplete) throw new IOException("Для изменения общего выбора загрузите полный список папок или выберите «Выбрать папки» и отметьте нужные.");
            foreach (string path in roots) Selection.Set(path, true);
        }
        internal void SetMode(DiskFoldersMode mode)
        {
            if (mode == Mode) return;
            // Explicit selective mode on an incomplete inventory starts empty; never silently discards hidden folders.
            if (Mode == DiskFoldersMode.All && mode == DiskFoldersMode.Selected) {
                if (rootLoaded && !rootIncomplete) SelectAllLoaded();
                else ClearSelection();
            }
            Mode = mode;
            if (mode == DiskFoldersMode.All) directions.Clear();
            if (mode == DiskFoldersMode.None) { ClearSelection(); External.Clear(); }
        }
        internal void Set(string path, bool value)
        {
            if (Mode == DiskFoldersMode.All) { if (value) return; SelectAllLoaded(); }
            Selection.Set(path, value); Mode = DiskFoldersMode.Selected;
        }
        internal void SetDirection(string path, string direction)
        {
            if (!DiskChoice.Directions.Contains(direction)) throw new IOException("Выберите направление передачи файлов");
            if (!Includes(path) && !Partial(path)) throw new IOException("Сначала отметьте папку");
            if (Mode == DiskFoldersMode.All && direction != DirectionOf(path)) { SelectAllLoaded(); Mode = DiskFoldersMode.Selected; }
            directions[DiskChoice.Project(path)] = direction;
        }
        internal void AddExternal(string path, string remote, string direction)
        {
            path = (path ?? "").Trim(); remote = (remote ?? "").Trim();
            if (path.Length == 0) throw new IOException("Выберите папку на компьютере");
            if (remote.Length == 0 || remote == "." || remote == ".." || remote.Any(c => !(char.IsLetterOrDigit(c) || c == ' ' || c == '.' || c == '_' || c == '-')))
                throw new IOException("В имени на сервере допустимы буквы, цифры, пробел, точка, _ и -");
            if (External.Any(e => string.Equals(e.Path.TrimEnd('\\', '/'), path.TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase))) throw new IOException("Эта папка уже есть в списке");
            if (External.Any(e => string.Equals(e.Remote, remote, StringComparison.OrdinalIgnoreCase))) throw new IOException("Это имя на сервере уже занято другой папкой из списка");
            if (!DiskChoice.Directions.Contains(direction)) throw new IOException("Выберите направление передачи файлов");
            External.Add(new DiskExternalChoice { Path = path, Remote = remote, Direction = direction });
            if (Mode == DiskFoldersMode.None) Mode = DiskFoldersMode.Selected;
        }
        internal DiskChoice ToChoice()
        {
            var choice = new DiskChoice { Chosen = true, All = Mode == DiskFoldersMode.All };
            if (Mode == DiskFoldersMode.Selected) foreach (string p in Selection.Paths) choice.Folders.Add(new DiskFolderChoice { Path = p, Direction = DirectionOf(p) });
            foreach (var e in External) choice.External.Add(Copy(e));
            return choice;
        }
    }
}
