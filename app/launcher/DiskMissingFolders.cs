using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;

namespace RemoteAgents.Launcher
{
    // Syncthing keeps a missing path registered indefinitely. Detach only after our own
    // conservative observation; never send file deletions or accept a server offer here.
    internal sealed class DiskMissingFolders
    {
        static readonly object Gate = new object();
        // A new launcher process starts a fresh observation: persisted monotonic samples
        // must never be interpreted across a reboot, process restart or clock epoch change.
        static readonly string Epoch = Guid.NewGuid().ToString("N");
        readonly string file; string epoch; readonly Func<double> seconds;
        readonly IDiskExplorerFileSystem fs; readonly Action<string> log;
        internal DiskMissingFolders(string home, Action<string> log, IDiskExplorerFileSystem fs = null, Func<double> seconds = null, string epoch = null)
        {
            file = Path.Combine(home, "missing-folders.json"); this.log = log;
            this.fs = fs ?? new DiskExplorerFileSystem();
            this.seconds = seconds ?? (() => (double)Stopwatch.GetTimestamp() / Stopwatch.Frequency);
            this.epoch = epoch ?? Epoch;
        }
        internal void Reset() { epoch = Guid.NewGuid().ToString("N"); }
        bool Missing(string path, string root)
        {
            // Exists() hides access errors. Stat the path itself (including dangling links),
            // and accept ENOENT only after enumerating its existing, accessible parent.
            try {
                for (string p = Path.GetDirectoryName(path); !string.IsNullOrEmpty(p); p = Path.GetDirectoryName(p)) {
                    var attributes = fs.Attributes(p);
                    if ((attributes & FileAttributes.Directory) == 0 || (attributes & FileAttributes.ReparsePoint) != 0) return false;
                }
                string parent = Path.GetDirectoryName(path);
                if (parent == null || fs.Entries(parent).Any(p => DiskPaths.Same(p, path))) return false;
                if (DiskPaths.Within(path, root)) {
                    if (DiskPaths.Same(path, root) || (fs.Attributes(root) & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != FileAttributes.Directory || !fs.Entries(root).Any()) return false;
                }
                try { fs.Attributes(path); return false; }
                catch (FileNotFoundException) { return true; }
                catch (DirectoryNotFoundException) { return true; }
            } catch (Exception e) when (e is IOException || e is UnauthorizedAccessException || e is ArgumentException) { return false; }
        }
        internal bool Reconcile(IDiskRest rest, string root, CancellationToken token)
        {
            lock (Gate) {
                var before = new Dictionary<string, object>();
                try { if (File.Exists(file)) before = Json.Read(file); }
                catch (Exception) { } // Unreadable/corrupt observations can only start a fresh wait.
                var old = Json.Str(before, "epoch") == epoch && Json.Str(before, "peer") == rest.Peer ? Json.Map(Json.Get(before, "folders")) : new Dictionary<string, object>();
                var next = new Dictionary<string, object>(); bool changed = false; double now = seconds();
                foreach (var value in Json.Array(rest.Request("GET", "config/folders", null, token))) {
                    var row = Json.Map(value); string id = Json.Str(row, "id"), path;
                    if (id.Length == 0 || !Shared(row, rest.Peer) || !DiskPaths.TryFull(Json.Str(row, "path"), out path) || !Missing(path, root)) continue;
                    var previous = Json.Map(Json.Get(old, id)); double since = DiskSnapshot.Number(previous, "since");
                    if (Json.Str(previous, "path") != path || !previous.ContainsKey("since") || since > now || since < 0) since = now;
                    next[id] = new { path, since };
                    if (now - since < 30) continue;
                    try {
                        // Re-read configuration and the filesystem immediately before DELETE.
                        var current = Json.Array(rest.Request("GET", "config/folders", null, token)).Select(Json.Map).SingleOrDefault(f => Json.Str(f, "id") == id);
                        if (current == null || !Shared(current, rest.Peer) || !DiskPaths.Same(Json.Str(current, "path"), path) || !Missing(path, root)) { next.Remove(id); continue; }
                        try { rest.Request("DELETE", "config/folders/" + Uri.EscapeDataString(id), null, token); }
                        catch (IOException) {
                            // A lost reply may follow an applied DELETE; confirm before retrying/logging.
                            if (Json.Array(rest.Request("GET", "config/folders", null, token)).Any(f => Json.Str(Json.Map(f), "id") == id)) throw;
                        }
                        next.Remove(id); changed = true;
                        log("disk.folder.missing.detached: " + Json.Text(row, "label", id).Replace("\r", " ").Replace("\n", " ").Replace("\0", ""));
                    } catch (IOException) { } // Retry this folder; other folders keep their independent observations.
                }
                var state = new Dictionary<string, object> { { "epoch", epoch }, { "peer", rest.Peer }, { "folders", next } };
                if (Json.Encode(before) != Json.Encode(state)) Json.Write(file, state);
                return changed;
            }
        }
        static bool Shared(Dictionary<string, object> row, string peer)
        { return Json.Array(Json.Get(row, "devices")).Any(d => Json.Str(Json.Map(d), "deviceID") == peer); }
    }
}
