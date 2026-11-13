using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Threading;

namespace RemoteAgents.Launcher
{
    internal static class DiskShellTests
    {
        static int count;
        static void Check(bool value, string label) { if (!value) throw new Exception("DiskShell: " + label); count++; }
        internal static void Run()
        {
            count = 0; DiskShellRequest request;
            Check(!DiskShellRequest.TryParse(new[] { "--settings" }, out request), "other command untouched");
            Check(DiskShellRequest.TryParse(new[] { "--home", "C:\\App", "--disk-shell", "download", "C:\\Disk\\A" }, out request) && request.Path == "C:\\Disk\\A", "home routing and path");
            Check(DiskShellRequest.TryParse(new[] { "--disk-shell", "keep-server", "C:\\Disk\\A", "--home", "C:\\App" }, out request), "home after shell args");
            try { DiskShellRequest.TryParse(new[] { "--disk-shell", "delete", "C:\\A" }, out request); throw new Exception("accepted unknown"); } catch (IOException) { count++; }
            try { DiskShellRequest.TryParse(new[] { "--disk-shell", "sync", "C:\\A\r\n" }, out request); throw new Exception("accepted newline"); } catch (IOException) { count++; }
            var queue = new DiskShellBatchQueue(); DateTime now = DateTime.UtcNow;
            queue.Add(new DiskShellRequest { Action = "download", Path = "C:\\Disk\\A" }, now);
            queue.Add(new DiskShellRequest { Action = "download", Path = "c:/disk/a/" }, now.AddMilliseconds(100));
            queue.Add(new DiskShellRequest { Action = "sync", Path = "C:\\Disk\\B" }, now.AddMilliseconds(200));
            Check(queue.Take(now.AddMilliseconds(600)).Count == 0, "waits for selection tail");
            Check(queue.Take(now.AddMilliseconds(760)).Count == 2, "one distinct batch");
            Check(queue.Take(now.AddSeconds(2)).Count == 0, "batch consumed once");
            for (int i = 0; i < 25; i++) queue.Add(new DiskShellRequest { Action = "sync", Path = "C:\\Disk\\" + i }, now.AddMilliseconds(i * 80));
            Check(queue.Take(now.AddSeconds(2)).Count == 25, "bounded collection window");
            var ini = "[tray]\r\nconnections\\1\\apiKey=synthetic\r\n[startup]\r\nsyncthingAutostart=true\r\ntools\\1\\autostart=true\r\n";
            string safe = DiskDetailsSettings.WithoutAutostart(ini);
            Check(safe.Contains("syncthingAutostart=false\r\n") && safe.Contains("tools\\1\\autostart=false\r\n") && safe.Contains("apiKey=synthetic"), "details keeps connection, disables engine/tools");
            Check(DiskDetailsSettings.WithoutAutostart(safe) == safe, "safe ini idempotent");
            Check(DiskDetailsSettings.WithoutAutostart("[tray]\n").Contains("[startup]\r\nsyncthingAutostart=false"), "absent startup section");
            var meter = new DiskTransferRate();
            Check(meter.Observe(new DiskSyncSnapshot { Failure = "", ObservedUtc = now, InBytesTotal = 100, OutBytesTotal = 500 }).Contains("ещё"), "first speed unknown");
            Check(meter.Observe(new DiskSyncSnapshot { Failure = "", ObservedUtc = now.AddSeconds(2), InBytesTotal = 2097252, OutBytesTotal = 1049076 }).Contains("Приём: 1 МБ/с"), "rates use actual sample duration");
            Check(meter.Observe(new DiskSyncSnapshot { Failure = "", ObservedUtc = now.AddSeconds(3), InBytesTotal = 0, OutBytesTotal = 0 }).Contains("перезапущены"), "counter reset no negative speed");
            var folder = new DiskSyncFolder { Id = "folder", Shared = true, Status = ConfigBundle.D("state", "idle", "needFiles", 0, "needBytes", 0) };
            var snapshot = new DiskSyncSnapshot { Failure = "", Connected = true };
            var complete = ConfigBundle.D("completion", 100, "needBytes", 0, "needItems", 0, "needDeletes", 0, "remoteState", "valid");
            Check(DiskEvictionProof.Refusal(snapshot, folder, complete) == "", "affirmative server proof");
            foreach (var c in new[] { ConfigBundle.D("completion", 99), ConfigBundle.D("completion", 100), ConfigBundle.D("completion", 100, "needBytes", 0, "needItems", 1, "needDeletes", 0, "remoteState", "valid"), ConfigBundle.D("completion", 100, "needBytes", 0, "needItems", 0, "needDeletes", 0, "remoteState", "unknown") })
                Check(DiskEvictionProof.Refusal(snapshot, folder, c).Length > 0, "partial or unknown server proof refuses eviction");
            folder.Status["receiveOnlyChangedFiles"] = 1;
            Check(DiskEvictionProof.Refusal(snapshot, folder, complete).Contains("локальные"), "receive-only local changes block eviction");
            folder.Status.Remove("receiveOnlyChangedFiles"); snapshot.Connected = false;
            Check(DiskEvictionProof.Refusal(snapshot, folder, complete).Length > 0, "offline blocks eviction");
            var entry = ConfigBundle.D("name", "a.txt", "type", "FILE_INFO_TYPE_FILE", "version", new[] { "DEV:1" }, "size", 3);
            var file = ConfigBundle.D("local", entry, "global", new Dictionary<string, object>(entry), "availability", new[] { ConfigBundle.D("id", "SERVER", "fromTemporary", false) });
            Check(DiskEvictionProof.FileConfirmed(file, "SERVER", false, 3), "per-file server availability");
            Check(!DiskEvictionProof.FileConfirmed(file, "OTHER", false, 3), "wrong peer rejected");
            Check(!DiskEvictionProof.FileConfirmed(file, "SERVER", false, 4), "unscanned length rejected");
            Json.Map(file["global"])["version"] = new[] { "DEV:2" };
            Check(!DiskEvictionProof.FileConfirmed(file, "SERVER", false, 3), "local version differs from global");
            Check(!DiskEvictionProof.FileConfirmed(new Dictionary<string, object>(), "SERVER", false, 3), "ignored/unindexed files cannot be discarded");
            byte[] content = new byte[300000]; for (int i = 0; i < content.Length; i++) content[i] = (byte)(i * 13);
            foreach (int blockSize in new[] { 128 * 1024, 256 * 1024, 16 * 1024 * 1024 }) {
                string blocksHash = BlockHash(content, blockSize); var indexed = ConfigBundle.D("size", content.Length, "numBlocks", (content.Length + blockSize - 1) / blockSize, "blocksHash", blocksHash);
                using (var stream = new MemoryStream(content)) Check(DiskEvictionProof.ContentConfirmed(stream, indexed, CancellationToken.None), "matches upstream block hash " + blockSize);
                content[0] ^= 1;
                using (var stream = new MemoryStream(content)) Check(!DiskEvictionProof.ContentConfirmed(stream, indexed, CancellationToken.None), "same-size same-mtime edit cannot pass " + blockSize);
                content[0] ^= 1;
            }
            using (var stream = new MemoryStream(new byte[0])) Check(DiskEvictionProof.ContentConfirmed(stream, ConfigBundle.D("size", 0, "numBlocks", 1, "blocksHash", BlockHash(new byte[0], 131072)), CancellationToken.None), "zero-byte file");
            using (var stream = new MemoryStream(content)) Check(!DiskEvictionProof.ContentConfirmed(stream, ConfigBundle.D("size", content.Length, "numBlocks", 3), CancellationToken.None), "missing content proof refuses eviction");
            string work = Path.Combine(Path.GetTempPath(), "disk-eviction-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(work);
            try {
                string project = Path.Combine(work, "A"), recyclePath = Path.Combine(work, "recycle"); Directory.CreateDirectory(project);
                string userFile = Path.Combine(project, "data.txt"); File.WriteAllText(userFile, "123");
                var rest = new FakeRest(userFile); var recycle = new FakeRecycle(recyclePath);
                rest.Percent = 99;
                var candidate = DiskEvictionCandidate.Prepare(rest, "A", project, CancellationToken.None);
                Check(candidate.Reason.Length > 0, "partial server blocks candidate");
                try { candidate.Recycle(recycle); throw new Exception("partial server recycled"); } catch (IOException) { count++; }
                Check(recycle.Calls == 0 && File.ReadAllText(userFile) == "123", "incomplete server leaves actual local files untouched");
                rest.Percent = 100; rest.Proof = false;
                candidate = DiskEvictionCandidate.Prepare(rest, "A", project, CancellationToken.None);
                Check(candidate.Reason.Length > 0, "missing REST content hash blocks candidate");
                rest.Proof = true;
                candidate = DiskEvictionCandidate.Prepare(rest, "A", project, CancellationToken.None);
                Check(candidate.Reason.Length == 0, "complete verified files authorize candidate: " + candidate.Reason);
                DateTime modified = File.GetLastWriteTimeUtc(userFile); File.WriteAllText(userFile, "321"); File.SetLastWriteTimeUtc(userFile, modified);
                try { candidate.Recycle(recycle); throw new Exception("changed file recycled"); } catch (IOException) { count++; }
                Check(recycle.Calls == 0 && File.ReadAllText(userFile) == "321", "post-proof same-size same-mtime edit kept");
                // A newly constructed proof also rejects same-size edits that the scan did not index.
                candidate = DiskEvictionCandidate.Prepare(rest, "A", project, CancellationToken.None);
                Check(candidate.Reason.Length > 0, "unindexed same-size edit rejected before deselection");
                File.WriteAllText(userFile, "123"); rest = new FakeRest(userFile);
                candidate = DiskEvictionCandidate.Prepare(rest, "A", project, CancellationToken.None);
                rest.Detached = false;
                try { candidate.Recycle(recycle); throw new Exception("attached folder recycled"); } catch (IOException) { count++; }
                Check(recycle.Calls == 0 && File.Exists(userFile), "still-attached engine cannot propagate local deletions");
                rest.Detached = true; candidate.Recycle(recycle);
                Check(recycle.Calls == 1 && !File.Exists(userFile) && File.ReadAllText(Path.Combine(recyclePath, "data.txt")) == "123", "verified candidate only invokes injected Recycle Bin adapter");
            } finally { Directory.Delete(work, true); }
            string restHome = Path.Combine(Path.GetTempPath(), "disk-rest-error-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(Path.Combine(restHome, "state"));
            try {
                File.WriteAllText(Path.Combine(restHome, "server.txt"), "SERVER\r\n");
                File.WriteAllText(Path.Combine(restHome, "state", "config.xml"), "<configuration><gui><address>127.0.0.1:8384</address><apikey>fixture</apikey></gui></configuration>");
                foreach (bool cancel in new[] { false, true }) using (var cancellation = new CancellationTokenSource()) {
                    var response = new ErrorResponse();
                    var rest = new DiskLocalRest(restHome, cancellation.Token, req => {
                        if (cancel) cancellation.Cancel();
                        throw new System.Net.WebException("fixture", null, System.Net.WebExceptionStatus.ProtocolError, response);
                    });
                    try { rest.File("folder", "data.txt"); throw new Exception("REST failure ignored"); }
                    catch (IOException) { Check(!cancel, "HTTP error becomes safe refusal"); }
                    catch (OperationCanceledException) { Check(cancel, "request cancellation remains cancellation"); }
                    Check(response.Closed, "HTTP error response closed even during cancellation: " + cancel);
                }
            } finally { Directory.Delete(restHome, true); }
            var observed = new DiskSyncSnapshot { Failure = "", Connected = true };
            observed.Folders["A"] = new DiskSyncFolder { Id = "configured", Path = "C:\\Disk\\A", Shared = true };
            var remembered = new Dictionary<string, string> { { "A", "C:\\Disk\\A" } };
            Check(DiskExplorerObservation.EffectiveSelection(false, "A", "C:\\Disk\\A", observed, remembered), "failed deselect keeps actual configured share");
            observed.Folders["A"].Shared = false;
            Check(!DiskExplorerObservation.EffectiveSelection(false, "A", "C:\\Disk\\A", observed, remembered), "another peer does not make a Disk share");
            observed.Folders["A"].Shared = true; observed.Folders["A"].Path = "D:\\Other\\A";
            Check(!DiskExplorerObservation.EffectiveSelection(false, "A", "C:\\Disk\\A", observed, remembered), "same name at another path does not select folder");
            observed.Folders.Clear();
            Check(!DiskExplorerObservation.EffectiveSelection(false, "A", "C:\\Disk\\A", observed, remembered), "successful REST detachment clears actual selection");
            Check(DiskExplorerObservation.EffectiveSelection(false, "A", "c:/disk/a", DiskSyncSnapshot.Unavailable("offline\r\n"), remembered), "REST outage retains last verified path");
            Check(!DiskExplorerObservation.EffectiveSelection(false, "A", "D:\\Other\\A", DiskSyncSnapshot.Unavailable("offline"), remembered), "REST outage never transfers proof to another path");
            Check(DiskExplorerObservation.EffectiveSelection(true, "New", "C:\\Disk\\New", observed, remembered), "desired selection stays pending before attachment");
            Console.WriteLine("DiskShell: " + count + " checks");
        }
        sealed class ErrorResponse : System.Net.WebResponse
        {
            internal bool Closed;
            public override void Close() { Closed = true; }
        }
        sealed class FakeRecycle : IDiskRecycle
        {
            readonly string root; internal int Calls;
            internal FakeRecycle(string root) { this.root = root; System.IO.Directory.CreateDirectory(root); }
            public void File(string path) { Calls++; System.IO.File.Move(path, Path.Combine(root, Path.GetFileName(path))); }
            public void Directory(string path) { Calls++; System.IO.Directory.Move(path, Path.Combine(root, Path.GetFileName(path))); }
        }
        sealed class FakeRest : IDiskEvictionRest
        {
            readonly Dictionary<string, object> entry; internal decimal Percent = 100; internal bool Proof = true, Detached = true;
            internal FakeRest(string path)
            {
                byte[] bytes = System.IO.File.ReadAllBytes(path);
                entry = ConfigBundle.D("name", "data.txt", "type", "FILE_INFO_TYPE_FILE", "size", bytes.Length, "numBlocks", 1, "blocksHash", BlockHash(bytes, 131072), "version", new[] { "DEV:1" }, "modified", System.IO.File.GetLastWriteTimeUtc(path).ToString("o"));
            }
            public string PeerId { get { return "SERVER"; } }
            public bool IsDetached(string path) { return Detached; }
            public DiskSyncSnapshot Read(Dictionary<string, string> paths, CancellationToken token)
            {
                var snapshot = new DiskSyncSnapshot { Failure = "", Connected = true };
                snapshot.Folders["A"] = new DiskSyncFolder { Id = "folder", Shared = true, Status = ConfigBundle.D("state", "idle", "needFiles", 0, "needBytes", 0) };
                return snapshot;
            }
            public void Scan(string folder) { }
            public Dictionary<string, object> Completion(string folder) { return ConfigBundle.D("completion", Percent, "needBytes", 0, "needItems", 0, "needDeletes", 0, "remoteState", "valid"); }
            public Dictionary<string, object> File(string folder, string relative)
            {
                var local = new Dictionary<string, object>(entry); if (!Proof) local.Remove("blocksHash");
                return ConfigBundle.D("local", local, "global", new Dictionary<string, object>(local), "availability", new[] { ConfigBundle.D("id", "SERVER", "fromTemporary", false) });
            }
        }
        static string BlockHash(byte[] bytes, int size)
        {
            var digests = new List<byte>();
            using (var sha = SHA256.Create()) {
                for (int offset = 0; offset < Math.Max(1, bytes.Length); offset += size) digests.AddRange(sha.ComputeHash(bytes, offset, Math.Min(size, bytes.Length - offset)));
                return Convert.ToBase64String(sha.ComputeHash(digests.ToArray()));
            }
        }
    }
}
