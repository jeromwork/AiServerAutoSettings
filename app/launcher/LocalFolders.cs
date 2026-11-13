using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace RemoteAgents.Launcher
{
    // Browsing THIS computer for the «Весь компьютер» tab. Pure rules here; the WinForms tree is LocalFolderBrowser.
    // Own code because Windows has no embeddable folder tree with checkboxes and per-folder sync status (FolderBrowserDialog
    // is modal and cannot show what already participates). Syncing itself stays with Syncthing via the «Disk» action.
    internal sealed class LocalDrive { internal string Root = "", Label = ""; internal DriveType Type; internal bool Ready; }
    internal sealed class LocalEntry { internal string Name = "", Path = ""; internal FileAttributes Attributes; }
    internal interface ILocalFileSystem
    {
        IEnumerable<LocalDrive> Drives();
        IEnumerable<LocalEntry> Folders(string path);
        bool Exists(string path);
    }
    internal sealed class LocalListing
    {
        internal readonly List<LocalEntry> Folders = new List<LocalEntry>();
        internal string Error = "";
        internal bool Truncated;
    }
    internal enum LocalFolderKind { Free, External, InExternal, Disk, InDisk, Contains, DriveRoot, System }
    internal sealed class LocalFolderState
    {
        internal LocalFolderKind Kind;
        internal bool Checked, Partial, Choosable;
        internal string Status = "", Reason = "", DiskPath = "";
        internal DiskExternalChoice Entry;
    }
    internal static class LocalFolders
    {
        internal const int Limit = 2000;
        internal const string NoAccess = "Нет доступа к папке";
        internal static string DiskBaseText(string diskBase, bool exists)
        {
            if (string.IsNullOrEmpty(diskBase)) return "Папка Disk не задана";
            return exists ? diskBase : "Папки Disk на этом компьютере ещё нет — она будет создана при синхронизации: " + diskBase;
        }
        internal static string DriveText(LocalDrive drive)
        {
            string letter = Normalize(drive.Root);
            return (string.IsNullOrWhiteSpace(drive.Label) ? "Локальный диск" : drive.Label.Trim()) + " (" + letter + ")";
        }
        // Fixed drives only: CD and network drives can hang or vanish, removable media is not a sync target.
        internal static LocalListing Drives(ILocalFileSystem fs)
        {
            var listing = new LocalListing();
            try {
                foreach (var d in fs.Drives())
                    if (d != null && d.Type == DriveType.Fixed && d.Ready && !string.IsNullOrEmpty(d.Root))
                        listing.Folders.Add(new LocalEntry { Name = DriveText(d), Path = d.Root, Attributes = FileAttributes.Directory });
            } catch (Exception error) when (Expected(error)) { listing.Error = "Список дисков недоступен: " + error.Message; }
            listing.Folders.Sort((a, b) => string.Compare(a.Path, b.Path, StringComparison.OrdinalIgnoreCase));
            return listing;
        }
        internal static bool Visible(LocalEntry entry)
        {
            const FileAttributes skip = FileAttributes.Hidden | FileAttributes.System | FileAttributes.ReparsePoint;
            return entry != null && !string.IsNullOrEmpty(entry.Name) && (entry.Attributes & skip) == 0;
        }
        // Hidden, system and junction/symlink folders are skipped: junctions loop or point elsewhere, the rest is not user data.
        internal static LocalListing List(ILocalFileSystem fs, string path)
        {
            var listing = new LocalListing();
            try {
                foreach (var entry in fs.Folders(path)) {
                    if (!Visible(entry)) continue;
                    if (listing.Folders.Count >= Limit) { listing.Truncated = true; break; }
                    listing.Folders.Add(entry);
                }
            } catch (UnauthorizedAccessException) { listing.Error = NoAccess; }
            catch (System.Security.SecurityException) { listing.Error = NoAccess; }
            catch (Exception error) when (Expected(error)) { listing.Error = "Папка недоступна: " + error.Message; }
            listing.Folders.Sort((a, b) => string.Compare(a.Name, b.Name, StringComparison.CurrentCultureIgnoreCase));
            return listing;
        }
        static bool Expected(Exception error) { return error is IOException || error is UnauthorizedAccessException || error is System.Security.SecurityException || error is ArgumentException || error is NotSupportedException || error is InvalidOperationException; }
        // String rules only: tests run on Linux with Windows paths, and the real paths come from the file system already absolute.
        internal static string Normalize(string path)
        {
            string p = (path ?? "").Trim().Replace('/', '\\');
            return p.TrimEnd('\\');
        }
        internal static bool Same(string a, string b) { return string.Equals(Normalize(a), Normalize(b), StringComparison.OrdinalIgnoreCase); }
        internal static bool Within(string parent, string path)
        {
            string p = Normalize(parent), c = Normalize(path);
            if (p.Length == 0 || c.Length == 0) return false;
            return string.Equals(p, c, StringComparison.OrdinalIgnoreCase) || c.StartsWith(p + "\\", StringComparison.OrdinalIgnoreCase);
        }
        internal static bool IsDriveRoot(string path) { string p = Normalize(path); return p.Length == 2 && p[1] == ':'; }
        internal static string SuggestedRemote(string path)
        {
            string p = Normalize(path); int slash = p.LastIndexOf('\\');
            return slash < 0 ? p : p.Substring(slash + 1);
        }
        static string Relative(string diskBase, string path) { return Normalize(path).Substring(Normalize(diskBase).Length + 1).Replace('\\', '/'); }
        internal static LocalFolderState State(DiskFoldersModel model, string path, string diskBase, IEnumerable<string> system)
        {
            var s = new LocalFolderState();
            var entry = model.ExternalRows.FirstOrDefault(e => Same(e.Path, path));
            if (entry != null) {
                s.Kind = LocalFolderKind.External; s.Entry = entry; s.Checked = model.IncludesExternal(entry);
                s.Choosable = !s.Checked; s.Reason = s.Checked ? "Эта папка выбрана для синхронизации" : "";
                s.Status = model.ExternalStatus(entry) + " → «" + entry.Remote + "»";
                return s;
            }
            var owner = model.External.FirstOrDefault(e => Within(e.Path, path));
            if (owner != null) {
                s.Kind = LocalFolderKind.InExternal; s.Entry = owner;
                s.Status = s.Reason = "Входит в выбранную папку «" + owner.Remote + "»";
                return s;
            }
            if (!string.IsNullOrEmpty(diskBase) && Same(diskBase, path)) {
                s.Kind = LocalFolderKind.Disk; s.Partial = model.Mode == DiskFoldersMode.All || model.Mode == DiskFoldersMode.Selected && model.Selection.Paths.Length > 0;
                s.Status = model.Mode == DiskFoldersMode.All ? "Папка Disk: все папки сервера" : s.Partial ? "Папка Disk: часть папок выбрана" : "Папка Disk: ничего не выбрано"; s.Reason = "Папки внутри Disk отмечаются по отдельности";
                return s;
            }
            if (!string.IsNullOrEmpty(diskBase) && Within(diskBase, path)) {
                s.Kind = LocalFolderKind.InDisk; s.DiskPath = Relative(diskBase, path);
                s.Checked = model.Includes(s.DiskPath); s.Partial = !s.Checked && model.Partial(s.DiskPath);
                s.Choosable = !s.Checked; s.Reason = s.Checked ? "Эта папка выбрана для синхронизации" : "";
                s.Status = (s.Checked || s.Partial) ? model.Status(s.DiskPath) : "В папке Disk; не синхронизируется";
                return s;
            }
            string systemRoot = (system ?? new string[0]).FirstOrDefault(r => Within(r, path));
            if (systemRoot != null) {
                s.Kind = LocalFolderKind.System; s.Status = s.Reason = "Системная папка — синхронизировать нельзя";
                return s;
            }
            bool hasDisk = !string.IsNullOrEmpty(diskBase) && Within(path, diskBase);
            var inner = model.External.FirstOrDefault(e => Within(path, e.Path));
            if (hasDisk || inner != null) {
                s.Kind = LocalFolderKind.Contains; s.Partial = true;
                s.Status = hasDisk ? "Внутри папка Disk" : "Внутри выбрана папка «" + inner.Remote + "»";
                s.Reason = hasDisk ? "Внутри находится папка Disk — выберите папку поменьше" : "Внутри уже выбрана папка «" + inner.Remote + "». Снимите её, чтобы выбрать эту папку целиком.";
                return s;
            }
            if (IsDriveRoot(path)) {
                s.Kind = LocalFolderKind.DriveRoot; s.Reason = "Целый диск синхронизировать нельзя — выберите папку на нём";
                return s;
            }
            s.Kind = LocalFolderKind.Free; s.Choosable = true; s.Status = "Не синхронизируется";
            return s;
        }
        // Returns true when the folder needs a server name and direction (the «Добавить папку» dialog); otherwise the
        // choice is already made: a folder inside Disk becomes a Disk path, a previously removed external entry is restored.
        internal static bool Send(DiskFoldersModel model, string path, string diskBase, IEnumerable<string> system)
        {
            var s = State(model, path, diskBase, system);
            if (!s.Choosable) throw new IOException(s.Reason.Length > 0 ? s.Reason : "Эту папку выбрать нельзя");
            if (s.Kind == LocalFolderKind.External) { model.SendToServer(s.Entry.Remote); return false; }
            if (s.Kind == LocalFolderKind.InDisk) { model.SendToServer(s.DiskPath); return false; }
            return true;
        }
        internal static void Stop(DiskFoldersModel model, string path, string diskBase)
        {
            var s = State(model, path, diskBase, null);
            if (s.Kind == LocalFolderKind.External) model.StopSynchronizing(s.Entry.Remote);
            else if (s.Kind == LocalFolderKind.InDisk) model.StopSynchronizing(s.DiskPath);
            else throw new IOException("Эта папка не синхронизируется отдельно");
        }
        // The same rules as Assert-DiskExternalChoices (disk/Disk.Selective.ps1), checked before the user waits for Apply.
        internal static DiskExternalChoice Choose(DiskFoldersModel model, string path, string remote, string direction, string diskBase, IEnumerable<string> system)
        {
            var s = State(model, path, diskBase, system);
            if (s.Kind == LocalFolderKind.InDisk) throw new IOException("Эта папка внутри Disk — отметьте её без нового имени");
            if (!s.Choosable || s.Kind != LocalFolderKind.Free) throw new IOException(s.Reason.Length > 0 ? s.Reason : "Эту папку выбрать нельзя");
            model.AddExternal(path, remote, direction);
            return model.External.Last();
        }
    }
    // Real file system. DirectoryInfo enumerates lazily; a long path that the OS refuses becomes a per-folder error.
    internal sealed class LocalFileSystem : ILocalFileSystem
    {
        public IEnumerable<LocalDrive> Drives()
        {
            var result = new List<LocalDrive>();
            foreach (var d in DriveInfo.GetDrives()) {
                var drive = new LocalDrive { Root = d.Name };
                try { drive.Type = d.DriveType; drive.Ready = drive.Type == DriveType.Fixed && d.IsReady; if (drive.Ready) drive.Label = d.VolumeLabel; }
                catch (Exception error) when (error is IOException || error is UnauthorizedAccessException) { drive.Ready = false; }
                result.Add(drive);
            }
            return result;
        }
        public IEnumerable<LocalEntry> Folders(string path)
        {
            foreach (var d in new DirectoryInfo(path).EnumerateDirectories())
                yield return new LocalEntry { Name = d.Name, Path = d.FullName, Attributes = d.Attributes };
        }
        public bool Exists(string path) { try { return !string.IsNullOrEmpty(path) && Directory.Exists(path); } catch (Exception) { return false; } }
    }
}
