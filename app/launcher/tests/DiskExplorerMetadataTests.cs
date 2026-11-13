using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace RemoteAgents.Launcher
{
    internal static class DiskExplorerMetadataTests
    {
        static int checks;
        static void Check(bool value, string message) { if (!value) throw new Exception("Explorer metadata: " + message); checks++; }
        internal static void Run()
        {
            var fs = new FakeFiles(); var notify = new FakeNotify(); var logs = new List<string>();
            var service = new DiskExplorerService(fs, new FakeIcons(), notify, logs.Add);
            var root = Path.GetFullPath("/Disk"); fs.CreateDirectory(root);
            var rows = new[] { new DiskExplorerFolder { Name = "server", ServerOnly = true }, new DiskExplorerFolder { Name = "local" } };
            string server = Path.Combine(root, "server"), local = Path.Combine(root, "local"); fs.CreateDirectory(local);
            service.Reconcile(root, rows, null);
            Check(service.IsPlaceholder(server), "server inventory creates marked empty placeholder");
            Check(!service.IsPlaceholder(local), "preexisting local folder never becomes placeholder");
            Check(fs.Read(Path.Combine(server, "desktop.ini")).Contains("Placeholder=1\r\n"), "ownership file uses CRLF");
            int writes = fs.Writes, attributes = fs.AttributeWrites, changes = notify.Changes;
            service.Reconcile(root, rows, null);
            Check(fs.Writes == writes && fs.AttributeWrites == attributes && notify.Changes == changes, "unchanged reconcile does not touch filesystem or shell");
            fs.Write(Path.Combine(server, "real.txt"), "user data"); service.Reconcile(root, rows, null);
            Check(!service.IsPlaceholder(server), "downloaded/user files invalidate placeholder");
            Check(fs.Read(Path.Combine(server, "desktop.ini")).Contains("Placeholder=0"), "marker cleared when real files arrive");
            service.Cleanup(root); service.Cleanup(root);
            Check(fs.DirectoryExists(server) && fs.Read(Path.Combine(server, "real.txt")) == "user data", "cleanup preserves folders and data");
            Check(!fs.FileExists(Path.Combine(server, "desktop.ini")) && (fs.Attributes(server) & FileAttributes.ReadOnly) == 0, "cleanup restores original read-only bit");
            string ro = Path.Combine(root, "ro"); fs.CreateDirectory(ro); fs.Attributes(ro, FileAttributes.Directory | FileAttributes.ReadOnly | FileAttributes.Hidden);
            service.Reconcile(root, new[] { new DiskExplorerFolder { Name = "ro" } }, null); service.Cleanup(root);
            Check((fs.Attributes(ro) & (FileAttributes.ReadOnly | FileAttributes.Hidden)) == (FileAttributes.ReadOnly | FileAttributes.Hidden), "original RO and unrelated attributes preserved");
            string foreign = Path.Combine(root, "foreign"); fs.CreateDirectory(foreign); fs.Write(Path.Combine(foreign, "desktop.ini"), "[.ShellClassInfo]\r\nInfoTip=user\r\n");
            writes = fs.Writes; service.Reconcile(root, new[] { new DiskExplorerFolder { Name = "foreign" } }, null); service.CleanupFolder(foreign);
            Check(fs.Writes == writes && fs.Read(Path.Combine(foreign, "desktop.ini")).Contains("InfoTip=user"), "foreign CRLF customization remains intact");
            Check(logs.Any(x => x.Contains("чужой")), "foreign customization is logged");
            string link = Path.Combine(root, "link"); fs.CreateDirectory(link); fs.Attributes(link, FileAttributes.Directory | FileAttributes.ReparsePoint);
            writes = fs.Writes; service.Reconcile(root, new[] { new DiskExplorerFolder { Name = "link", ServerOnly = true } }, null);
            Check(fs.Writes == writes && !service.IsPlaceholder(link), "junctions are not decorated or traversed");
            string iniLink = Path.Combine(root, "ini-link"); fs.CreateDirectory(iniLink); fs.Write(Path.Combine(iniLink, "desktop.ini"), "target"); fs.Attributes(Path.Combine(iniLink, "desktop.ini"), FileAttributes.ReparsePoint);
            writes = fs.Writes; service.Reconcile(root, new[] { new DiskExplorerFolder { Name = "ini-link" } }, null);
            Check(fs.Writes == writes && fs.Read(Path.Combine(iniLink, "desktop.ini")) == "target", "desktop.ini reparse point is not overwritten");
            string collision = Path.Combine(root, "collision"); fs.Write(collision, "file");
            service.Reconcile(root, new[] { new DiskExplorerFolder { Name = "collision", ServerOnly = true } }, null);
            Check(fs.Read(collision) == "file", "server file collision is preserved");
            Check(!DiskExplorerService.ValidName("../outside") && !DiskExplorerService.ValidName("bad\r\nname") && !DiskExplorerService.ValidName("trailing."), "unsafe names rejected");
            var snapshot = new DiskSyncSnapshot { Connected = true, Failure = "" }; var folder = new DiskSyncFolder { Id = "f", Shared = true };
            folder.Status["state"] = "idle"; folder.Status["needFiles"] = 0; folder.Status["needBytes"] = 0;
            Check(DiskExplorerPresentation.From(snapshot, folder, true, false).Kind == DiskExplorerKind.Synced, "completion uses shared DiskSyncStatus");
            folder.Status.Remove("needFiles"); Check(DiskExplorerPresentation.From(snapshot, folder, true, false).Kind != DiskExplorerKind.Synced, "absent counter cannot show green");
            folder.Status["state"] = "scanning"; Check(DiskExplorerPresentation.From(snapshot, folder, true, false).Kind == DiskExplorerKind.Syncing, "scanning is processing");
            folder.Paused = true; Check(DiskExplorerPresentation.From(snapshot, folder, true, false).Kind == DiskExplorerKind.Paused, "paused never green");
            folder.Status["error"] = "ошибка\r\nprivate extra";
            Check(DiskExplorerPresentation.From(snapshot, folder, true, false).Kind == DiskExplorerKind.Error && !DiskExplorerPresentation.From(snapshot, folder, true, false).Tooltip.Contains("private"), "CRLF error follows common safe first line");
            Check(DiskExplorerPresentation.From(DiskSyncSnapshot.Unavailable("REST\r\nuntrusted"), folder, true, false).Kind == DiskExplorerKind.Unavailable, "REST failure wins");
            folder.Paused = false; folder.Status.Clear(); snapshot.Connected = false;
            Check(DiskExplorerPresentation.From(snapshot, folder, true, false).Kind == DiskExplorerKind.Offline, "disconnection is explicit");
            var cloud = DiskExplorerPresentation.From(null, null, false, true);
            Check(cloud.MenuActions.SequenceEqual(new[] { "download" }) && cloud.Icon.EndsWith("ServerOnly.ico") && cloud.Tooltip == "Только на сервере. Правый клик → Скачать на компьютер", "server presentation tuple");
            var synced = new DiskExplorerPresentation { Kind = DiskExplorerKind.Synced };
            Check(synced.MenuActions.SequenceEqual(new[] { "keep-server", "progress" }) && synced.Icon.EndsWith("Synced.ico"), "selected menu independent from transfer health");
            var localDisplay = DiskExplorerPresentation.From(null, null, false, false);
            Check(localDisplay.MenuActions.SequenceEqual(new[] { "sync" }) && localDisplay.Tooltip == "Не синхронизируется. Правый клик → Добавить в Диск", "local presentation tuple");
            Check(!service.MarkPlaceholder(foreign) && !service.MarkPlaceholder(link) && !service.MarkPlaceholder(server), "placeholder transition refuses foreign metadata, junctions and data");
            string empty = Path.Combine(root, "evicted");
            Check(service.MarkPlaceholder(empty) && service.IsPlaceholder(empty), "successful eviction can explicitly become server-only");
            service.CleanupFolder(empty); Check(fs.DirectoryExists(empty) && !service.IsPlaceholder(empty), "default cleanup only removes metadata");
            string fresh = Path.GetFullPath("/FreshDisk");
            service.Reconcile(fresh, new[] { new DiskExplorerFolder { Name = "remote", ServerOnly = true } }, null);
            Check(service.IsPlaceholder(Path.Combine(fresh, "remote")), "fresh Disk root created for confirmed inventory");
            External();
            Registry();
            Console.WriteLine("Explorer metadata: " + checks + " checks passed");
        }
        static void External()
        {
            var fs = new FakeFiles(); var notify = new FakeNotify(); var logs = new List<string>();
            var service = new DiskExplorerService(fs, new FakeIcons(), notify, logs.Add);
            string parent = Path.GetFullPath("/External"), target = Path.Combine(parent, "source"), sibling = Path.Combine(parent, "sibling");
            fs.CreateDirectory(parent); fs.CreateDirectory(target); fs.CreateDirectory(sibling);
            fs.Attributes(target, FileAttributes.Directory | FileAttributes.ReadOnly | FileAttributes.Hidden);
            fs.Write(Path.Combine(target, "project.txt"), "user data");
            fs.Write(Path.Combine(target, ".stignore"), "desktop.ini\r\n");
            fs.Write(Path.Combine(sibling, "desktop.ini"), "foreign sibling\r\n");
            var snapshot = new DiskSyncSnapshot { Connected = true, Failure = "" };
            var folder = new DiskSyncFolder { Id = "external-id", Path = target, Shared = true };
            folder.Status["state"] = "idle"; folder.Status["needFiles"] = 0; folder.Status["needBytes"] = 0;
            snapshot.Folders["remote"] = folder;
            int enumerations = fs.Enumerations;
            Check(service.ReconcileExternal(target, "remote", snapshot, true), "configured external source accepts direct customization");
            string ini = Path.Combine(target, "desktop.ini");
            Check(fs.Read(ini).Contains("Synced.ico") && fs.Read(ini).Contains("InfoTip=На компьютере и на сервере") && fs.Read(ini).Contains("Placeholder=0"), "external source uses actual shared snapshot");
            Check(fs.Enumerations == enumerations, "external customization never enumerates target, parent or siblings");
            int writes = fs.Writes, attributes = fs.AttributeWrites, changes = notify.Changes;
            Check(service.ReconcileExternal(target, "remote", snapshot, true) && fs.Writes == writes && fs.AttributeWrites == attributes && notify.Changes == changes, "external customization is idempotent");
            folder.Status["state"] = "syncing"; folder.Status["needFiles"] = 2; folder.Status["globalBytes"] = 100; folder.Status["inSyncBytes"] = 45;
            service.ReconcileExternal(target, "remote", snapshot, true);
            Check(fs.Read(ini).Contains("Syncing.ico") && fs.Read(ini).Contains("Синхронизация 45%"), "external source updates transfer progress");
            folder.Path = Path.Combine(parent, "different"); service.ReconcileExternal(target, "remote", snapshot, true);
            Check(fs.Read(ini).Contains("Unavailable.ico"), "snapshot for a different external source cannot show completion");
            service.CleanupExternal(target); service.CleanupExternal(target);
            Check(fs.DirectoryExists(target) && !fs.FileExists(ini) && fs.Read(Path.Combine(target, "project.txt")) == "user data", "external cleanup only removes owned metadata");
            Check((fs.Attributes(target) & (FileAttributes.ReadOnly | FileAttributes.Hidden)) == (FileAttributes.ReadOnly | FileAttributes.Hidden), "external cleanup restores original RO and preserves hidden flag");
            Check(fs.Read(Path.Combine(sibling, "desktop.ini")) == "foreign sibling\r\n" && fs.Enumerations == enumerations, "external cleanup leaves siblings untouched without enumeration");
            fs.Write(ini, "[.ShellClassInfo]\r\nInfoTip=foreign\r\n"); writes = fs.Writes;
            Check(!service.ReconcileExternal(target, "remote", snapshot, true) && fs.Writes == writes && logs.Any(x => x.Contains("чужой")), "external foreign metadata is preserved and logged");
            fs.Attributes(target, fs.Attributes(target) | FileAttributes.ReparsePoint);
            Check(!service.ReconcileExternal(target, "remote", snapshot, true), "external target cannot itself be a junction");
            fs.Attributes(target, FileAttributes.Directory); fs.Attributes(parent, FileAttributes.Directory | FileAttributes.ReparsePoint);
            Check(!service.ReconcileExternal(target, "remote", snapshot, true), "external target under a junction is rejected");
            fs.Attributes(parent, FileAttributes.Directory);
            string missing = Path.Combine(parent, "missing");
            Check(!service.ReconcileExternal(missing, "remote", snapshot, true) && !fs.DirectoryExists(missing), "external customization never creates a missing source");
            Check(!service.ReconcileExternal(target, "bad\r\nname", snapshot, true), "external name rejects CRLF injection");
        }
        static void Registry()
        {
            var store = new FakeRegistry(); int notifications = 0; var reg = new DiskExplorerRegistry(store, delegate { }, () => notifications++);
            var rows = new[] { new DiskExplorerFolder { Name = "download", ServerOnly = true }, new DiskExplorerFolder { Name = "local" }, new DiskExplorerFolder { Name = "selected", Selected = true } };
            reg.Register(@"C:\App Name\RemoteAgents.exe", @"C:\Disk", rows, @"C:\User Home");
            string prefix = DiskExplorerRegistry.Prefix;
            Check(store.Read(prefix + "download\\command", "") == "\"C:\\App Name\\RemoteAgents.exe\" --home \"C:\\User Home\" --disk-shell download \"%1\"", "command quotes executable, configured home and clicked path");
            Check(store.Read(prefix + "download", "AppliesTo").Contains("C:\\Disk\\download") && !store.Read(prefix + "download", "AppliesTo").Contains("selected"), "download scope is exact placeholder path");
            Check(store.Read(prefix + "keep-server", "AppliesTo").Contains("selected") && !store.Read(prefix + "keep-server", "AppliesTo").Contains("local"), "keep-server only selected folders");
            Check(store.Read(prefix + "add", "AppliesTo").Contains("NOT System.ItemPathDisplay:~<\"C:\\Disk\\\""), "outside add scope excludes configured Disk");
            Check(store.Read(prefix + "sync", "MultiSelectModel") == "Document", "legacy Explorer dispatches selected folders individually");
            int writes = store.Writes; reg.Register(@"C:\App Name\RemoteAgents.exe", @"C:\Disk", rows, @"C:\User Home");
            Check(store.Writes == writes && notifications == 1, "registry reconcile skips unchanged values and broadcasts once");
            reg.Register(@"C:\App Name\RemoteAgents.exe", @"C:\Disk", rows, @"C:\User Home\");
            Check(store.Read(prefix + "download\\command", "").Contains(" --home " + Files.Quote(@"C:\User Home\") + " --disk-shell "), "trailing slash home keeps native argument boundary");
            reg.Cleanup(); reg.Cleanup(); Check(store.Values.Count == 0, "HKCU cleanup idempotent");
            store.Write(prefix + "add", "MUIVerb", "foreign"); reg.Register(@"C:\app.exe", @"C:\Disk", rows); reg.Cleanup();
            Check(store.Read(prefix + "add", "MUIVerb") == "foreign", "foreign key ownership is respected");
            bool rejected = false; try { reg.Register("bad\r\nexe", @"C:\Disk", rows); } catch (ArgumentException) { rejected = true; }
            Check(rejected, "CRLF registry command injection rejected");
        }
        sealed class FakeIcons : IDiskExplorerIcons { public string PathFor(DiskExplorerKind kind) { return "/icons/" + kind + ".ico"; } }
        sealed class FakeNotify : IDiskExplorerNotifier { internal int Changes; public void Changed(string path) { Changes++; } }
        sealed class FakeFiles : IDiskExplorerFileSystem
        {
            sealed class Entry { internal FileAttributes Attributes; internal string Content; }
            readonly Dictionary<string, Entry> entries = new Dictionary<string, Entry>(StringComparer.OrdinalIgnoreCase);
            internal int Writes, AttributeWrites, Enumerations;
            public bool DirectoryExists(string path) { Entry e; return entries.TryGetValue(path, out e) && (e.Attributes & FileAttributes.Directory) != 0; }
            public bool FileExists(string path) { Entry e; return entries.TryGetValue(path, out e) && (e.Attributes & FileAttributes.Directory) == 0; }
            public FileAttributes Attributes(string path) { return entries[path].Attributes; }
            public void Attributes(string path, FileAttributes value) { entries[path].Attributes = value; AttributeWrites++; }
            public IEnumerable<string> Entries(string path) { Enumerations++; return entries.Keys.Where(p => Path.GetDirectoryName(p) == path).ToArray(); }
            public string Read(string path) { return entries[path].Content; }
            public void Write(string path, string content) { entries[path] = new Entry { Content = content, Attributes = FileAttributes.Normal }; Writes++; }
            public void CreateDirectory(string path) { if (!DirectoryExists(path)) entries[path] = new Entry { Attributes = FileAttributes.Directory }; }
            public void DeleteFile(string path) { entries.Remove(path); }
            public void DeleteDirectory(string path) { if (Entries(path).Any()) throw new IOException("not empty"); entries.Remove(path); }
        }
        sealed class FakeRegistry : IDiskExplorerRegistry
        {
            internal readonly Dictionary<string, string> Values = new Dictionary<string, string>();
            internal int Writes;
            public bool Exists(string key) { return Values.Keys.Any(k => k.StartsWith(key + "|", StringComparison.Ordinal)); }
            public string Read(string key, string name) { string value; return Values.TryGetValue(key + "|" + name, out value) ? value : null; }
            public void Write(string key, string name, string value) { Values[key + "|" + name] = value; Writes++; }
            public void DeleteTree(string key) { foreach (string k in Values.Keys.Where(k => k.StartsWith(key + "|", StringComparison.Ordinal) || k.StartsWith(key + "\\", StringComparison.Ordinal)).ToArray()) Values.Remove(k); }
        }
    }
}
