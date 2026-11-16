using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace RemoteAgents.Launcher
{
    internal static class DiskExplorerTests
    {
        static int checks;
        static readonly CancellationToken None = CancellationToken.None;
        static void Check(bool ok, string message) { if (!ok) throw new Exception("Disk Explorer: " + message); checks++; }
        static void Reject(Action action, string message)
        { bool rejected = false; try { action(); } catch (Exception e) when (e is IOException || e is ArgumentException || e is System.Xml.XmlException) { rejected = true; } Check(rejected, message); }
        static Dictionary<string, object> Map(string json) { return Json.Map(Json.Parse(json)); }
        // Called by the two-engine fixture. Only the Recycle Bin is replaced with a reversible move on Linux.
        internal static int EngineAction(string[] args)
        {
            var rest = new DiskSyncthingClient(args[1]); var service = Service(new TestFiles());
            var commands = new DiskShellCommands(rest, args[2], service, new DiskPlaceholderCatalog(args[1]), File.ReadAllText(args[5]), path => Directory.Move(path, args[6]), args.Length > 7 ? int.Parse(args[7]) : 30000, args[1]);
            if (args[3] == "watch-missing") {
                var watch = new DiskMissingFolders(args[1], Console.WriteLine);
                var elapsed = Stopwatch.StartNew();
                while (elapsed.Elapsed.TotalSeconds < 34) { watch.Reconcile(rest, args[2], None); Thread.Sleep(200); }
                return 0;
            }
            if (args[3] == "inspect") {
                var snapshot = commands.Read(None);
                Console.WriteLine(Json.Encode(new { folders = snapshot.Folders.Select(f => new { f.Id, kind = f.Kind.ToString(), f.Detail }).ToArray(), tray = new DiskTraySession(args[1]).Read(None) }));
                return 0;
            }
            service.Reconcile(args[2], commands.Read(None).Folders);
            string result = commands.Execute(new DiskShellRequest { Action = args[3], Path = args[4] }, None);
            Console.WriteLine(result); return 0;
        }
        internal static void Run()
        {
            string temp = Path.Combine(Path.GetTempPath(), "disk-explorer-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(temp);
            try { RecyclePolicy(); States(); MissingFolders(Path.Combine(temp, "missing")); FolderErrorsAndRemoval(Path.Combine(temp, "removal")); Metadata(Path.Combine(temp, "metadata")); LocalCopies(Path.Combine(temp, "local-copies")); Registry(); Menu(); MenuIcon(); IconFile(Path.Combine(temp, "icons")); StateIcons(Path.Combine(temp, "state-icons")); Commands(Path.Combine(temp, "actions")); Console.WriteLine("PASS: Explorer model, metadata, registry and action fixtures"); HttpAndEvents(Path.Combine(temp, "http")).GetAwaiter().GetResult(); }
            finally { if (Directory.Exists(temp)) Directory.Delete(temp, true); }
            Console.WriteLine("PASS: " + checks + " local Syncthing / Explorer checks (REST, events, placeholders, HKCU, shell, recycle rollback)");
        }
        sealed class ShellItem : DiskRecycle.IShellItem { }
        static void RecyclePolicy()
        {
            Check((DiskRecycle.Flags & 0x84050) == 0x84050 && (DiskRecycle.Flags & 0x400) == 0, "recycle-only flags, nuke warning, Shell error UI enabled");
            var sink = new DiskRecycle.RecycleSink();
            Check(sink.PreDeleteItem(0, null) < 0 && !sink.Confirmed, "permanent delete vetoed before Shell operation");
            sink = new DiskRecycle.RecycleSink();
            Check(sink.PreDeleteItem(0x80, null) == 0, "recycle operation admitted");
            sink.PostDeleteItem(0x80, null, 0, null);
            Check(!sink.Confirmed, "missing recycled item is never accepted as success");
            sink = new DiskRecycle.RecycleSink(); sink.PostDeleteItem(0x80, null, 0, new ShellItem());
            Check(sink.Confirmed, "Shell reports new item in recycle bin"); sink.FinishOperations(-1);
            Check(!sink.Confirmed, "failed operation never reports recycle success");
        }
        static void States()
        {
            var local = Map("{\"state\":\"idle\",\"globalBytes\":100,\"needBytes\":0,\"needTotalItems\":0}");
            var remote = Map("{\"completion\":100,\"needBytes\":0,\"needItems\":0,\"needDeletes\":0,\"remoteState\":\"valid\"}");
            var row = new DiskFolderState();
            Check(DiskSnapshot.Status(row, local, remote, true).Kind == DiskExplorerKind.Synced, "only confirmed local and remote completion is green");
            Check(DiskSnapshot.Status(row, local, remote, false).Kind == DiskExplorerKind.Offline, "disconnected never green");
            local["state"] = "scanning"; Check(DiskSnapshot.Status(row, local, remote, true).Kind == DiskExplorerKind.Syncing && row.Percent == 99, "scanning cannot show 100%");
            local["state"] = "syncing"; local["needBytes"] = 55;
            Check(DiskSnapshot.Status(row, local, remote, true).Percent == 45 && row.Tooltip.Contains("45%"), "download percentage");
            local["needBytes"] = 0; remote["completion"] = 20;
            Check(DiskSnapshot.Status(row, local, remote, true).Percent == 20, "upload percentage uses server completion");
            local["state"] = "idle"; remote["completion"] = 100; remote["needDeletes"] = 1;
            Check(DiskSnapshot.Status(row, local, remote, true).Kind == DiskExplorerKind.Syncing, "pending deletions are not complete");
            remote["needDeletes"] = 0; remote["remoteState"] = "notSharing";
            Check(DiskSnapshot.Status(row, local, remote, true).Kind == DiskExplorerKind.Pending, "server must accept the folder");
            remote["remoteState"] = "paused"; Check(DiskSnapshot.Status(row, local, remote, true).Kind == DiskExplorerKind.Paused, "server pause is explicit");
            remote["remoteState"] = "valid"; local.Remove("needTotalItems");
            Check(DiskSnapshot.Status(row, local, remote, true).Kind == DiskExplorerKind.Pending, "missing counters never imply completion");
            local["needTotalItems"] = 0; row.Paused = true;
            Check(DiskSnapshot.Status(row, local, remote, true).Kind == DiskExplorerKind.Paused, "pause is explicit");
            row.Paused = false; local["pullErrors"] = 1;
            Check(DiskSnapshot.Status(row, local, remote, true).Kind == DiskExplorerKind.Error, "pull errors are explicit");
            Check(!DiskPaths.ValidName("CON.txt") && !DiskPaths.ValidName("a\\b") && !DiskPaths.ValidName("trailing.") && !DiskPaths.ValidName("bad\r\nname") && DiskPaths.ValidName("Проект №1"), "portable Windows name validation");
            Check(DiskPaths.Full(Path.GetPathRoot(Path.GetTempPath())) == Path.GetPathRoot(Path.GetTempPath()), "filesystem root is preserved");
            Check(!WindowModel.ShouldShow(new[] { "--disk-shell", "add", "/folder" }) && !WindowModel.ForwardArguments(new[] { "--disk-shell", "add", "/folder" }).Contains("--show"), "shell IPC stays out of main window");
            Reject(() => DiskShellRequest.Parse(new[] { "--disk-shell", "unknown", "/path" }), "unknown shell action rejected");
            Reject(() => DiskShellRequest.Parse(new[] { "--disk-shell", "add", "relative" }), "relative path rejected");
            Check(DiskRestModel.EventId(Json.Parse("{\"id\":5000000000}")) == 5000000000L, "64-bit event cursor");
            Check(DiskRestModel.ChangesFolders(Json.Parse("{\"type\":\"PendingFoldersChanged\"}")) && !DiskRestModel.ChangesFolders(Json.Parse("{\"type\":\"DeviceDiscovered\"}")), "only relevant events refresh folders");
        }
        internal sealed class TestFiles : IDiskExplorerFileSystem
        {
            readonly Dictionary<string, FileAttributes> attributes = new Dictionary<string, FileAttributes>();
            internal int Writes;
            internal Func<string, FileAttributes?> Stat;
            public bool DirectoryExists(string p) { return Directory.Exists(p); }
            public bool FileExists(string p) { return File.Exists(p); }
            public FileAttributes Attributes(string p) { if (Stat != null) { var v = Stat(p); if (v.HasValue) return v.Value; } FileAttributes a; return attributes.TryGetValue(p, out a) ? a : File.GetAttributes(p); }
            public void Attributes(string p, FileAttributes a) { attributes[p] = a; }
            public IEnumerable<string> Entries(string p) { return Directory.GetFileSystemEntries(p); }
            public string Read(string p) { return File.ReadAllText(p); }
            public void Write(string p, string s) { Writes++; File.WriteAllText(p, s, Encoding.Unicode); }
            public void CreateDirectory(string p) { Directory.CreateDirectory(p); }
            public void DeleteFile(string p) { File.Delete(p); attributes.Remove(p); }
            public void DeleteDirectory(string p) { Directory.Delete(p); attributes.Remove(p); }
        }
        static void MissingFolders(string temp)
        {
            string root = Path.Combine(temp, "Disk"), home = Path.Combine(temp, "state"), outside = Path.Combine(temp, "External");
            Directory.CreateDirectory(root); File.WriteAllText(Path.Combine(root, "keep"), "keep");
            var fs = new TestFiles(); var rest = new FakeRest(); var logs = new List<string>(); double now = 100;
            Func<string, string, Dictionary<string, object>> folder = (id, path) => Map("{\"id\":" + Json.Encode(id) + ",\"label\":" + Json.Encode(id) + ",\"path\":" + Json.Encode(path) + ",\"devices\":[{\"deviceID\":\"SERVER\"}]}");
            rest.Folders.Add(folder("external", outside)); rest.Folders.Add(folder("inside", Path.Combine(root, "Gone")));
            var watch = new DiskMissingFolders(home, logs.Add, fs, () => now, "test");
            watch.Reconcile(rest, root, None); now = 129.99; watch.Reconcile(rest, root, None);
            Check(rest.Folders.Count == 2 && logs.Count == 0, "missing paths stay registered before thirty monotonic seconds");
            // Reload the atomic on-disk state; independent of wall clock and of this instance.
            watch = new DiskMissingFolders(home, logs.Add, fs, () => now, "test"); now = 130;
            Check(watch.Reconcile(rest, root, None) && rest.Folders.Count == 0 && logs.Count == 2 && logs.Any(l => l.EndsWith("external")), "inside and external missing folders detach at thirty seconds with one journal line each");
            watch.Reconcile(rest, root, None); Check(logs.Count == 2 && File.ReadAllText(Path.Combine(root, "keep")) == "keep", "repeat detachment is silent and never removes files");
            rest.Folders.Add(folder("brief", outside)); now = 200; watch.Reconcile(rest, root, None);
            Directory.CreateDirectory(outside); now = 229; watch.Reconcile(rest, root, None); Directory.Delete(outside);
            now = 231; watch.Reconcile(rest, root, None); now = 260; watch.Reconcile(rest, root, None);
            Check(rest.Folders.Count == 1, "return of same path resets its entire observation");
            // Access errors, files and links are never absence (even after an earlier observation).
            foreach (int mode in new[] { 0, 1, 2, 3 }) {
                fs.Stat = p => { if (p == outside) { if (mode == 0) throw new UnauthorizedAccessException(); if (mode == 1) return FileAttributes.Normal; if (mode == 2) return FileAttributes.ReparsePoint; } if (mode == 3 && p == temp) throw new IOException("unmounted"); return null; };
                now += 100; watch.Reconcile(rest, root, None);
            }
            fs.Stat = null; now += 100; watch.Reconcile(rest, root, None);
            Check(rest.Folders.Count == 1, "file, dangling link, access error and unavailable parent reset timers");
            watch = new DiskMissingFolders(home, logs.Add, fs, () => now, "new-process"); now += 100;
            watch.Reconcile(rest, root, None); Check(rest.Folders.Count == 1, "new process/epoch starts a fresh conservative observation");
            now -= 50; watch.Reconcile(rest, root, None); now += 29; watch.Reconcile(rest, root, None);
            Check(rest.Folders.Count == 1, "backwards monotonic sample cannot expire an observation");
            rest.Folders.Clear(); rest.Folders.Add(folder("empty", Path.Combine(root, "Gone"))); File.Delete(Path.Combine(root, "keep"));
            now += 100; watch.Reconcile(rest, root, None); now += 100; watch.Reconcile(rest, root, None);
            Check(rest.Folders.Count == 1, "empty Disk never detaches folders");
            File.WriteAllText(Path.Combine(root, "keep"), "keep"); watch.Reconcile(rest, root, None);
            now += 30; int reads = 0;
            rest.OnFoldersRead = () => { if (++reads == 2) Directory.CreateDirectory(Path.Combine(root, "Gone")); };
            watch.Reconcile(rest, root, None); Check(rest.Folders.Count == 1 && reads == 2, "filesystem is rechecked after fetching the current registration, immediately before DELETE");
            rest.OnFoldersRead = null; Directory.Delete(Path.Combine(root, "Gone"));
            now += 100; watch.Reconcile(rest, root, None); rest.FailDelete = true; now += 30; watch.Reconcile(rest, root, None);
            Check(rest.Folders.Count == 1, "rejected DELETE keeps registration and observation for retry");
            rest.FailDelete = false; watch.Reconcile(rest, root, None); Check(rest.Folders.Count == 0, "retry detaches without deleting files");
            rest.Folders.Add(folder("foreign", outside)); rest.Folders[0]["devices"] = new object[0]; now += 100; watch.Reconcile(rest, root, None); now += 100; watch.Reconcile(rest, root, None);
            Check(rest.Folders.Count == 1, "foreign registration not shared with our server is untouched");
            File.WriteAllText(Path.Combine(home, "missing-folders.json"), "{broken\r\n"); rest.Folders[0]["devices"] = new[] { new { deviceID = "SERVER" } };
            watch.Reconcile(rest, root, None); Check(rest.Folders.Count == 1, "corrupt state starts a fresh observation");
            foreach (object invalid in new object[] { null, "bad", "NaN", "Infinity", -1, now + 10000 }) {
                var state = Json.Read(Path.Combine(home, "missing-folders.json"));
                Json.Map(Json.Get(Json.Map(Json.Get(state, "folders")), "foreign"))["since"] = invalid;
                Json.Write(Path.Combine(home, "missing-folders.json"), state); now += 100;
                watch.Reconcile(rest, root, None);
                Check(rest.Folders.Count == 1, "invalid persisted monotonic time cannot authorize early detachment: " + invalid);
            }
            Check(!Directory.GetFiles(home, "*.tmp").Any(), "atomic state leaves no temporary files");
        }
        sealed class Icons : IDiskExplorerIcons { public string PathFor(DiskExplorerKind k) { return "/icons/" + k + ".ico"; } public string ApplicationPath() { return "/icons/App.ico"; } }
        sealed class BrokenIcons : IDiskExplorerIcons { public string PathFor(DiskExplorerKind k) { return "/icons/" + k + ".ico"; } public string ApplicationPath() { throw new IOException("the icon cannot be drawn"); } }
        sealed class Notify : IDiskExplorerNotifier { internal int Count; public void Changed(string path) { Count++; } }
        static DiskExplorerService Service(TestFiles fs) { return new DiskExplorerService(fs, new Icons(), new Notify(), delegate { }); }
        // Ошибка одной папки не красит весь Диск; папка, снятая сервером, не ошибка, а новая, ещё не принятая, не «удалена».
        static void FolderErrorsAndRemoval(string temp)
        {
            var local = Map("{\"state\":\"idle\",\"globalBytes\":100,\"needBytes\":0,\"needTotalItems\":0}");
            var remote = Map("{\"completion\":100,\"needBytes\":0,\"needItems\":0,\"needDeletes\":0,\"remoteState\":\"notSharing\"}");
            var row = new DiskFolderState();
            Check(DiskSnapshot.Status(row, local, remote, true, true).Kind == DiskExplorerKind.ServerRemoved && row.Tooltip == "Удалена на сервере, локальная копия сохранена", "confirmed folder the server stopped sharing is «removed on server»");
            Check(DiskSnapshot.Status(row, local, remote, true, false).Kind == DiskExplorerKind.Pending, "a new folder the server has not accepted yet is waiting, not removed");
            Check(DiskSnapshot.Status(row, local, remote, false, true).Kind == DiskExplorerKind.Offline, "without a connection nothing is known about the server");
            local["pullErrors"] = 2; local["error"] = "folder path missing";
            Check(DiskSnapshot.Status(row, local, remote, true, true).Kind == DiskExplorerKind.ServerRemoved && row.Detail.Length == 0, "removal on the server is not an error");
            Check(DiskSnapshot.Status(row, local, remote, true, false).Kind == DiskExplorerKind.Error, "an error of a folder the server never confirmed stays an error of that folder");
            remote["remoteState"] = "valid"; Check(DiskSnapshot.Status(row, local, remote, true, true).Kind == DiskExplorerKind.Error, "a folder the server still shares keeps its error");
            var store = new TestRegistry(); var registry = new DiskExplorerRegistry(store, delegate { });
            registry.Register(@"C:\app.exe", @"C:\Disk", new[] { new DiskFolderState { Path = @"C:\Disk\Gone", Kind = DiskExplorerKind.ServerRemoved }, new DiskFolderState { Path = @"C:\Disk\Live", Kind = DiskExplorerKind.Synced } });
            string keep = store.Read(DiskExplorerRegistry.Prefix + "keep-server", "AppliesTo");
            Check(keep.Contains(@"C:\Disk\Live") && !keep.Contains("Gone"), "«Оставить только на сервере» is not offered on a folder the server removed");
            // Read: одна папка в ошибке, одна снята сервером, одна новая; память «сервер подтверждал» живёт в диске программы.
            string diskHome = Path.Combine(temp, "state"), root = Path.Combine(temp, "Disk"); Directory.CreateDirectory(diskHome);
            var rest = new FakeRest();
            Func<string, Dictionary<string, object>> folder = id => Map("{\"id\":\"" + id + "\",\"label\":\"" + id + "\",\"path\":" + Json.Encode(Path.Combine(root, id)) + ",\"devices\":[{\"deviceID\":\"SERVER\"}]}");
            foreach (string id in new[] { "ok", "broken", "gone" }) rest.Folders.Add(folder(id));
            rest.LocalOf["broken"] = Map("{\"state\":\"error\",\"error\":\"folder path missing\",\"globalBytes\":100,\"needBytes\":0,\"needTotalItems\":0}");
            var snapshot = new DiskRestModel(rest, diskHome).Read(root, None);
            Func<string, DiskExplorerKind> kind = id => snapshot.Folders.Single(f => f.Id == id).Kind;
            Check(kind("ok") == DiskExplorerKind.Synced && kind("broken") == DiskExplorerKind.Error && snapshot.Folders.Single(f => f.Id == "broken").Tooltip.Contains("folder path missing"), "one folder in error: the others stay synchronized");
            Check(File.Exists(Path.Combine(diskHome, "explorer-confirmed.json")) && DiskConfirmedFolders.Load(diskHome, "SERVER").SetEquals(new[] { "ok", "broken", "gone" }), "folders confirmed by the server are remembered");
            rest.RemoteOf["gone"] = Map("{\"completion\":100,\"needBytes\":0,\"needItems\":0,\"needDeletes\":0,\"remoteState\":\"notSharing\"}");
            rest.Folders.Add(folder("fresh")); rest.RemoteOf["fresh"] = Map("{\"completion\":0,\"needBytes\":0,\"needItems\":0,\"needDeletes\":0,\"remoteState\":\"notSharing\"}");
            snapshot = new DiskRestModel(rest, diskHome).Read(root, None);
            Check(kind("gone") == DiskExplorerKind.ServerRemoved && kind("fresh") == DiskExplorerKind.Pending && kind("ok") == DiskExplorerKind.Synced, "removed on server vs. new and unconfirmed vs. working");
            Check(DiskConfirmedFolders.Load(diskHome, "SERVER").Contains("gone") && !DiskConfirmedFolders.Load(diskHome, "SERVER").Contains("fresh"), "the memory keeps a removed folder and does not invent a new one");
            rest.Connected = false; Check(ReadKinds(rest, diskHome, root)["gone"] == DiskExplorerKind.Offline, "no connection: nothing is «removed on server»"); rest.Connected = true;
            Check(new DiskRestModel(rest).Read(root, None).Folders.Single(f => f.Id == "gone").Kind == DiskExplorerKind.Pending, "without the memory a removed folder cannot be told from a new one and is not shown as an error");
            Check(DiskConfirmedFolders.Load(diskHome, "OTHER").Count == 0, "the memory belongs to one server");
            rest.Folders.RemoveAll(f => Json.Str(f, "id") == "gone"); new DiskRestModel(rest, diskHome).Read(root, None);
            Check(!DiskConfirmedFolders.Load(diskHome, "SERVER").Contains("gone"), "a folder deleted on the computer is forgotten");
        }
        static Dictionary<string, DiskExplorerKind> ReadKinds(FakeRest rest, string diskHome, string root)
        { return new DiskRestModel(rest, diskHome).Read(root, None).Folders.GroupBy(f => f.Id).ToDictionary(g => g.Key, g => g.First().Kind); }
        static void Metadata(string root)
        {
            var fs = new TestFiles(); var service = Service(fs);
            var row = new DiskFolderState { Id = "opaque-id", Name = "Проект", Path = Path.Combine(root, "Проект"), ServerOnly = true, Kind = DiskExplorerKind.ServerOnly };
            service.Reconcile(root, new[] { row });
            Check(service.IsPlaceholder(row.Path), "pending creates owned empty placeholder");
            string ini = Path.Combine(row.Path, "desktop.ini");
            Check(File.ReadAllBytes(ini).Take(2).SequenceEqual(new byte[] { 255, 254 }) && fs.Read(ini).Contains("\r\nOwner=RemoteAgents.Disk.v2\r\n"), "Unicode desktop.ini with CRLF and new ownership");
            Check((fs.Attributes(row.Path) & FileAttributes.ReadOnly) != 0 && (fs.Attributes(ini) & (FileAttributes.Hidden | FileAttributes.System)) != 0, "Explorer customization attributes");
            int writes = fs.Writes; service.Reconcile(root, new[] { row }); Check(fs.Writes == writes, "unchanged metadata not rewritten");
            string hint = fs.Read(ini);
            Check(hint.Contains("\r\nInfoTip=Только на сервере. Правый клик → Скачать на компьютер\r\n"), "placeholder hint names the menu item to click");
            fs.Write(ini, hint.Replace("Скачать на компьютер", "Забрать с сервера")); writes = fs.Writes; service.Reconcile(root, new[] { row });
            Check(fs.Read(ini).Replace("\r", "") == hint.Replace("\r", "") && fs.Writes == writes + 1, "hint left by the previous version is refreshed");
            File.WriteAllText(Path.Combine(row.Path, "user.txt"), "keep"); service.Reconcile(root, new[] { row });
            Check(!service.IsPlaceholder(row.Path) && fs.Read(ini).Contains("LocalCopy.ico") && fs.Read(ini).Contains("Локальная копия, не синхронизируется"), "local data becomes a neutral local copy without an error badge");
            service.CleanupFolder(row.Path, true);
            Check(File.ReadAllText(Path.Combine(row.Path, "user.txt")) == "keep" && !File.Exists(ini) && (fs.Attributes(row.Path) & FileAttributes.ReadOnly) == 0, "cleanup preserves data and restores read-only");
            string foreign = Path.Combine(root, "foreign"); Directory.CreateDirectory(foreign); File.WriteAllText(Path.Combine(foreign, "desktop.ini"), "foreign\r\n");
            Check(!service.MarkPlaceholder(foreign), "foreign desktop.ini not claimed");
            service.Reconcile(root, new[] { new DiskFolderState { Path = foreign, Kind = DiskExplorerKind.Synced } });
            Check(File.ReadAllText(Path.Combine(foreign, "desktop.ini")) == "foreign\r\n", "foreign metadata preserved");
            string link = Path.Combine(root, "link"); Directory.CreateDirectory(link); fs.Attributes(link, FileAttributes.Directory | FileAttributes.ReparsePoint);
            Check(!service.MarkPlaceholder(link), "junction placeholder refused");
            string readOnly = Path.Combine(root, "readonly"); Directory.CreateDirectory(readOnly); fs.Attributes(readOnly, FileAttributes.Directory | FileAttributes.ReadOnly | FileAttributes.Hidden);
            service.Reconcile(root, new[] { new DiskFolderState { Path = readOnly, Kind = DiskExplorerKind.Synced } }); service.CleanupFolder(readOnly);
            Check((fs.Attributes(readOnly) & (FileAttributes.ReadOnly | FileAttributes.Hidden)) == (FileAttributes.ReadOnly | FileAttributes.Hidden), "original unrelated attributes restored");
            string empty = Path.Combine(root, "empty"); Check(service.MarkPlaceholder(empty), "eviction placeholder created");
            Check(fs.Read(Path.Combine(empty, "desktop.ini")).Contains("→ Скачать на компьютер"), "eviction placeholder carries the same hint");
            service.CleanupFolder(empty, true); Check(!Directory.Exists(empty), "only owned empty placeholder can be removed");
        }
        static void LocalCopies(string temp)
        {
            string root = Path.Combine(temp, "Disk"), home = Path.Combine(temp, "state"), path = Path.Combine(root, "BackendLaravel");
            Directory.CreateDirectory(Path.Combine(path, ".stfolder")); File.WriteAllText(Path.Combine(path, "local.txt"), "local copy");
            var rest = new FakeRest(); rest.Offer("server-id", "BackendLaravel");
            var service = Service(new TestFiles()); var commands = new DiskShellCommands(rest, root, service, new DiskPlaceholderCatalog(home), "(?i).git\r\n/desktop.ini\r\n", p => { throw new Exception("never recycle a local copy"); });
            var snapshot = commands.Read(None); var row = snapshot.Folders.Single();
            Check(row.Kind == DiskExplorerKind.LocalCopy && row.Tooltip == DiskMenu.LocalCopyHint && row.ServerOnly, "old installation files without a registration have a separate neutral state");
            service.Reconcile(root, snapshot.Folders);
            Check(File.ReadAllText(Path.Combine(path, "desktop.ini")).Contains("LocalCopy.ico") && !service.IsPlaceholder(path), "local copy has a plain folder icon and cannot become an empty cloud");
            var store = new TestRegistry(); var registry = new DiskExplorerRegistry(store, delegate { });
            registry.Register("/app.exe", root, snapshot.Folders);
            string prefix = DiskExplorerRegistry.Prefix;
            Check(store.Read(prefix + "sync", "MUIVerb") == "Синхронизировать с сервером" && store.Read(prefix + "sync", "Icon") == "\"/app.exe\",0", "explicit merge menu item uses the program icon");
            Check(store.Read(prefix + @"sync\command", "").Contains("--disk-shell sync") && Applies(store.Read(prefix + "sync", "AppliesTo"), path) && !Applies(store.Read(prefix + "add", "AppliesTo"), path) && !store.Exists(prefix + "download") && !store.Exists(prefix + "keep-server"), "local copy offers merge only, no misleading download/upload/eviction item");
            Check(!rest.Calls.Any(c => c.StartsWith("POST") || c.StartsWith("DELETE")), "read/reconcile never automatically accepts a populated copy");
            Reject(() => commands.Execute(new DiskShellRequest { Action = "download", Path = path }, None), "download still requires an empty owned placeholder");
            string message = commands.Execute(DiskShellRequest.Parse(new[] { "--disk-shell", "sync", path }), None);
            var config = rest.Folders.Single();
            Check(message.Contains("Слияние") && Json.Str(config, "id") == "server-id" && DiskPaths.Same(Json.Str(config, "path"), path), "explicit merge keeps offered ID and existing path");
            Check(Json.Str(config, "type") == "sendreceive" && Json.Int(config, "maxConflicts", 0) == -1 && Json.Str(Json.Map(Json.Get(config, "versioning")), "type") == "staggered", "merge uses existing bidirectional acceptance with unlimited conflicts and versioning");
            Check(File.ReadAllText(Path.Combine(path, "local.txt")) == "local copy" && Directory.Exists(Path.Combine(path, ".stfolder")), "acceptance leaves original files and old Syncthing marker intact");
            registry.Register("/app.exe", root, commands.Read(None).Folders);
            Check(!store.Exists(prefix + "sync") && store.Exists(prefix + "keep-server"), "registered copy moves from merge menu to synchronized-folder menu");
            Reject(() => commands.Execute(new DiskShellRequest { Action = "sync", Path = path }, None), "stale merge command cannot replace a registration");
            registry.Cleanup(); Check(store.Values.Count == 0, "cleanup removes the merge menu along with other owned verbs");
        }
        internal sealed class TestRegistry : IDiskExplorerRegistry
        {
            internal readonly Dictionary<string, string> Values = new Dictionary<string, string>(); internal int Writes;
            public bool Exists(string k) { lock (Values) return Values.Keys.Any(v => v.StartsWith(k + "|", StringComparison.Ordinal)); }
            public string Read(string k, string n) { lock (Values) { string v; return Values.TryGetValue(k + "|" + n, out v) ? v : null; } }
            public void Write(string k, string n, string v) { lock (Values) { Values[k + "|" + n] = v; Writes++; } }
            public void DeleteTree(string k) { lock (Values) foreach (string v in Values.Keys.Where(v => v.StartsWith(k + "|", StringComparison.Ordinal) || v.StartsWith(k + "\\", StringComparison.Ordinal)).ToArray()) Values.Remove(v); }
        }
        static void Registry()
        {
            var store = new TestRegistry(); int changes = 0; var registry = new DiskExplorerRegistry(store, delegate { }, () => changes++);
            var rows = new[] { new DiskFolderState { Path = @"C:\Disk\Проект", ServerOnly = true, Kind = DiskExplorerKind.ServerOnly }, new DiskFolderState { Path = @"D:\External", Kind = DiskExplorerKind.Synced } };
            registry.Register(@"C:\App Name\RemoteAgents.exe", @"C:\Disk", rows, @"C:\User Home"); string p = DiskExplorerRegistry.Prefix;
            Check(store.Read(p + @"download\command", "") == "\"C:\\App Name\\RemoteAgents.exe\" --home \"C:\\User Home\" --disk-shell download \"%1\"", "quoted executable / home / clicked path");
            Check(store.Read(p + "download", "AppliesTo").Contains(@"C:\Disk\Проект") && store.Read(p + "keep-server", "AppliesTo").Contains(@"D:\External"), "verbs scoped to actual folder paths");
            Check(store.Read(p + "add", "MUIVerb") == "Загрузить на сервер" && !store.Read(p + "add", "AppliesTo").Contains("~<"), "upload available inside and outside Disk");
            int writes = store.Writes; registry.Register(@"C:\App Name\RemoteAgents.exe", @"C:\Disk", rows, @"C:\User Home");
            Check(store.Writes == writes && changes == 1, "registry updates are idempotent");
            registry.Cleanup(); Check(store.Values.Count == 0, "owned HKCU keys removed");
            store.Write(p + "add", "RemoteAgentsOwner", "foreign"); registry.Register(@"C:\app.exe", @"C:\Disk", rows); registry.Cleanup();
            Check(store.Read(p + "add", "RemoteAgentsOwner") == "foreign", "foreign registry owner preserved");
            Reject(() => registry.Register("bad\r\nexe", @"C:\Disk", rows), "command injection rejected");
        }
        static void Require(bool ok, string message) { if (!ok) throw new Exception("Disk Explorer: " + message); }
        static string ParentOf(string path)
        { string parent = path.Substring(0, path.LastIndexOfAny(new[] { '\\', '/' })); return parent.Length == 2 && parent[1] == ':' ? parent + "\\" : parent; }
        // Evaluates the AQS the menu items use and nothing else. A folder list «(T OR T ...)» is true when a term equals the folder path.
        // The upload condition «NOT T AND NOT T ...» is true when no term does. A term compares either the path of
        // the folder (ItemPathDisplay) or the path of its parent (ItemFolderPathDisplay). Anything of another shape fails the test.
        static bool Applies(string aqs, string path)
        {
            string shape = Regex.Replace(aqs, "System\\.\\w+:=\"[^\"]*\"", "T");
            bool upload = Regex.IsMatch(shape, @"^NOT T( AND NOT T)*$");
            Require(upload || Regex.IsMatch(shape, @"^\(T( OR T)*\)$"), "menu condition has an unexpected shape: " + shape);
            bool any = false;
            foreach (Match term in Regex.Matches(aqs, "System\\.(\\w+):=\"([^\"]*)\"")) {
                string property = term.Groups[1].Value;
                Require(property == "ItemPathDisplay" || property == "ItemFolderPathDisplay", "unexpected AQS property " + property);
                any |= string.Equals(term.Groups[2].Value, property == "ItemPathDisplay" ? path : ParentOf(path), StringComparison.OrdinalIgnoreCase);
            }
            return upload ? !any : any;
        }
        // The three Explorer items: their names and which of them a folder is offered.
        static void Menu()
        {
            const string exe = @"C:\App Name\RemoteAgents.exe", home = @"C:\User Home";
            string p = DiskExplorerRegistry.Prefix; string[] verbs = { "download", "keep-server", "add" };
            Check(DiskMenu.Download == "Скачать на компьютер" && DiskMenu.KeepServer == "Оставить только на сервере" && DiskMenu.Upload == "Загрузить на сервер", "menu item names");
            Check(new DiskFolderState { Kind = DiskExplorerKind.ServerOnly }.Tooltip == "Только на сервере. Правый клик → Скачать на компьютер", "placeholder hint names the item to click");
            var store = new TestRegistry(); var registry = new DiskExplorerRegistry(store, delegate { });
            string disk = @"C:\Disk", placeholder = disk + @"\Проект", inDisk = disk + @"\Сайт", outside = @"D:\External", plain = @"E:\Plain", receiveOnly = @"F:\Receive", restored = @"G:\Restored";
            var rows = new[] {
                new DiskFolderState { Path = placeholder, ServerOnly = true, Kind = DiskExplorerKind.ServerOnly },
                new DiskFolderState { Path = inDisk, Kind = DiskExplorerKind.Synced, Config = Map("{\"type\":\"sendreceive\"}") },
                new DiskFolderState { Path = outside, Kind = DiskExplorerKind.Syncing, Config = Map("{\"type\":\"sendreceive\"}") },
                new DiskFolderState { Path = plain, Kind = DiskExplorerKind.Local, Config = Map("{\"type\":\"sendreceive\"}") },
                new DiskFolderState { Path = receiveOnly, Kind = DiskExplorerKind.LocalChanges, Config = Map("{\"type\":\"receiveonly\"}") },
                new DiskFolderState { Path = restored, Kind = DiskExplorerKind.Unavailable } };
            registry.Register(exe, disk, rows, home);
            Check(store.Read(p + "download", "MUIVerb") == "Скачать на компьютер" && store.Read(p + "keep-server", "MUIVerb") == "Оставить только на сервере" && store.Read(p + "add", "MUIVerb") == "Загрузить на сервер", "menu labels");
            Check(!store.Values.Values.Any(v => v.Contains("Забрать")), "the old item name is gone from the registry");
            Func<string, string[]> offered = path => verbs.Where(v => store.Exists(p + v) && Applies(store.Read(p + v, "AppliesTo"), path)).ToArray();
            Check(offered(disk).Length == 0, "no item on the Disk root");
            Check(offered(placeholder).SequenceEqual(new[] { "download" }), "placeholder: only «Скачать на компьютер»");
            Check(offered(inDisk).SequenceEqual(new[] { "keep-server" }) && offered(outside).SequenceEqual(new[] { "keep-server" }), "syncing folder in Disk or outside it: only «Оставить только на сервере»");
            Check(offered(plain).SequenceEqual(new[] { "add" }), "a folder Syncthing knows but has not shared with the server can still be uploaded");
            Check(offered(receiveOnly).SequenceEqual(new[] { "keep-server", "add" }), "a shared receive-only folder keeps the upload item: it turns the folder into send and receive");
            Check(offered(restored).SequenceEqual(new[] { "keep-server" }), "state restored without a Syncthing config counts as uploading");
            Check(offered(disk + @"\Новая").SequenceEqual(new[] { "add" }) && offered(@"D:\Проекты\X").SequenceEqual(new[] { "add" }), "ordinary folder in Disk or anywhere else: only «Загрузить на сервер»");
            // The condition is stable: the order of folders and the move placeholder -> syncing do not change it (no needless Explorer refresh).
            string scope = store.Read(p + "add", "AppliesTo");
            registry.Register(exe, disk, rows.Reverse().ToArray(), home);
            Check(store.Read(p + "add", "AppliesTo") == scope, "upload condition does not depend on the order of folders");
            var accepted = rows.Select(r => r.Copy()).ToArray(); accepted[0].ServerOnly = false; accepted[0].Kind = DiskExplorerKind.Syncing;
            registry.Register(exe, disk, accepted, home);
            Check(store.Read(p + "add", "AppliesTo") == scope && !store.Exists(p + "download") && Applies(store.Read(p + "keep-server", "AppliesTo"), placeholder), "a downloaded placeholder keeps the upload condition and moves to «Оставить только на сервере»");
            var empty = new TestRegistry(); new DiskExplorerRegistry(empty, delegate { }).Register(exe, disk, new DiskFolderState[0], home);
            Check(!empty.Exists(p + "download") && !empty.Exists(p + "keep-server") && empty.Read(p + "add", "AppliesTo") == "NOT System.ItemPathDisplay:=\"" + disk + "\"", "no folders: only the Disk root is excluded from upload");
            Check(DiskExplorerRegistry.UploadScope(@"C:\Disk\", new[] { placeholder }) == DiskExplorerRegistry.UploadScope(disk, new[] { placeholder }), "closing backslash of the root does not matter");
            // Too many folders for one registry value: the list is cut by the safe variant, exactly once, and always within the limit.
            bool safe = false;
            for (int n = 1; n <= 100; n++) {
                string text = DiskExplorerRegistry.UploadScope(disk, Enumerable.Range(1, n).Select(i => disk + @"\Проект-" + i));
                bool listed = !text.Contains("ItemFolderPathDisplay");
                Require(text.Length <= DiskExplorerRegistry.MaxAppliesTo, "upload condition longer than the limit for " + n + " folders");
                Require(!(safe && listed), "the safe variant must not switch back to the full list");
                Require(n > 5 || listed, "a short list of folders is spelled out in full");
                safe |= !listed;
            }
            Check(safe, "a long list of folders switches to the safe variant");
            var many = Enumerable.Range(1, 60).Select(i => new DiskFolderState { Path = disk + @"\Проект-" + i, ServerOnly = true, Kind = DiskExplorerKind.ServerOnly }).ToList();
            many.Add(new DiskFolderState { Path = outside, Kind = DiskExplorerKind.Synced });
            var big = new TestRegistry(); new DiskExplorerRegistry(big, delegate { }).Register(exe, disk, many, home);
            string compact = big.Read(p + "add", "AppliesTo");
            Check(compact.Length <= DiskExplorerRegistry.MaxAppliesTo && compact.Contains("System.ItemFolderPathDisplay:=\"" + disk + "\"") && !compact.Contains("Проект-33"), "safe variant: every direct child of Disk is hidden as a whole");
            Check(!Applies(compact, disk) && !Applies(compact, disk + @"\Проект-33") && !Applies(compact, outside), "safe variant: root, placeholders and the listed outside folder have no upload item");
            Check(Applies(compact, @"D:\Other") && Applies(compact, @"D:\Проекты\X"), "safe variant: folders outside Disk are still offered the upload item");
            Check(!Applies(compact, disk + @"\Новая"), "safe variant: the price is that a brand-new folder placed directly in Disk is not offered the upload item");
            var notes = new List<string>(); var noisy = new DiskExplorerRegistry(new TestRegistry(), notes.Add);
            noisy.Register(exe, disk, many, home); noisy.Register(exe, disk, many, home);
            Check(notes.Count == 1 && notes[0].Contains("слишком много"), "the switch to the safe variant is journalled once, not on every refresh");
            // Even the outside list does not fit: it is left out; the command itself answers that such a folder already syncs.
            var far = Enumerable.Range(1, 100).Select(i => new DiskFolderState { Path = @"D:\Много\Папка-" + i, Kind = DiskExplorerKind.Synced }).ToList();
            var farStore = new TestRegistry(); new DiskExplorerRegistry(farStore, delegate { }).Register(exe, disk, far, home);
            string bounded = farStore.Read(p + "add", "AppliesTo");
            Check(bounded.Length <= DiskExplorerRegistry.MaxAppliesTo && !Applies(bounded, disk + @"\Проект") && Applies(bounded, @"D:\Другая"), "outside folders left out of an oversized condition; the Disk children stay hidden");
            string driveScope = DiskExplorerRegistry.UploadScope(@"C:\", Enumerable.Range(1, 80).Select(i => @"C:\Папка-" + i));
            Check(driveScope.Length <= DiskExplorerRegistry.MaxAppliesTo && !Applies(driveScope, @"C:\Папка-5") && !Applies(driveScope, @"C:\") && Applies(driveScope, @"D:\Папка-5"), "a drive root works as the Disk root");
        }
        // All three items carry the program's icon exported as a file; without it they fall back to the program file.
        static void MenuIcon()
        {
            const string exe = @"C:\App Name\RemoteAgents.exe", home = @"C:\User Home", disk = @"C:\Disk", icon = @"C:\Users\User\AppData\Local\RemoteDisk\explorer-icons\RemoteAgents.Disk.v2.App.ico";
            string p = DiskExplorerRegistry.Prefix; string[] verbs = { "download", "keep-server", "add" };
            var rows = new[] { new DiskFolderState { Path = disk + @"\Проект", ServerOnly = true, Kind = DiskExplorerKind.ServerOnly }, new DiskFolderState { Path = @"D:\External", Kind = DiskExplorerKind.Synced } };
            var store = new TestRegistry(); int changes = 0; var registry = new DiskExplorerRegistry(store, delegate { }, () => changes++);
            registry.Register(exe, disk, rows, home, icon);
            Check(verbs.All(v => store.Read(p + v, "Icon") == "\"" + icon + "\",0"), "all three items carry the application icon");
            changes = 0; registry.Register(exe, disk, rows, home, icon);
            Check(changes == 0, "the same icon does not refresh Explorer again");
            registry.Register(exe, disk, rows, home, @"C:\Other\icon.ico");
            Check(changes == 1 && verbs.All(v => store.Read(p + v, "Icon") == "\"C:\\Other\\icon.ico\",0"), "a new icon file updates every item and refreshes Explorer once");
            var bare = new TestRegistry(); new DiskExplorerRegistry(bare, delegate { }).Register(exe, disk, rows, home);
            Check(verbs.All(v => bare.Read(p + v, "Icon") == "\"" + exe + "\",0"), "without an exported icon the items use the program file");
            Reject(() => registry.Register(exe, disk, rows, home, "bad\r\nicon.ico"), "icon path injection rejected");
        }
        static string SourceDirectory([CallerFilePath] string file = "") { return Path.GetDirectoryName(file); }
        static readonly byte[] PngSignature = { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
        sealed class IconFrame { internal int Side, Bits, Length, Offset; }
        static IconFrame[] Frames(byte[] ico)
        {
            return Enumerable.Range(0, BitConverter.ToUInt16(ico, 4)).Select(i => new IconFrame {
                Side = ico[6 + 16 * i] == 0 ? 256 : ico[6 + 16 * i], Bits = BitConverter.ToUInt16(ico, 12 + 16 * i), Length = BitConverter.ToInt32(ico, 14 + 16 * i), Offset = BitConverter.ToInt32(ico, 18 + 16 * i) }).ToArray();
        }
        // The program's own icon: app.ico, built into the program and written as it is. Its picture is the tray dot.
        static void IconFile(string temp)
        {
            Directory.CreateDirectory(temp);
            string app = Path.Combine(temp, DiskExplorerService.ApplicationIconFile);
            DiskIconFile.ExportApplicationIcon(app); byte[] icon = File.ReadAllBytes(app);
            Check(icon.SequenceEqual(File.ReadAllBytes(Path.Combine(SourceDirectory(), "..", "app.ico"))), "the exported icon is app.ico of the repository, byte for byte");
            var entries = Frames(icon);
            Check(entries.Select(e => e.Side).SequenceEqual(new[] { 16, 20, 24, 32, 48, 256 }) && entries.All(e => e.Bits == 32 && e.Offset + e.Length <= icon.Length), "program icon: 16-48 px for menus and the taskbar at 100-300% scale, 256 px for large views, all 32-bit");
            int at = entries.Single(e => e.Side == 32).Offset;
            Check(BitConverter.ToInt32(icon, at) == 40 && BitConverter.ToInt32(icon, at + 4) == 32 && BitConverter.ToInt32(icon, at + 8) == 64 && BitConverter.ToUInt16(icon, at + 14) == 32, "the 32 px frame is a 32-bit bitmap");
            Func<int, int, byte[]> pixel = (x, y) => icon.Skip(at + 40 + ((31 - y) * 32 + x) * 4).Take(4).ToArray(); // B, G, R, A; rows are stored bottom-up
            Check(pixel(16, 16).SequenceEqual(new byte[] { 34, 139, 34, 255 }) && pixel(0, 0)[3] == 0 && pixel(4, 16)[3] == 255, "the picture is the tray dot: an opaque ForestGreen disc with transparent corners");
            Check(icon.Skip(entries.Last().Offset).Take(8).SequenceEqual(PngSignature), "the 256 px frame is PNG");
            DiskIconFile.ExportApplicationIcon(app);
            Check(File.ReadAllBytes(app).SequenceEqual(icon) && Directory.GetFileSystemEntries(temp).Length == 1, "export keeps an existing icon and leaves no temporary file");
            Reject(() => DiskIconFile.ExportApplicationIcon(Path.Combine(temp, "no-such-resource", "x.ico")) , "an unwritable target is reported, not ignored");
        }
        // The state icons: the files of app/launcher/icons, built into the program and written under names that carry the icon revision.
        static void StateIcons(string temp)
        {
            string dir = Path.Combine(temp, "explorer-icons"), source = Path.Combine(SourceDirectory(), "..", "icons");
            var provider = new DiskExplorerIcons(dir);
            var kinds = Enum.GetValues(typeof(DiskExplorerKind)).Cast<DiskExplorerKind>().ToArray();
            Check(kinds.All(k => File.Exists(Path.Combine(source, k + ".ico"))) && Directory.GetFiles(source, "*.ico").Length == kinds.Length, "every folder state has an icon file, and no icon exists for an unknown state");
            Check(kinds.All(k => File.ReadAllBytes(provider.PathFor(k)).SequenceEqual(File.ReadAllBytes(Path.Combine(source, k + ".ico")))), "the program writes the icon files of app/launcher/icons as they are");
            Check(DiskExplorerService.IconRevision >= 2 && kinds.All(k => Path.GetFileName(provider.PathFor(k)) == "RemoteAgents.Disk.v2.r" + DiskExplorerService.IconRevision + "." + k + ".ico"), "state icon files carry the icon revision in their name");
            Check(kinds.All(k => Path.GetFileName(provider.PathFor(k)) != DiskExplorerService.Owner + "." + k + ".ico"), "the names differ from those of the first icons, so Explorer cannot show a cached old picture");
            Check(Directory.GetFiles(dir).Length == kinds.Length && !Directory.GetFiles(dir).Any(f => f.EndsWith(".tmp")), "one file per state and no temporary file; a repeated request writes nothing new");
            var written = kinds.Select(k => File.ReadAllBytes(provider.PathFor(k))).ToArray();
            Check(written.All(b => { var f = Frames(b); return f.Select(e => e.Side).SequenceEqual(new[] { 16, 20, 24, 32, 48, 256 }) && f.All(e => e.Bits == 32 && e.Offset + e.Length <= b.Length && b.Skip(e.Offset).Take(8).SequenceEqual(PngSignature)); }), "every state icon has 16-48 px frames for lists and tiles and a 256 px frame for large icons, all 32-bit PNG");
            Check(File.ReadAllBytes(provider.PathFor(DiskExplorerKind.Offline)).SequenceEqual(File.ReadAllBytes(provider.PathFor(DiskExplorerKind.Unavailable))) && !File.ReadAllBytes(provider.PathFor(DiskExplorerKind.Synced)).SequenceEqual(File.ReadAllBytes(provider.PathFor(DiskExplorerKind.Error))), "offline and unavailable share a picture; the other states differ");
            // Update from the first icons: a folder decorated before points to the old file; the next reconcile points it to the new one.
            string home = Path.Combine(temp, "update"), root = Path.Combine(home, "Disk"), icons = Path.Combine(home, "explorer-icons"), project = Path.Combine(root, "Проект");
            Directory.CreateDirectory(icons); Directory.CreateDirectory(project);
            string old = Path.Combine(icons, "RemoteAgents.Disk.v2.ServerOnly.ico"); File.WriteAllText(old, "the first picture");
            var fs = new TestFiles();
            fs.Write(Path.Combine(project, "desktop.ini"), "[.ShellClassInfo]\r\nIconResource=" + old + ",0\r\nInfoTip=Только на сервере. Правый клик → Забрать с сервера\r\n[RemoteAgents]\r\nOwner=RemoteAgents.Disk.v2\r\nOriginalReadOnly=0\r\nPlaceholder=1\r\nCreatedDirectory=1\r\n");
            var service = new DiskExplorerService(fs, new DiskExplorerIcons(icons), new Notify(), delegate { });
            service.Reconcile(root, new[] { new DiskFolderState { Id = "id", Name = "Проект", Path = project, ServerOnly = true, Kind = DiskExplorerKind.ServerOnly } });
            string ini = fs.Read(Path.Combine(project, "desktop.ini")), current = Path.Combine(icons, "RemoteAgents.Disk.v2.r" + DiskExplorerService.IconRevision + ".ServerOnly.ico");
            Check(ini.Contains("IconResource=" + current + ",0") && !ini.Contains(old) && File.Exists(current), "a folder decorated with the first icons points to the new file after the next reconcile");
            Check(ini.Contains("Скачать на компьютер") && !ini.Contains("Забрать с сервера") && File.ReadAllText(old) == "the first picture", "the hint is refreshed in the same pass; the old icon file is left alone until uninstall");
            // Uninstall removes our icons of every revision and the program's icon, and nothing else.
            string stale = Path.Combine(temp, "cleanup"); Directory.CreateDirectory(stale);
            foreach (var kind in kinds) foreach (string name in new[] { DiskExplorerService.Owner + "." + kind + ".ico", DiskExplorerService.Owner + ".r2." + kind + ".ico", DiskExplorerService.Owner + ".r9." + kind + ".ico" }) File.WriteAllText(Path.Combine(stale, name), "own");
            File.WriteAllText(Path.Combine(stale, DiskExplorerService.ApplicationIconFile), "own");
            var foreign = new[] { "foreign.ico", "RemoteAgents.Disk.v1.Synced.ico", "RemoteAgents.Disk.v2.Unknown.ico", "RemoteAgents.Disk.v2.r2.Synced.ico.bak" };
            foreach (string name in foreign) File.WriteAllText(Path.Combine(stale, name), "foreign");
            DiskIconFile.Cleanup(stale); DiskIconFile.Cleanup(Path.Combine(temp, "missing"));
            Check(Directory.GetFiles(stale).Select(Path.GetFileName).OrderBy(n => n, StringComparer.Ordinal).SequenceEqual(foreign.OrderBy(n => n, StringComparer.Ordinal)), "uninstall removes our icons of every revision and the application icon, nothing else");
            Check(DiskExplorerService.ApplicationIconFile == "RemoteAgents.Disk.v2.App.ico" && !Enum.GetNames(typeof(DiskExplorerKind)).Contains("App"), "the application icon file name cannot collide with a state icon");
        }
        internal sealed class FakeRest : IDiskRest
        {
            public string Peer { get { return "SERVER"; } }
            internal readonly List<Dictionary<string, object>> Folders = new List<Dictionary<string, object>>();
            internal readonly Dictionary<string, object> Pending = new Dictionary<string, object>();
            internal readonly List<string> Calls = new List<string>();
            internal Action OnScan, OnFoldersRead; internal Action<int> OnStatus; int statusReads;
            internal bool FailPost, Connected = true, FailDelete, AppliedThenTimeout, FailVerify;
            bool verifying;
            internal Dictionary<string, object> Local = Map("{\"state\":\"idle\",\"globalBytes\":100,\"needBytes\":0,\"needTotalItems\":0,\"sequence\":1}");
            internal Dictionary<string, object> Remote = Map("{\"completion\":100,\"needBytes\":0,\"needItems\":0,\"needDeletes\":0,\"remoteState\":\"valid\"}");
            // Answers of single folders (by id); a folder without an entry gets Local / Remote.
            internal readonly Dictionary<string, Dictionary<string, object>> LocalOf = new Dictionary<string, Dictionary<string, object>>(), RemoteOf = new Dictionary<string, Dictionary<string, object>>();
            static string FolderOf(string route) { string v = route.Substring(route.IndexOf("folder=") + 7); int amp = v.IndexOf('&'); return Uri.UnescapeDataString(amp < 0 ? v : v.Substring(0, amp)); }
            internal void Offer(string id, string label, string peer = "SERVER") { Pending[id] = new Dictionary<string, object> { { "offeredBy", new Dictionary<string, object> { { peer, new Dictionary<string, object> { { "label", label } } } } } }; }
            public object Request(string method, string route, object body, CancellationToken token, int timeout = 3000)
            {
                token.ThrowIfCancellationRequested(); lock (Calls) Calls.Add(method + " " + route);
                if (route == "system/connections") return new Dictionary<string, object> { { "connections", new Dictionary<string, object> { { Peer, new { connected = Connected } } } } }.ToPortable();
                if (route == "config/folders" && method == "GET") { if (OnFoldersRead != null) OnFoldersRead(); if (FailVerify && verifying) { verifying = false; throw new IOException("verification lost"); } verifying = false; return Folders.ToArray(); }
                if (route.StartsWith("cluster/pending/folders")) return Pending;
                if (route.StartsWith("db/scan") && method == "POST") { if (OnScan != null) OnScan(); return null; }
                 if (route.StartsWith("db/status")) { if (OnStatus != null) OnStatus(++statusReads); Dictionary<string, object> own; return new Dictionary<string, object>(LocalOf.TryGetValue(FolderOf(route), out own) ? own : Local); }
                if (route.StartsWith("db/completion")) { Dictionary<string, object> own; return RemoteOf.TryGetValue(FolderOf(route), out own) ? own : Remote; }
                if (route == "config/defaults/folder") return Map("{\"rescanIntervalS\":3600,\"fsWatcherEnabled\":true}");
                if (route == "system/status") return Map("{\"myID\":\"LOCAL\"}");
                if (route == "config/folders" && method == "POST") {
                    if (FailPost) { verifying = true; throw new IOException("rejected"); }
                    var row = Json.Map(Json.Parse(Json.Encode(body))); Folders.RemoveAll(f => Json.Str(f, "id") == Json.Str(row, "id")); Folders.Add(row);
                    Pending.Remove(Json.Str(row, "id")); if (AppliedThenTimeout) { AppliedThenTimeout = false; throw new IOException("timeout after commit"); } return null;
                }
                if (route.StartsWith("config/folders/") && method == "DELETE") {
                    if (FailDelete) throw new IOException("DELETE rejected");
                    string id = Uri.UnescapeDataString(route.Substring("config/folders/".Length)); Folders.RemoveAll(f => Json.Str(f, "id") == id); return null;
                }
                if (route.StartsWith("config/folders/") && method == "PATCH") { var patch = Json.Map(Json.Parse(Json.Encode(body))); foreach (var pair in patch) Folders.Single()[pair.Key] = pair.Value; return null; }
                throw new Exception("Unexpected REST: " + method + " " + route);
            }
        }
        static void Commands(string temp)
        {
            string root = Path.Combine(temp, "Disk"), diskHome = Path.Combine(temp, "state"); Directory.CreateDirectory(root);
            var rest = new FakeRest(); var fs = new TestFiles(); var service = Service(fs); var catalog = new DiskPlaceholderCatalog(diskHome);
            int recycled = 0; bool failRecycle = false;
            Action<string> recycle = path => { Check(!rest.Folders.Any(), "detach confirmed before recycle"); recycled++; if (failRecycle) throw new IOException(DiskRecycle.Refused); Directory.Move(path, path + ".recycled-" + recycled); };
            var commands = new DiskShellCommands(rest, root, service, catalog, "(?i).git\r\n(?i).env*\r\n(?i)/desktop.ini\r\n", recycle);
            rest.Offer("real-id-123", "Проект"); rest.Offer("alien-id", "Чужой", "OTHER"); rest.Offer("unsafe-id", "../escape");
            var initial = commands.Read(None); Check(initial.Folders.Count == 1 && initial.Folders[0].Id == "real-id-123", "only server offer, label distinct from ID, unsafe names excluded");
            service.Reconcile(root, initial.Folders); string project = Path.Combine(root, "Проект");
            string started = commands.Execute(new DiskShellRequest { Action = "download", Path = project }, None);
            Check(started == "Папка скачивается на компьютер. Синхронизация запущена", "download result names what happens");
            var config = rest.Folders.Single();
            Check(Json.Str(config, "id") == "real-id-123" && Json.Str(config, "label") == "Проект" && DiskPaths.Same(Json.Str(config, "path"), project), "accept uses pending ID and label path");
            Check(Json.Str(config, "type") == "sendreceive" && Json.Int(config, "fsWatcherDelayS", 0) == 2 && Json.Int(config, "maxConflicts", 0) == -1 && Json.Str(Json.Map(Json.Get(config, "versioning")), "type") == "staggered", "required folder options");
            Check(Json.Array(Json.Get(config, "devices")).Length == 2 && File.ReadAllText(Path.Combine(project, ".stignore")).Contains("#include .stignore-remoteagents"), "shared devices and exclusions before first scan");
            Check(!service.IsPlaceholder(project) && File.ReadAllText(Path.Combine(project, "desktop.ini")).Contains("Syncing.ico"), "accept immediately shows syncing");
            File.WriteAllText(Path.Combine(project, "data.txt"), "data");
            rest.Remote["completion"] = 99; Reject(() => commands.Execute(new DiskShellRequest { Action = "keep-server", Path = project }, None), "unsynced eviction rejected");
            rest.Remote["completion"] = 100; rest.FailDelete = true;
            Reject(() => commands.Execute(new DiskShellRequest { Action = "keep-server", Path = project }, None), "delete rejection never recycles"); Check(recycled == 0 && File.Exists(Path.Combine(project, "data.txt")), "data retained on REST failure");
            rest.FailDelete = false; failRecycle = true;
            string recycleFailure = "";
            try { commands.Execute(new DiskShellRequest { Action = "keep-server", Path = project }, None); } catch (IOException e) { recycleFailure = e.Message; }
            Check(recycleFailure == DiskRecycle.Refused, "full/unavailable bin is reported with instructions, no permanent fallback");
            Check(rest.Folders.Count == 1 && File.Exists(Path.Combine(project, "data.txt")), "registration restored after failed recycle");
            failRecycle = false; commands.Execute(new DiskShellRequest { Action = "keep-server", Path = project }, None);
            Check(rest.Folders.Count == 0 && service.IsPlaceholder(project) && File.ReadAllText(Path.Combine(project + ".recycled-2", "data.txt")) == "data", "successful eviction keeps files in recycle fixture and creates cloud");
            Check(commands.Read(None).Folders.Any(f => f.Id == "real-id-123" && f.ServerOnly), "evicted folder survives pending-offer delay");
            string namesake = Path.Combine(temp, "Elsewhere", "Проект"); Directory.CreateDirectory(namesake); string clash = "";
            try { commands.Execute(new DiskShellRequest { Action = "add", Path = namesake }, None); } catch (IOException e) { clash = e.Message; }
            Check(clash == "На Диске уже есть папка с таким именем; используйте «Скачать на компьютер»", "upload of a namesake points to the renamed download item");
            // External upload stays in place; CRLF user ignore bytes are retained.
            string external = Path.Combine(temp, "External"); Directory.CreateDirectory(external); File.WriteAllText(Path.Combine(external, "data.txt"), "external");
            File.WriteAllText(Path.Combine(external, ".stignore"), "custom\r\n", Files.Utf8);
            commands.Execute(new DiskShellRequest { Action = "add", Path = external }, None);
            Check(DiskPaths.Same(Json.Str(rest.Folders.Single(), "path"), external) && File.Exists(Path.Combine(external, "data.txt")), "external upload registered in place");
            Check(File.ReadAllText(Path.Combine(external, ".stignore")) == "custom\r\n#include .stignore-remoteagents\r\n", "user CRLF rules preserved");
            int posts = rest.Calls.Count(c => c == "POST config/folders"); commands.Execute(new DiskShellRequest { Action = "add", Path = external }, None);
            Check(rest.Calls.Count(c => c == "POST config/folders") == posts, "repeat upload idempotent");
            Reject(() => commands.Execute(new DiskShellRequest { Action = "add", Path = Path.Combine(external, "nested") }, None), "missing or overlapping source rejected");
            rest.Folders.Clear(); string rejected = Path.Combine(temp, "Rejected"); Directory.CreateDirectory(rejected); File.WriteAllText(Path.Combine(rejected, ".stignore"), "user\r\n", Files.Utf8);
            rest.FailPost = true; Reject(() => commands.Execute(new DiskShellRequest { Action = "add", Path = rejected }, None), "rejected POST reported");
            Check(File.ReadAllText(Path.Combine(rejected, ".stignore")) == "user\r\n" && !File.Exists(Path.Combine(rejected, ".stignore-remoteagents")), "failed registration rolls back only managed ignore additions");
            rest.FailPost = false; rest.AppliedThenTimeout = true; commands.Execute(new DiskShellRequest { Action = "add", Path = rejected }, None);
            Check(rest.Folders.Count == 1 && File.Exists(Path.Combine(rejected, ".stignore-remoteagents")), "timeout after applied POST reconciled locally");
            rest.Folders.Clear(); rest.FailPost = true; rest.FailVerify = true; string uncertain = Path.Combine(temp, "Uncertain"); Directory.CreateDirectory(uncertain);
            Reject(() => commands.Execute(new DiskShellRequest { Action = "add", Path = uncertain }, None), "unconfirmed write reported as uncertain");
            Check(File.Exists(Path.Combine(uncertain, ".stignore-remoteagents")) && File.ReadAllText(Path.Combine(uncertain, ".stignore")).Contains("#include"), "ambiguous write never removes first-scan exclusions");
            rest.FailPost = rest.FailVerify = false;
            // Sharing an existing registration keeps its path, other devices, and unrelated options.
            string existing = Path.Combine(temp, "Existing"); Directory.CreateDirectory(existing);
            rest.Folders.Add(new Dictionary<string, object> { { "id", "already-configured" }, { "label", "Existing" }, { "path", existing }, { "rescanIntervalS", 57 }, { "type", "receiveonly" }, { "devices", new[] { new { deviceID = "OTHER" } } } }.ToPortable() as Dictionary<string, object>);
            commands.Execute(new DiskShellRequest { Action = "add", Path = existing }, None);
            Check(Json.Int(rest.Folders.Single(), "rescanIntervalS", 0) == 57 && Json.Array(Json.Get(rest.Folders.Single(), "devices")).Select(Json.Map).Select(d => Json.Str(d, "deviceID")).OrderBy(d => d).SequenceEqual(new[] { "OTHER", "SERVER" }), "existing registration extended without replacing other devices/options");
            Check(Json.Str(rest.Folders.Single(), "type") == "sendreceive", "existing receiveonly registration enables upload");
            rest.Folders.Clear();
            string externalKeep = Path.Combine(temp, "ExternalKeep"); Directory.CreateDirectory(externalKeep); File.WriteAllText(Path.Combine(externalKeep, "file.txt"), "outside");
            commands.Execute(new DiskShellRequest { Action = "add", Path = externalKeep }, None);
            int beforeRecycle = recycled;
            // A stale green snapshot must not authorize deletion after scan discovers local-only changes.
            rest.OnScan = () => { rest.Local["receiveOnlyChangedBytes"] = 1; };
            Reject(() => commands.Execute(new DiskShellRequest { Action = "keep-server", Path = externalKeep }, None), "post-scan receiveonly changes stop removal");
            Check(rest.Folders.Count == 1 && recycled == beforeRecycle, "failed readiness leaves registration and data intact");
            rest.OnScan = null; rest.Local.Remove("receiveOnlyChangedBytes");
            var bounded = new DiskShellCommands(rest, root, service, catalog, "rules", recycle, 30);
            rest.OnScan = () => { rest.Remote["needItems"] = 1; };
            string failure = "";
            try { bounded.Execute(new DiskShellRequest { Action = "keep-server", Path = externalKeep }, None); } catch (IOException e) { failure = e.Message; }
            Check(failure.Contains("вовремя") && rest.Folders.Count == 1 && recycled == beforeRecycle, "readiness timeout is explicit and does not detach/recycle");
            rest.OnScan = null; rest.Remote["needItems"] = 0;
            int scans = 0; rest.OnScan = () => scans++;
            rest.OnStatus = n => { if (scans == 1) rest.Local["sequence"] = Json.Int(rest.Local, "sequence", 0) + 1; };
            commands.Execute(new DiskShellRequest { Action = "keep-server", Path = externalKeep }, None);
            Check(scans >= 2, "changing local sequence is scanned again before removal");
            rest.OnScan = null; rest.OnStatus = null;
            Check(service.IsPlaceholder(externalKeep) && commands.Read(None).Folders.Any(f => f.Name == "ExternalKeep" && f.Path == externalKeep), "external keep-server recreates cloud at the original path");
            var switched = new DiskSnapshot(); catalog.Merge("NEW-SERVER", switched); Check(switched.Folders.Count == 0, "placeholder catalog bound to paired server");
            Reject(() => DiskPaths.Available(root, root, new DiskFolderState[0]), "Disk root cannot be shared");
            Check(!rest.Calls.Any(c => c.IndexOf("ssh", StringComparison.OrdinalIgnoreCase) >= 0), "all folder actions use local REST only");
        }
        internal sealed class LocalApi : IDisposable
        {
            readonly HttpListener listener = new HttpListener(); readonly CancellationTokenSource stop = new CancellationTokenSource();
            TaskCompletionSource<bool> changed = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously); internal readonly FakeRest Rest = new FakeRest();
            internal int EventId = 1, LongPolls, Requests; internal bool Redirect;
            internal readonly string Home; readonly Task worker;
            internal LocalApi(string home)
            {
                Home = home; Directory.CreateDirectory(Path.Combine(home, "state"));
                var socket = new TcpListener(IPAddress.Loopback, 0); socket.Start(); int port = ((IPEndPoint)socket.LocalEndpoint).Port; socket.Stop();
                listener.Prefixes.Add("http://127.0.0.1:" + port + "/"); listener.Start();
                File.WriteAllText(Path.Combine(home, "state", "config.xml"), "<configuration>\r\n<gui tls=\"false\"><address>127.0.0.1:" + port + "</address><apikey>test-key</apikey></gui>\r\n</configuration>");
                File.WriteAllText(Path.Combine(home, "server.txt"), "SERVER\r\n");
                worker = Task.Run(async () => { while (!stop.IsCancellationRequested) { HttpListenerContext context; try { context = await listener.GetContextAsync(); } catch { return; } _ = Handle(context); } });
            }
            async Task Handle(HttpListenerContext context)
            {
                try {
                    Interlocked.Increment(ref Requests);
                    if (context.Request.Headers["X-API-Key"] != "test-key") { context.Response.StatusCode = 403; return; }
                    if (Redirect) { context.Response.StatusCode = 302; context.Response.RedirectLocation = "http://192.0.2.1/"; return; }
                    object result;
                    if (context.Request.Url.AbsolutePath == "/rest/events") {
                        long since; long.TryParse(context.Request.QueryString["since"], out since);
                        if (context.Request.QueryString["limit"] == null && since >= EventId) { Interlocked.Increment(ref LongPolls); await Task.WhenAny(changed.Task, Task.Delay(30000, stop.Token)); stop.Token.ThrowIfCancellationRequested(); }
                        result = new[] { new { id = EventId, type = "PendingFoldersChanged" } };
                    } else {
                        object body = null; using (var reader = new StreamReader(context.Request.InputStream)) { string text = reader.ReadToEnd(); if (text.Length > 0) body = Json.Parse(text); }
                        result = Rest.Request(context.Request.HttpMethod, context.Request.Url.PathAndQuery.Substring("/rest/".Length), body, stop.Token);
                    }
                    byte[] bytes = Encoding.UTF8.GetBytes(Json.Encode(result) + "\r\n"); context.Response.ContentType = "application/json"; context.Response.ContentLength64 = bytes.Length;
                    await context.Response.OutputStream.WriteAsync(bytes, 0, bytes.Length);
                } catch { } finally { context.Response.Close(); }
            }
            internal void Event() { Interlocked.Increment(ref EventId); var signal = changed; changed = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously); signal.TrySetResult(true); }
            public void Dispose() { stop.Cancel(); listener.Close(); worker.Wait(1000); }
        }
        static async Task HttpAndEvents(string temp)
        {
            using (var api = new LocalApi(Path.Combine(temp, "state"))) {
                var client = new DiskSyncthingClient(api.Home);
                Check(client.Peer == "SERVER" && Json.Str(Json.Map(client.Request("GET", "system/status", null, None)), "myID") == "LOCAL", "real loopback REST auth and CRLF settings");
                api.Redirect = true; Reject(() => client.Request("GET", "system/status", null, None), "redirects never followed"); api.Redirect = false;
                var model = new DiskRestModel(client); Check(DiskRestModel.EventId(model.Events(0, None, true).Single()) == 1, "event tail seeds cursor before snapshot");
                using (var cancel = new CancellationTokenSource()) {
                    var blocked = Task.Run(() => model.Events(1, cancel.Token));
                    await Until(() => api.LongPolls > 0); cancel.Cancel();
                    bool cancelled = false; try { await blocked; } catch (OperationCanceledException) { cancelled = true; } Check(cancelled, "cancel aborts blocked HTTP long-poll");
                }
                string root = Path.Combine(temp, "Disk"), bundle = Path.Combine(temp, "bundle"); Directory.CreateDirectory(Path.Combine(bundle, "disk")); File.WriteAllText(Path.Combine(bundle, "disk", "stignore.txt"), ".git\n.env*\n/desktop.ini\n");
                api.Rest.Offer("id-a", "First"); var fs = new TestFiles(); var service = Service(fs); var store = new TestRegistry();
                var notices = new ConcurrentQueue<string>();
                using (var controller = new DiskExplorerController(Path.Combine(temp, "app"), () => root, () => bundle, () => true, () => true, (m, ok) => notices.Enqueue(m), delegate { }, service, new DiskExplorerRegistry(store, delegate { }), api.Home)) {
                    await Until(() => Directory.Exists(Path.Combine(root, "First")));
                    await Until(() => api.LongPolls >= 2);
                    int calls = api.Requests; await Task.Delay(200); Check(api.Requests == calls, "quiet long-poll does not poll statuses");
                    api.Rest.Offer("id-b", "Second"); api.Event();
                    await Until(() => Directory.Exists(Path.Combine(root, "Second")));
                    Check(service.IsPlaceholder(Path.Combine(root, "Second")), "pending event creates new placeholder without timer polling");
                    var watch = Stopwatch.StartNew(); controller.Submit(new DiskShellRequest { Action = "download", Path = Path.Combine(root, "First") });
                    Check(watch.ElapsedMilliseconds < 1000 && notices.Count > 0, "click acknowledged within one second while events wait on separate connection");
                    await Until(() => notices.Count >= 2);
                    string firstIni = Path.Combine(root, "First", "desktop.ini");
                    Check(File.ReadAllText(firstIni).Contains("Synced.ico"), "command completes without waiting for long-poll");
                    controller.Dispose(); Check(await Task.Run(() => controller.Wait(3000)), "monitor exits promptly while long-poll is blocked");
                    Check(File.ReadAllText(firstIni).Contains("Unavailable.ico"), "exit does not leave a stale green status");
                    string menu = DiskExplorerRegistry.Prefix, upload = store.Read(menu + "add", "AppliesTo");
                    Check(upload.Contains(Path.Combine(root, "First")) && upload.Contains(Path.Combine(root, "Second")), "upload hidden on the placeholder and on the folder that now syncs");
                    Check(new[] { "download", "keep-server", "add" }.All(a => store.Read(menu + a, "Icon") == "\"/icons/App.ico\",0"), "controller gives all three items the application icon");
                }
                DiskExplorerController.RemoveIntegration(root, api.Home, service, new DiskExplorerRegistry(store, delegate { }));
                Check(Directory.Exists(Path.Combine(root, "First")) && !File.Exists(Path.Combine(root, "First", "desktop.ini")) && !Directory.Exists(Path.Combine(root, "Second")) && store.Values.Count == 0, "uninstall removes only owned decoration/placeholders and preserves accepted folder");
                // The icon cannot be produced: the items still work with the program file's icon, and the failure is journalled once.
                var journal = new ConcurrentQueue<string>(); var fallback = new TestRegistry();
                using (var controller = new DiskExplorerController(Path.Combine(temp, "app2"), () => root, () => bundle, () => true, () => true, (m, ok) => { }, journal.Enqueue, new DiskExplorerService(fs, new BrokenIcons(), new Notify(), delegate { }), new DiskExplorerRegistry(fallback, delegate { }), api.Home)) {
                    await Until(() => fallback.Read(DiskExplorerRegistry.Prefix + "add", "Icon") != null);
                    api.Rest.Offer("id-c", "Third"); api.Event();
                    await Until(() => Directory.Exists(Path.Combine(root, "Third")));
                    controller.Dispose(); Check(await Task.Run(() => controller.Wait(3000)), "monitor with a broken icon exits promptly");
                }
                string programIcon = "\"" + Path.Combine(Path.GetTempPath(), "RemoteAgents.exe") + "\",0";
                Check(new[] { "download", "keep-server", "add" }.All(a => fallback.Read(DiskExplorerRegistry.Prefix + a, "Icon") == programIcon), "items keep working with the program icon when the icon cannot be produced");
                Check(journal.Count(j => j == "disk.explorer.icon.failed") == 1, "icon failure is journalled once, not on every refresh");
                File.WriteAllText(Path.Combine(api.Home, "server.txt"), "OTHER\r\n");
                Reject(() => client.Request("DELETE", "config/folders/id-a", null, None), "server switch invalidates stale mutation client");
                string xml = Path.Combine(api.Home, "state", "config.xml"); File.WriteAllText(xml, "<configuration><gui><address>0.0.0.0:8384</address><apikey>test</apikey></gui></configuration>");
                Reject(() => new DiskSyncthingClient(api.Home), "non-loopback GUI refused");
                File.WriteAllText(xml, "<!DOCTYPE x [<!ENTITY x SYSTEM 'file:///not-read'>]><configuration>&x;</configuration>");
                Reject(() => new DiskSyncthingClient(api.Home), "DTD external entity refused");
            }
        }
        static async Task Until(Func<bool> predicate)
        { for (int i = 0; i < 150; i++) { if (predicate()) return; await Task.Delay(20); } throw new Exception("Disk Explorer: timed out waiting for event"); }
        static object ToPortable(this object value) { return Json.Parse(Json.Encode(value)); }
    }
}
