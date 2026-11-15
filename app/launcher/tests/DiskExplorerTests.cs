using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
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
            var commands = new DiskShellCommands(rest, args[2], service, new DiskPlaceholderCatalog(args[1]), File.ReadAllText(args[5]), path => Directory.Move(path, args[6]), args.Length > 7 ? int.Parse(args[7]) : 30000);
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
            try { RecyclePolicy(); States(); Metadata(Path.Combine(temp, "metadata")); Registry(); Menu(); Commands(Path.Combine(temp, "actions")); Console.WriteLine("PASS: Explorer model, metadata, registry and action fixtures"); HttpAndEvents(Path.Combine(temp, "http")).GetAwaiter().GetResult(); }
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
            public bool DirectoryExists(string p) { return Directory.Exists(p); }
            public bool FileExists(string p) { return File.Exists(p); }
            public FileAttributes Attributes(string p) { FileAttributes a; return attributes.TryGetValue(p, out a) ? a : File.GetAttributes(p); }
            public void Attributes(string p, FileAttributes a) { attributes[p] = a; }
            public IEnumerable<string> Entries(string p) { return Directory.GetFileSystemEntries(p); }
            public string Read(string p) { return File.ReadAllText(p); }
            public void Write(string p, string s) { Writes++; File.WriteAllText(p, s, Encoding.Unicode); }
            public void CreateDirectory(string p) { Directory.CreateDirectory(p); }
            public void DeleteFile(string p) { File.Delete(p); attributes.Remove(p); }
            public void DeleteDirectory(string p) { Directory.Delete(p); attributes.Remove(p); }
        }
        sealed class Icons : IDiskExplorerIcons { public string PathFor(DiskExplorerKind k) { return "/icons/" + k + ".ico"; } }
        sealed class Notify : IDiskExplorerNotifier { internal int Count; public void Changed(string path) { Count++; } }
        static DiskExplorerService Service(TestFiles fs) { return new DiskExplorerService(fs, new Icons(), new Notify(), delegate { }); }
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
            Check(!service.IsPlaceholder(row.Path) && fs.Read(ini).Contains("Error.ico"), "local data invalidates transparent cloud");
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
        internal sealed class TestRegistry : IDiskExplorerRegistry
        {
            internal readonly Dictionary<string, string> Values = new Dictionary<string, string>(); internal int Writes;
            public bool Exists(string k) { return Values.Keys.Any(v => v.StartsWith(k + "|", StringComparison.Ordinal)); }
            public string Read(string k, string n) { string v; return Values.TryGetValue(k + "|" + n, out v) ? v : null; }
            public void Write(string k, string n, string v) { Values[k + "|" + n] = v; Writes++; }
            public void DeleteTree(string k) { foreach (string v in Values.Keys.Where(v => v.StartsWith(k + "|", StringComparison.Ordinal) || v.StartsWith(k + "\\", StringComparison.Ordinal)).ToArray()) Values.Remove(v); }
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
        internal sealed class FakeRest : IDiskRest
        {
            public string Peer { get { return "SERVER"; } }
            internal readonly List<Dictionary<string, object>> Folders = new List<Dictionary<string, object>>();
            internal readonly Dictionary<string, object> Pending = new Dictionary<string, object>();
            internal readonly List<string> Calls = new List<string>();
            internal Action OnScan; internal Action<int> OnStatus; int statusReads;
            internal bool FailPost, Connected = true, FailDelete, AppliedThenTimeout, FailVerify;
            bool verifying;
            internal Dictionary<string, object> Local = Map("{\"state\":\"idle\",\"globalBytes\":100,\"needBytes\":0,\"needTotalItems\":0,\"sequence\":1}");
            internal Dictionary<string, object> Remote = Map("{\"completion\":100,\"needBytes\":0,\"needItems\":0,\"needDeletes\":0,\"remoteState\":\"valid\"}");
            internal void Offer(string id, string label, string peer = "SERVER") { Pending[id] = new Dictionary<string, object> { { "offeredBy", new Dictionary<string, object> { { peer, new Dictionary<string, object> { { "label", label } } } } } }; }
            public object Request(string method, string route, object body, CancellationToken token, int timeout = 3000)
            {
                token.ThrowIfCancellationRequested(); lock (Calls) Calls.Add(method + " " + route);
                if (route == "system/connections") return new Dictionary<string, object> { { "connections", new Dictionary<string, object> { { Peer, new { connected = Connected } } } } }.ToPortable();
                if (route == "config/folders" && method == "GET") { if (FailVerify && verifying) { verifying = false; throw new IOException("verification lost"); } verifying = false; return Folders.ToArray(); }
                if (route.StartsWith("cluster/pending/folders")) return Pending;
                if (route.StartsWith("db/scan") && method == "POST") { if (OnScan != null) OnScan(); return null; }
                 if (route.StartsWith("db/status")) { if (OnStatus != null) OnStatus(++statusReads); return new Dictionary<string, object>(Local); }
                if (route.StartsWith("db/completion")) return Remote;
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
                }
                DiskExplorerController.RemoveIntegration(root, api.Home, service, new DiskExplorerRegistry(store, delegate { }));
                Check(Directory.Exists(Path.Combine(root, "First")) && !File.Exists(Path.Combine(root, "First", "desktop.ini")) && !Directory.Exists(Path.Combine(root, "Second")) && store.Values.Count == 0, "uninstall removes only owned decoration/placeholders and preserves accepted folder");
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
