using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace RemoteAgents.Launcher
{
    internal static class LocalFoldersTests
    {
        static int count;
        static void Check(bool ok, string message) { if (!ok) throw new Exception("Local folders: " + message); count++; }
        static bool Refused(Action action) { try { action(); return false; } catch (IOException) { return true; } }
        sealed class FakeFileSystem : ILocalFileSystem
        {
            internal readonly List<LocalDrive> DriveList = new List<LocalDrive>();
            internal readonly Dictionary<string, List<LocalEntry>> Children = new Dictionary<string, List<LocalEntry>>(StringComparer.OrdinalIgnoreCase);
            internal readonly Dictionary<string, Exception> Errors = new Dictionary<string, Exception>(StringComparer.OrdinalIgnoreCase);
            internal readonly List<string> Listed = new List<string>();
            internal void Add(string parent, string name, FileAttributes attributes = FileAttributes.Directory)
            {
                List<LocalEntry> list; if (!Children.TryGetValue(parent, out list)) Children[parent] = list = new List<LocalEntry>();
                list.Add(new LocalEntry { Name = name, Path = parent.TrimEnd('\\') + "\\" + name, Attributes = attributes });
            }
            public IEnumerable<LocalDrive> Drives() { return DriveList; }
            public IEnumerable<LocalEntry> Folders(string path)
            {
                Listed.Add(path);
                List<LocalEntry> list; Exception error;
                if (Children.TryGetValue(path, out list)) foreach (var e in list) {
                    // Errors in the middle of enumeration, as DirectoryInfo.EnumerateDirectories can throw them.
                    if (Errors.TryGetValue(path, out error)) throw error;
                    yield return e;
                }
                else if (Errors.TryGetValue(path, out error)) throw error;
            }
            public bool Exists(string path) { return Children.ContainsKey(path); }
        }
        static DiskFoldersModel Model(string disk) { return new DiskFoldersModel(DiskChoice.FromProfile(Json.Map(Json.Parse("{\"disk\":" + disk + "}")))); }
        static DiskChoice Roundtrip(DiskFoldersModel model) { return DiskChoice.FromProfile(model.ToChoice().WriteTo(new Dictionary<string, object>(), "C:\\Users\\u\\Disk")); }
        internal static void Run()
        {
            const string disk = "C:\\Users\\u\\Disk";
            var system = new[] { "C:\\Windows", "C:\\Program Files" };
            var fs = new FakeFileSystem();
            fs.DriveList.Add(new LocalDrive { Root = "D:\\", Label = "Data", Type = DriveType.Fixed, Ready = true });
            fs.DriveList.Add(new LocalDrive { Root = "C:\\", Label = "", Type = DriveType.Fixed, Ready = true });
            fs.DriveList.Add(new LocalDrive { Root = "E:\\", Type = DriveType.CDRom, Ready = true });
            fs.DriveList.Add(new LocalDrive { Root = "Z:\\", Type = DriveType.Network, Ready = true });
            fs.DriveList.Add(new LocalDrive { Root = "F:\\", Type = DriveType.Fixed, Ready = false });
            var drives = LocalFolders.Drives(fs);
            Check(drives.Folders.Select(d => d.Path).SequenceEqual(new[] { "C:\\", "D:\\" }), "only ready fixed drives, sorted");
            Check(drives.Folders[0].Name == "Локальный диск (C:)" && drives.Folders[1].Name == "Data (D:)", "drive names are plain");

            fs.Add("D:\\", "Work"); fs.Add("D:\\", "archive"); fs.Add("D:\\", "$RECYCLE.BIN", FileAttributes.Directory | FileAttributes.Hidden | FileAttributes.System);
            fs.Add("D:\\", "Link", FileAttributes.Directory | FileAttributes.ReparsePoint); fs.Add("D:\\", ".cache", FileAttributes.Directory | FileAttributes.Hidden);
            var listing = LocalFolders.List(fs, "D:\\");
            Check(listing.Folders.Select(f => f.Name).SequenceEqual(new[] { "archive", "Work" }) && listing.Error == "", "hidden, system and junction folders skipped, names sorted");
            Check(fs.Listed.SequenceEqual(new[] { "D:\\" }), "listing reads only the requested level");
            fs.Errors["C:\\Users\\Other"] = new UnauthorizedAccessException("denied");
            var denied = LocalFolders.List(fs, "C:\\Users\\Other");
            Check(denied.Folders.Count == 0 && denied.Error == LocalFolders.NoAccess, "inaccessible folder becomes a plain message");
            fs.Add("D:\\Broken", "a"); fs.Errors["D:\\Broken"] = new PathTooLongException("too long");
            Check(LocalFolders.List(fs, "D:\\Broken").Error.StartsWith("Папка недоступна"), "long path error mid-enumeration is reported, not thrown");
            for (int i = 0; i < LocalFolders.Limit + 5; i++) fs.Add("D:\\Many", "f" + i);
            var many = LocalFolders.List(fs, "D:\\Many");
            Check(many.Truncated && many.Folders.Count == LocalFolders.Limit, "huge folder is capped");

            Check(LocalFolders.DiskBaseText(disk, false) == "Папки Disk на этом компьютере ещё нет — она будет создана при синхронизации: " + disk, "missing Disk folder is said plainly");
            Check(LocalFolders.DiskBaseText(disk, true) == disk, "existing Disk folder shows its path");

            var m = Model("{\"folders\":[]}");
            var free = LocalFolders.State(m, "D:\\Work", disk, system);
            Check(free.Kind == LocalFolderKind.Free && free.Choosable && !free.Checked, "ordinary folder can be chosen");
            Check(LocalFolders.Send(m, "D:\\Work", disk, system), "ordinary folder asks for a server name");
            Check(LocalFolders.SuggestedRemote("D:\\Work\\") == "Work", "server name suggested from folder name");
            var entry = LocalFolders.Choose(m, "D:\\Work", "Work", DiskChoice.Send, disk, system);
            var choice = Roundtrip(m);
            Check(choice.External.Count == 1 && choice.External[0].Path == "D:\\Work" && choice.External[0].Remote == "Work" && choice.External[0].Direction == DiskChoice.Send && choice.Folders.Count == 0, "chosen folder becomes DiskChoice.External");
            var chosen = LocalFolders.State(m, "d:\\work\\", disk, system);
            Check(chosen.Kind == LocalFolderKind.External && chosen.Checked && chosen.Entry == entry && chosen.Status.Contains("«Work»"), "chosen folder is shown checked with its server name");
            var inside = LocalFolders.State(m, "D:\\Work\\src", disk, system);
            Check(inside.Kind == LocalFolderKind.InExternal && !inside.Choosable && inside.Status.Contains("Work"), "subfolder of a chosen folder is covered, not chosen twice");
            var parent = LocalFolders.State(m, "D:\\", disk, system);
            Check(parent.Kind == LocalFolderKind.Contains && parent.Partial && !parent.Choosable, "drive with a chosen folder is marked partial");
            Check(Refused(() => LocalFolders.Choose(m, "D:\\Work\\src", "Src", DiskChoice.Both, disk, system)), "nested external refused like Assert-DiskExternalChoices");
            Check(Refused(() => LocalFolders.Choose(m, "D:\\archive", "Work", DiskChoice.Both, disk, system)), "duplicate server name refused");
            LocalFolders.Stop(m, "D:\\Work", disk);
            Check(m.External.Count == 0 && !LocalFolders.State(m, "D:\\Work", disk, system).Checked, "unchecking stops the external folder");
            Check(!LocalFolders.Send(m, "D:\\Work", disk, system) && m.External.Count == 1 && Roundtrip(m).External[0].Remote == "Work", "re-checking restores it without a second dialog");

            Check(LocalFolders.State(m, "E:\\", disk, system).Kind == LocalFolderKind.DriveRoot && Refused(() => LocalFolders.Send(m, "E:\\", disk, system)), "whole drive refused");
            Check(LocalFolders.State(m, "C:\\Windows\\System32", disk, system).Kind == LocalFolderKind.System && Refused(() => LocalFolders.Send(m, "C:\\Windows", disk, system)), "system folders refused");
            var profile = LocalFolders.State(m, "C:\\Users\\u", disk, system);
            Check(profile.Kind == LocalFolderKind.Contains && Refused(() => LocalFolders.Choose(m, "C:\\Users\\u", "u", DiskChoice.Both, disk, system)), "folder containing Disk refused");
            Check(LocalFolders.State(m, disk, disk, system).Kind == LocalFolderKind.Disk && Refused(() => LocalFolders.Send(m, disk, disk, system)), "Disk itself is not an external folder");
            var project = LocalFolders.State(m, disk + "\\Project\\docs", disk, system);
            Check(project.Kind == LocalFolderKind.InDisk && project.DiskPath == "Project/docs" && project.Choosable, "folder inside Disk maps to a Disk path");
            Check(!LocalFolders.Send(m, disk + "\\Project\\docs", disk, system) && Roundtrip(m).Folders.Single().Path == "Project/docs" && Roundtrip(m).External.Count == 1, "choosing inside Disk selects the Disk path, not an external folder");
            Check(LocalFolders.State(m, disk + "\\Project", disk, system).Partial && LocalFolders.State(m, disk + "\\Project\\docs", disk, system).Checked, "Disk selection shown on the computer tree");
            Check(Refused(() => LocalFolders.Choose(m, disk + "\\Other", "Other", DiskChoice.Both, disk, system)), "Disk folder never becomes external");
            LocalFolders.Stop(m, disk + "\\Project\\docs", disk);
            Check(Roundtrip(m).Folders.Count == 0, "unchecking inside Disk stops that Disk path");
            Check(Refused(() => LocalFolders.Stop(m, "D:\\archive", disk)), "stopping an unsynced folder is refused");
            var noBase = LocalFolders.State(Model("{\"folders\":[]}"), "C:\\Users\\u\\Disk\\X", "", system);
            Check(noBase.Kind == LocalFolderKind.Free, "empty Disk base does not swallow paths");
            Console.WriteLine("PASS local folder browser model checks: " + count);
        }
    }
}
