using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;

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
    // Windows icon files (.ico). The folder badges are drawn at run time (DiskExplorerIcons) and wrapped here; the program's own
    // icon is the finished file app.ico (drawn by build/make-app-icon.py) that is built into the program.
    internal static class DiskIconFile
    {
        // Folder badges: small list view, normal, large and the 256 px preview.
        internal static readonly int[] FolderSizes = { 16, 32, 48, 256 };
        // app.ico is built into the program twice: as the program's icon (what Explorer shows for the EXE) and as this resource.
        internal const string ApplicationIconResource = "RemoteAgents.App.ico";
        // Uninstall: our icon files only (one per folder state and the application icon); anything else in the directory stays.
        internal static void Cleanup(string directory)
        {
            var names = Enum.GetValues(typeof(DiskExplorerKind)).Cast<DiskExplorerKind>().Select(kind => DiskExplorerService.Owner + "." + kind + ".ico").Concat(new[] { DiskExplorerService.ApplicationIconFile });
            foreach (string name in names) {
                string path = Path.Combine(directory, name);
                if (File.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) == 0) File.Delete(path);
            }
        }
        // The icon container around ready-made PNG frames.
        internal static void Write(string path, int[] sizes, IList<byte[]> frames)
        {
            if (sizes.Length == 0 || sizes.Length != frames.Count) throw new ArgumentException("Размеры и кадры значка не совпадают");
            using (var bytes = new MemoryStream()) {
                using (var writer = new BinaryWriter(bytes)) {
                    writer.Write((ushort)0); writer.Write((ushort)1); writer.Write((ushort)sizes.Length);
                    int offset = 6 + 16 * sizes.Length;
                    for (int i = 0; i < sizes.Length; i++) {
                        writer.Write((byte)(sizes[i] == 256 ? 0 : sizes[i])); writer.Write((byte)(sizes[i] == 256 ? 0 : sizes[i]));
                        writer.Write((byte)0); writer.Write((byte)0); writer.Write((ushort)1); writer.Write((ushort)32);
                        writer.Write(frames[i].Length); writer.Write(offset); offset += frames[i].Length;
                    }
                    foreach (byte[] frame in frames) writer.Write(frame);
                }
                Save(path, bytes.ToArray());
            }
        }
        // The program's icon for the menu items: the file built into the program, byte for byte. An existing file is kept.
        internal static void ExportApplicationIcon(string path)
        {
            if (File.Exists(path)) return;
            using (var source = typeof(DiskIconFile).Assembly.GetManifestResourceStream(ApplicationIconResource)) {
                if (source == null) throw new IOException("В программе нет файла значка");
                using (var copy = new MemoryStream()) { source.CopyTo(copy); Save(path, copy.ToArray()); }
            }
        }
        // Written through a temporary file; an icon that already exists is never replaced (Explorer may be reading it).
        static void Save(string path, byte[] data)
        {
            string temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try {
                using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None)) stream.Write(data, 0, data.Length);
                if (!File.Exists(path)) File.Move(temp, path);
            } finally { if (File.Exists(temp)) File.Delete(temp); }
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
            if (!fs.DirectoryExists(root) && !fs.FileExists(root) && !HasReparseAncestor(root) && rows.Any(f => f.ServerOnly)) fs.CreateDirectory(root);
            if (!fs.DirectoryExists(root) || HasReparseAncestor(root)) return;
            foreach (var row in rows.Where(f => f.Kind != DiskExplorerKind.Local)) {
                try {
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
                    // A pending offer does not give us ownership of a pre-existing local directory.
                    if (row.ServerOnly && !placeholder) {
                        if (metadata != null) Apply(row.Path, DiskExplorerKind.Error, "В папке есть локальные файлы; папка не синхронизируется", metadata, false, false);
                        continue;
                    }
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
            return Flag(metadata, "Placeholder") && !UserEntries(path).Any();
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
        static bool Flag(Dictionary<string, string> metadata, string name)
        { string value; return metadata != null && metadata.TryGetValue(name, out value) && value == "1"; }
        void Apply(string path, DiskExplorerKind kind, string tip, Dictionary<string, string> metadata, bool placeholder, bool created)
        {
            string ini = Path.Combine(path, "desktop.ini");
            bool originalReadOnly = metadata == null ? (fs.Attributes(path) & FileAttributes.ReadOnly) != 0 : Flag(metadata, "OriginalReadOnly");
            string tooltip = tip.Replace("\r", " ").Replace("\n", " ").Replace("\0", "");
            string icon = icons.PathFor(kind);
            if (icon.IndexOfAny(new[] { '\r', '\n', '"' }) >= 0) throw new IOException("Недопустимый путь значка");
            string content = "[.ShellClassInfo]\r\nIconResource=" + icon + ",0\r\nInfoTip=" + tooltip + "\r\n[RemoteAgents]\r\nOwner=" + Owner + "\r\nOriginalReadOnly=" + (originalReadOnly ? "1" : "0") + "\r\nPlaceholder=" + (placeholder ? "1" : "0") + "\r\nCreatedDirectory=" + ((created || Flag(metadata, "CreatedDirectory")) ? "1" : "0") + "\r\n";
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
            bool remove = removeEmptyPlaceholder && Flag(metadata, "Placeholder") && Flag(metadata, "CreatedDirectory") && !UserEntries(path).Any();
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
