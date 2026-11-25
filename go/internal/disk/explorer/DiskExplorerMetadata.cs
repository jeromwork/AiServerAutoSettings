using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace RemoteAgents.Launcher
{
    internal interface IDiskExplorerFileSystem
    {
        bool DirectoryExists(string path);
        bool FileExists(string path);
        FileAttributes Attributes(string path);
        void Attributes(string path, FileAttributes value);
        IEnumerable<string> Entries(string path);
        string Read(string path);
        void Write(string path, string content);
        void CreateDirectory(string path);
        void DeleteFile(string path);
        void DeleteDirectory(string path);
    }
    internal interface IDiskExplorerIcons
    {
        string PathFor(DiskExplorerKind kind);
        // The program's own icon (the one in the tray) as a file: our Explorer menu items use it.
        string ApplicationPath();
    }
    // The icon files of the Disk. All of them are finished .ico files built into the program (the state icons from app/launcher/icons,
    // the program's icon from app/launcher/app.ico; build/make-state-icons.py and make-app-icon.py draw them) and written to a
    // directory of the user as they are. Nothing is drawn at run time.
    internal static class DiskIconFile
    {
        // app.ico is built into the program twice: as the program's icon (what Explorer shows for the EXE) and as this resource.
        internal const string ApplicationIconResource = "RemoteAgents.App.ico";
        internal static string StateIconResource(DiskExplorerKind kind) { return "RemoteAgents.Icons." + kind + ".ico"; }
        // Explorer remembers an icon by the name of its file, so a new picture needs a new name: the icon revision is part of it
        // (DiskExplorerService.IconRevision). Revision 1, the folder icon with a badge drawn over it, has no marker in the name.
        internal static string StateIconFile(DiskExplorerKind kind) { return DiskExplorerService.Owner + ".r" + DiskExplorerService.IconRevision + "." + kind + ".ico"; }
        // Uninstall: our icon files of every revision (and the application icon); anything else in the directory stays.
        internal static void Cleanup(string directory)
        {
            if (!Directory.Exists(directory)) return;
            var ours = new Regex("^" + Regex.Escape(DiskExplorerService.Owner) + @"\.((r\d+\.)?(" + string.Join("|", Enum.GetNames(typeof(DiskExplorerKind))) + @")|App)\.ico$");
            foreach (string path in Directory.GetFiles(directory))
                if (ours.IsMatch(Path.GetFileName(path)) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) == 0) File.Delete(path);
        }
        internal static void ExportStateIcon(DiskExplorerKind kind, string path) { Export(StateIconResource(kind), path); }
        internal static void ExportApplicationIcon(string path) { Export(ApplicationIconResource, path); }
        // The built-in file, byte for byte. An existing file is kept: Explorer may be reading it, and its name says which picture it is.
        static void Export(string resource, string path)
        {
            if (File.Exists(path)) return;
            using (var source = typeof(DiskIconFile).Assembly.GetManifestResourceStream(resource)) {
                if (source == null) throw new IOException("В программе нет файла значка " + resource);
                using (var copy = new MemoryStream()) {
                    source.CopyTo(copy);
                    string temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
                    try {
                        using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None)) stream.Write(copy.GetBuffer(), 0, (int)copy.Length);
                        if (!File.Exists(path)) File.Move(temp, path);
                    } finally { if (File.Exists(temp)) File.Delete(temp); }
                }
            }
        }
    }
    // The icons of the Disk in a directory of the user (%LOCALAPPDATA%\RemoteDisk\explorer-icons): the state icons, whose paths go to
    // desktop.ini of the folders, and the program's icon for the menu items.
    internal sealed class DiskExplorerIcons : IDiskExplorerIcons
    {
        readonly string directory;
        internal DiskExplorerIcons(string directory) { this.directory = Path.GetFullPath(directory); }
        public string PathFor(DiskExplorerKind kind)
        {
            Directory.CreateDirectory(directory);
            string path = Path.Combine(directory, DiskIconFile.StateIconFile(kind));
            DiskIconFile.ExportStateIcon(kind, path);
            return path;
        }
        public string ApplicationPath()
        {
            Directory.CreateDirectory(directory);
            string path = Path.Combine(directory, DiskExplorerService.ApplicationIconFile);
            DiskIconFile.ExportApplicationIcon(path);
            return path;
        }
    }
    internal interface IDiskExplorerNotifier { void Changed(string path); }
    internal sealed class DiskExplorerFileSystem : IDiskExplorerFileSystem
    {
        public bool DirectoryExists(string path) { return Directory.Exists(path); }
        public bool FileExists(string path) { return File.Exists(path); }
        public FileAttributes Attributes(string path) { return File.GetAttributes(path); }
        public void Attributes(string path, FileAttributes value) { File.SetAttributes(path, value); }
        public IEnumerable<string> Entries(string path) { return Directory.EnumerateFileSystemEntries(path); }
        public string Read(string path) { return File.ReadAllText(path); }
        public void Write(string path, string content) { File.WriteAllText(path, content, new UnicodeEncoding(false, true)); }
        public void CreateDirectory(string path) { Directory.CreateDirectory(path); }
        public void DeleteFile(string path) { File.Delete(path); }
        public void DeleteDirectory(string path) { Directory.Delete(path, false); }
    }
    internal sealed class DiskExplorerService
    {
        internal const string Owner = "RemoteAgents.Disk.v2";
        internal const string ApplicationIconFile = Owner + ".App.ico";
        // The look of the state icons. Raise it when app/launcher/icons change: the new files get new names (see DiskIconFile).
        internal const int IconRevision = 2;
        readonly IDiskExplorerFileSystem fs;
        readonly IDiskExplorerIcons icons;
        readonly IDiskExplorerNotifier notifier;
        readonly Action<string> log;
        internal DiskExplorerService(IDiskExplorerFileSystem fs, IDiskExplorerIcons icons, IDiskExplorerNotifier notifier, Action<string> log)
        { this.fs = fs; this.icons = icons; this.notifier = notifier; this.log = log ?? delegate { }; }
        internal string ApplicationIcon() { return icons.ApplicationPath(); }
        // Only our own empty placeholders and desktop.ini are managed. User metadata always wins.
        internal void Reconcile(string root, IEnumerable<DiskFolderState> folders)
        {
            var rows = folders.ToArray();
            ClassifyLocalCopies(rows);
            if (!fs.DirectoryExists(root) && !fs.FileExists(root) && !HasReparseAncestor(root) && rows.Any(f => f.ServerOnly)) fs.CreateDirectory(root);
            if (!fs.DirectoryExists(root) || HasReparseAncestor(root)) return;
            foreach (var row in rows.Where(f => f.Kind != DiskExplorerKind.Local)) {
                try {
                    try { DiskPaths.Location(row.Path, root); } catch (IOException) { CleanupFolder(row.Path); continue; }
                    if (fs.FileExists(row.Path) || HasReparseAncestor(row.Path)) continue;
                    bool created = !fs.DirectoryExists(row.Path);
                    if (created) {
                        if (!row.ServerOnly || row.Kind != DiskExplorerKind.ServerOnly) continue;
                        fs.CreateDirectory(row.Path);
                    }
                    var metadata = ReadOwned(row.Path);
                    string ini = Path.Combine(row.Path, "desktop.ini");
                    if ((fs.FileExists(ini) || fs.DirectoryExists(ini)) && metadata == null) continue;
                    bool placeholder = row.ServerOnly && !UserEntries(row.Path).Any() && (created || Flag(metadata, "Placeholder"));
                    // A local copy awaits an explicit merge; its files are never an error or an empty placeholder.
                    if (row.ServerOnly && !placeholder && row.Kind != DiskExplorerKind.LocalCopy) continue;
                    Apply(row.Path, row.Kind, row.Tooltip, metadata, placeholder, created);
                } catch (Exception e) { Failure(e); }
            }
            var wanted = new HashSet<string>(rows.Select(f => f.Path), StringComparer.OrdinalIgnoreCase);
            foreach (var path in fs.Entries(root).ToArray()) {
                if (wanted.Contains(path)) continue;
                try { if (fs.DirectoryExists(path) && !HasReparseAncestor(path)) CleanupFolder(path, true); }
                catch (Exception e) { Failure(e); }
            }
        }
        internal void ClassifyLocalCopies(IEnumerable<DiskFolderState> rows)
        {
            foreach (var row in rows.Where(f => f.ServerOnly && (f.Kind == DiskExplorerKind.ServerOnly || f.Kind == DiskExplorerKind.LocalCopy))) {
                try {
                    if (fs.DirectoryExists(row.Path) && !HasReparseAncestor(row.Path))
                        row.Kind = IsPlaceholder(row.Path) ? DiskExplorerKind.ServerOnly : DiskExplorerKind.LocalCopy;
                    else if (!fs.FileExists(row.Path) && !HasReparseAncestor(row.Path)) row.Kind = DiskExplorerKind.ServerOnly;
                } catch (Exception e) { Failure(e); }
            }
        }
        internal bool HasReparseAncestor(string path)
        {
            for (string current = Path.GetFullPath(path); !string.IsNullOrEmpty(current); current = Path.GetDirectoryName(current))
                if ((fs.DirectoryExists(current) || fs.FileExists(current)) && (fs.Attributes(current) & FileAttributes.ReparsePoint) != 0) return true;
            return false;
        }
        internal bool MarkPlaceholder(string path)
        {
            path = Path.GetFullPath(path);
            if (fs.FileExists(path) || HasReparseAncestor(path)) return false;
            bool created = !fs.DirectoryExists(path);
            if (created) fs.CreateDirectory(path);
            var metadata = ReadOwned(path);
            string ini = Path.Combine(path, "desktop.ini");
            if (((fs.FileExists(ini) || fs.DirectoryExists(ini)) && metadata == null) || UserEntries(path).Any()) return false;
            Apply(path, DiskExplorerKind.ServerOnly, DiskMenu.ServerOnlyHint, metadata, true, created);
            return true;
        }
        internal bool IsPlaceholder(string path)
        {
            if (!fs.DirectoryExists(path) || HasReparseAncestor(path)) return false;
            var metadata = ReadOwned(path);
            return Flag(metadata, "Placeholder") && Bound(metadata, path) && !UserEntries(path).Any();
        }
        IEnumerable<string> UserEntries(string path)
        { return fs.Entries(path).Where(p => !string.Equals(Path.GetFileName(p), "desktop.ini", StringComparison.OrdinalIgnoreCase)); }
        Dictionary<string, string> ReadOwned(string path)
        {
            string ini = Path.Combine(path, "desktop.ini");
            if (!fs.FileExists(ini) || (fs.Attributes(ini) & FileAttributes.ReparsePoint) != 0) return null;
            var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase); string section = "";
            foreach (var raw in fs.Read(ini).Replace("\r", "").Split('\n')) {
                string line = raw.Trim();
                if (line.StartsWith("[") && line.EndsWith("]")) { section = line; continue; }
                int eq = line.IndexOf('=');
                if (section.Equals("[RemoteAgents]", StringComparison.OrdinalIgnoreCase) && eq > 0) values[line.Substring(0, eq).Trim()] = line.Substring(eq + 1).Trim();
            }
            string owner;
            return values.TryGetValue("Owner", out owner) && owner == Owner && values.ContainsKey("OriginalReadOnly") && (values["OriginalReadOnly"] == "0" || values["OriginalReadOnly"] == "1") ? values : null;
        }
        static bool Bound(Dictionary<string, string> metadata, string path)
        { string bound; return metadata != null && (!metadata.TryGetValue("BoundPath", out bound) || DiskPaths.Same(bound, path)); }
        static bool Flag(Dictionary<string, string> metadata, string name)
        { string value; return metadata != null && metadata.TryGetValue(name, out value) && value == "1"; }
        void Apply(string path, DiskExplorerKind kind, string tip, Dictionary<string, string> metadata, bool placeholder, bool created)
        {
            string ini = Path.Combine(path, "desktop.ini");
            bool originalReadOnly = metadata == null ? (fs.Attributes(path) & FileAttributes.ReadOnly) != 0 : Flag(metadata, "OriginalReadOnly");
            string tooltip = tip.Replace("\r", " ").Replace("\n", " ").Replace("\0", "");
            string icon = icons.PathFor(kind);
            if (icon.IndexOfAny(new[] { '\r', '\n', '"' }) >= 0) throw new IOException("Недопустимый путь значка");
            string content = "[.ShellClassInfo]\r\nIconResource=" + icon + ",0\r\nInfoTip=" + tooltip + "\r\n[RemoteAgents]\r\nOwner=" + Owner + "\r\nBoundPath=" + Path.GetFullPath(path) + "\r\nOriginalReadOnly=" + (originalReadOnly ? "1" : "0") + "\r\nPlaceholder=" + (placeholder ? "1" : "0") + "\r\nCreatedDirectory=" + ((created || Flag(metadata, "CreatedDirectory")) ? "1" : "0") + "\r\n";
            bool changed = !fs.FileExists(ini) || fs.Read(ini).Replace("\r", "") != content.Replace("\r", "");
            if (changed) {
                if (fs.FileExists(ini)) fs.Attributes(ini, FileAttributes.Normal);
                fs.Write(ini, content);
            }
            SetAttributes(ini, fs.Attributes(ini) | FileAttributes.Hidden | FileAttributes.System);
            SetAttributes(path, fs.Attributes(path) | FileAttributes.ReadOnly);
            if (changed) notifier.Changed(path);
        }
        internal void Cleanup(string root, bool removeEmptyPlaceholders = false)
        {
            if (!fs.DirectoryExists(root) || HasReparseAncestor(root)) return;
            foreach (var path in fs.Entries(root).ToArray()) {
                try { if (fs.DirectoryExists(path) && !HasReparseAncestor(path)) CleanupFolder(path, removeEmptyPlaceholders); }
                catch (Exception e) { Failure(e); }
            }
        }
        internal void CleanupFolder(string path, bool removeEmptyPlaceholder = false)
        {
            if (!fs.DirectoryExists(path) || HasReparseAncestor(path)) return;
            var metadata = ReadOwned(path);
            if (metadata == null) {
                if (fs.FileExists(Path.Combine(path, "desktop.ini")) || fs.DirectoryExists(Path.Combine(path, "desktop.ini"))) log("Проводник: чужой desktop.ini оставлен без изменений");
                return;
            }
            bool remove = removeEmptyPlaceholder && Bound(metadata, path) && Flag(metadata, "Placeholder") && Flag(metadata, "CreatedDirectory") && !UserEntries(path).Any();
            string ini = Path.Combine(path, "desktop.ini");
            FileAttributes attributes = fs.Attributes(path);
            SetAttributes(path, Flag(metadata, "OriginalReadOnly") ? attributes | FileAttributes.ReadOnly : attributes & ~FileAttributes.ReadOnly);
            fs.Attributes(ini, FileAttributes.Normal); fs.DeleteFile(ini);
            if (remove) fs.DeleteDirectory(path);
            notifier.Changed(path);
        }
        void SetAttributes(string path, FileAttributes attributes)
        { if (fs.Attributes(path) != attributes) fs.Attributes(path, attributes); }
        void Failure(Exception e)
        { log("Проводник: операция оформления не выполнена (" + e.GetType().Name + ")"); }
    }
}
