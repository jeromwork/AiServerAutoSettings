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
        internal bool Truncated;
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
        DiskChoice applied; DiskTreeSelection appliedSelection;
        string[] manualPaths;
        Dictionary<string, string> manualDirections;
        readonly HashSet<string> excludedProjects = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        readonly List<DiskExternalChoice> removedExternal = new List<DiskExternalChoice>();
        readonly Dictionary<string, string> externalDirections = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        readonly Dictionary<string, string> externalStates = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        internal IEnumerable<DiskExternalChoice> ExternalRows { get { return External.Concat(removedExternal); } }
        internal DiskFoldersModel(DiskChoice choice, DiskChoice appliedChoice = null, IEnumerable<string> excluded = null)
        {
            Mode = choice.All ? DiskFoldersMode.All : choice.Chosen && choice.Folders.Count == 0 && choice.External.Count == 0 ? DiskFoldersMode.None : DiskFoldersMode.Selected;
            Selection = new DiskTreeSelection(choice.Folders.Select(f => f.Path));
            if (excluded != null) excludedProjects.UnionWith(excluded);
            SetApplied(appliedChoice);
            foreach (var f in choice.Folders) directions[DiskChoice.Project(f.Path)] = choice.DirectionOf(f.Path);
            foreach (var e in choice.External) External.Add(Copy(e));
        }
        static DiskExternalChoice Copy(DiskExternalChoice e) { return new DiskExternalChoice { Path = e.Path, Remote = e.Remote, Direction = e.Direction }; }
        internal static string DirectionText(string value) { return value == DiskChoice.Send ? "Только отправлять на сервер" : value == DiskChoice.Receive ? "Только забирать с сервера" : "В обе стороны"; }
        internal DiskExternalChoice ExternalFor(string path) { return ExternalRows.FirstOrDefault(e => string.Equals(e.Remote, DiskChoice.Project(path), StringComparison.OrdinalIgnoreCase)); }
        internal string DirectionOf(string path) { var entry = ExternalFor(path); if (entry != null) return entry.Direction; if (Mode == DiskFoldersMode.All) return DiskChoice.Both; string d; return directions.TryGetValue(DiskChoice.Project(path), out d) ? d : DiskChoice.Both; }
        // Presence means an entry was observed, not that its contents have finished transferring.
        // A truncated union cannot establish absence on the other side. Direction must never promise a forbidden transfer.
        internal static string FolderStatus(bool isChecked, string presence, bool isApplied, string direction, bool truncated, bool wasChecked, string state = "")
        {
            if (!isChecked && wasChecked) return "Перестанет синхронизироваться; файлы на компьютере останутся";
            if (!isChecked) {
                if (presence == "both") return "Не синхронизируется; копии на компьютере и сервере";
                if (presence == "local" && !truncated) return "🖥 Только на этом компьютере (не синхронизируется)";
                if (presence == "server" && !truncated) return "☁ Только на сервере";
            }
            if (isChecked && isApplied && state == "syncing") return direction == DiskChoice.Send ? "⟳ Отправляется" : "⟳ Скачивается";
            if (presence == "both") return "✓ На компьютере и на сервере";
            if (truncated) return presence == "local" ? "Обнаружена на компьютере; список неполный" : presence == "server" ? "Обнаружена на сервере; список неполный" : "Наличие не проверено; список неполный";
            if (isChecked && presence == "server") return direction == DiskChoice.Send ? "☁ На сервере; получение отключено" : isApplied ? "⟳ Скачивается" : "↓ Будет скачана";
            if (isChecked && presence == "local") return direction == DiskChoice.Receive ? "🖥 На компьютере; отправка отключена" : isApplied ? "⟳ Отправляется" : "↑ Будет отправлена";
            return "Наличие не проверено";
        }
        internal static string DirectionHint(string direction) { return direction == DiskChoice.Receive ? "↓ только забирать" : direction == DiskChoice.Send ? "↑ только отправлять" : ""; }
        internal string Status(string path)
        {
            var entry = ExternalFor(path); if (entry != null) return ExternalStatus(entry);
            DiskFolderInfo info; if (!Items.TryGetValue(path, out info)) return "Наличие не проверено";
            bool current = Includes(path) || Partial(path), confirmed = applied != null && (applied.All && !excludedProjects.Contains(DiskChoice.Project(path)) || appliedSelection.Includes(path)) && applied.DirectionOf(path) == DirectionOf(path);
            return FolderStatus(current, info.Presence, confirmed, DirectionOf(path), info.Truncated, WasChecked(path));
        }
        internal bool CanRevert(string path)
        {
            DiskFolderInfo info; string top = DiskChoice.Project(path);
            return ExternalFor(top) == null && (Includes(top) || Partial(top)) && DirectionOf(top) == DiskChoice.Receive && Items.TryGetValue(top, out info) && info.LocalChanges > 0;
        }
        void SetApplied(DiskChoice choice)
        {
            // Keep an immutable baseline, independent from pending checkbox/direction edits.
            applied = choice == null ? null : DiskChoice.FromProfile(choice.WriteTo(new Dictionary<string, object>(), ""));
            appliedSelection = new DiskTreeSelection(applied == null ? new string[0] : applied.Folders.Select(f => f.Path));
        }
        bool WasChecked(string path)
        {
            return applied != null && (applied.All && !excludedProjects.Contains(DiskChoice.Project(path)) || appliedSelection.Includes(path) || appliedSelection.Partial(path));
        }
        internal void MarkApplied(IEnumerable<string> excluded = null)
        {
            var choice = ToChoice();
            if (excluded != null) { excludedProjects.Clear(); excludedProjects.UnionWith(excluded); }
            else {
                foreach (var entry in removedExternal)
                    if (applied != null && applied.External.Any(e => string.Equals(e.Remote, entry.Remote, StringComparison.OrdinalIgnoreCase)) || externalStates.ContainsKey(entry.Path)) excludedProjects.Add(entry.Remote);
                foreach (var folder in choice.Folders) excludedProjects.Remove(DiskChoice.Project(folder.Path));
            }
            SetApplied(choice);
            removedExternal.Clear();
        }
        internal bool Includes(string path)
        {
            var entry = ExternalFor(path); if (entry != null) return IncludesExternal(entry);
            return Mode == DiskFoldersMode.All ? !excludedProjects.Contains(DiskChoice.Project(path)) : Mode == DiskFoldersMode.Selected && Selection.Includes(path);
        }
        internal bool Partial(string path) { return ExternalFor(path) == null && Mode == DiskFoldersMode.Selected && Selection.Partial(path); }
        internal void Level(string parent, Dictionary<string, object> union)
        {
            var rows = Json.Array(Json.Get(union, "rows")).Select(Json.Map).ToArray();
            var children = new List<string>();
            foreach (var r in rows) {
                string path = Json.Str(r, "path"); int slash = path.LastIndexOf('/');
                if ((slash < 0 ? "" : path.Substring(0, slash)) != parent) throw new InvalidDataException("Сервер вернул другой уровень папки");
                Items[path] = new DiskFolderInfo { Path = path, Presence = Json.Str(r, "presence"), Kind = Json.Str(r, "kind"), LocalChanges = Json.Int(r, "localChanges", 0), Truncated = Json.Bool(union, "truncated") };
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
            if (!rootLoaded || rootIncomplete) throw new IOException("Для изменения общего выбора загрузите полный список папок или снимите «Все папки сервера, включая новые» и отметьте нужные.");
            ClearSelection(); directions.Clear();
            foreach (string path in roots) if (ExternalFor(path) == null && !excludedProjects.Contains(path)) Selection.Set(path, true);
        }
        internal void SetMode(DiskFoldersMode mode)
        {
            if (mode == Mode) return;
            if (mode == DiskFoldersMode.All) {
                manualPaths = Selection.Paths;
                manualDirections = new Dictionary<string, string>(directions, StringComparer.OrdinalIgnoreCase);
            }
            if (Mode == DiskFoldersMode.All && mode == DiskFoldersMode.Selected) {
                if (manualPaths != null) {
                    ClearSelection(); foreach (string path in manualPaths) Selection.Set(path, true);
                    directions.Clear(); foreach (var pair in manualDirections) directions[pair.Key] = pair.Value;
                } else if (rootLoaded && !rootIncomplete) SelectAllLoaded();
                else { ClearSelection(); directions.Clear(); }
            }
            Mode = mode;
            if (mode == DiskFoldersMode.None) { ClearSelection(); External.Clear(); manualPaths = null; manualDirections = null; }
        }
        // Pane membership is based on observations and the pending choice, never on filesystem guesses.
        internal bool OnComputer(string path)
        {
            DiskFolderInfo info;
            return ExternalFor(path) == null && (Includes(path) || Partial(path) || Items.TryGetValue(path, out info) && (info.Presence == "local" || info.Presence == "both"));
        }
        internal bool OnServer(string path)
        {
            DiskFolderInfo info;
            return Items.TryGetValue(path, out info) && (info.Presence == "server" || info.Presence == "both");
        }
        internal void TakeToComputer(string path) { ChooseTransfer(path, DiskChoice.Send); }
        internal void SendToServer(string path) { ChooseTransfer(path, DiskChoice.Receive); }
        void ChooseTransfer(string path, string blockedDirection)
        {
            if (string.IsNullOrEmpty(path)) throw new IOException("Выберите папку");
            Set(path, true);
            // A deliberate transfer must enable that direction. Keep other existing policies.
            if (DirectionOf(path) == blockedDirection) SetDirection(path, DiskChoice.Both);
        }
        internal void StopSynchronizing(string path)
        {
            if (string.IsNullOrEmpty(path)) throw new IOException("Выберите папку");
            Set(path, false);
        }
        internal void Set(string path, bool value)
        {
            var entry = ExternalFor(path); if (entry != null) { SetExternal(entry, value); return; }
            if (Mode == DiskFoldersMode.All) { if (value && Includes(path)) return; SelectAllLoaded(); }
            Selection.Set(path, value); Mode = DiskFoldersMode.Selected;
        }
        internal void SetDirection(string path, string direction)
        {
            if (!DiskChoice.Directions.Contains(direction)) throw new IOException("Выберите направление передачи файлов");
            if (!Includes(path) && !Partial(path)) throw new IOException("Сначала отметьте папку");
            var entry = ExternalFor(path); if (entry != null) { entry.Direction = direction; return; }
            if (Mode == DiskFoldersMode.All && direction != DirectionOf(path)) { SelectAllLoaded(); Mode = DiskFoldersMode.Selected; }
            directions[DiskChoice.Project(path)] = direction;
        }
        internal void AddExternal(string path, string remote, string direction)
        {
            path = (path ?? "").Trim(); remote = (remote ?? "").Trim();
            if (path.Length == 0) throw new IOException("Выберите папку на компьютере");
            if (remote.Length == 0 || remote == "." || remote == ".." || remote.Any(c => !(char.IsLetterOrDigit(c) || c == ' ' || c == '.' || c == '_' || c == '-')))
                throw new IOException("В имени на сервере допустимы буквы, цифры, пробел, точка, _ и -");
            if (ExternalRows.Any(e => string.Equals(e.Path.TrimEnd('\\', '/'), path.TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase))) throw new IOException("Эта папка уже есть в списке");
            if (ExternalRows.Any(e => string.Equals(e.Remote, remote, StringComparison.OrdinalIgnoreCase))) throw new IOException("Это имя на сервере уже занято другой папкой из списка");
            if (!DiskChoice.Directions.Contains(direction)) throw new IOException("Выберите направление передачи файлов");
            External.Add(new DiskExternalChoice { Path = path, Remote = remote, Direction = direction });
            if (Mode == DiskFoldersMode.None) Mode = DiskFoldersMode.Selected;
        }
        internal bool IncludesExternal(DiskExternalChoice entry) { return External.Contains(entry); }
        internal void SetExternal(DiskExternalChoice entry, bool value)
        {
            if (value == IncludesExternal(entry)) return;
            if (value) { removedExternal.Remove(entry); External.Add(entry); if (Mode == DiskFoldersMode.None) Mode = DiskFoldersMode.Selected; }
            else { External.Remove(entry); removedExternal.Add(entry); }
        }
        internal void ExternalState(DiskExternalChoice entry, string state, string observedDirection = null) { externalStates[entry.Path] = state; externalDirections[entry.Path] = observedDirection ?? entry.Direction; }
        internal string ExternalStatus(DiskExternalChoice entry)
        {
            if (!IncludesExternal(entry)) return FolderStatus(false, "", false, entry.Direction, false,
                applied != null && applied.External.Any(e => string.Equals(e.Remote, entry.Remote, StringComparison.OrdinalIgnoreCase)));
            string state, observedDirection; externalStates.TryGetValue(entry.Path, out state);
            if (!externalDirections.TryGetValue(entry.Path, out observedDirection) || observedDirection != entry.Direction) state = "";
            bool confirmed = applied != null && applied.External.Any(e => e.Path == entry.Path && e.Remote == entry.Remote && e.Direction == entry.Direction);
            if (state == "syncing") return FolderStatus(true, "", true, entry.Direction, false, false, state);
            if (state == "paused") return "Синхронизация приостановлена";
            if (state == "detached") return "Будет подключена к синхронизации";
            if (!confirmed && string.IsNullOrEmpty(state)) return "Будет подключена к синхронизации";
            return state == "idle" ? "✓ Подключена к синхронизации" : "Подключена; состояние передачи неизвестно";
        }
        internal DiskChoice ToChoice()
        {
            var choice = new DiskChoice { Chosen = true, All = Mode == DiskFoldersMode.All };
            if (Mode == DiskFoldersMode.Selected) foreach (string p in Selection.Paths.Where(p => ExternalFor(p) == null)) choice.Folders.Add(new DiskFolderChoice { Path = p, Direction = DirectionOf(p) });
            foreach (var e in External) choice.External.Add(Copy(e));
            return choice;
        }
    }
}
