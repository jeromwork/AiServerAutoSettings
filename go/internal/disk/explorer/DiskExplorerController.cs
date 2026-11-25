using System;
using System.IO;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace RemoteAgents.Launcher
{
    // One in-process long-poll, with a separate connection for shell commands. No subprocess or SSH status monitor.
    internal sealed class DiskExplorerController : IDisposable
    {
        readonly string home, diskHome; readonly Func<string> root, bundle; readonly Func<bool> enabled, cleanup;
        readonly Action<string, bool> notify; readonly Action<string> log;
        readonly CancellationTokenSource stop = new CancellationTokenSource();
        readonly SemaphoreSlim gate = new SemaphoreSlim(1, 1);
        readonly DiskMissingFolders missing;
        readonly DiskExplorerService metadata; readonly DiskExplorerRegistry registry;
        readonly Task worker; readonly TaskCompletionSource<bool> initialized = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        readonly FileSystemWatcher watcher;
        readonly HashSet<string> missingDeadlines = new HashSet<string>();
        readonly AutoResetEvent changed = new AutoResetEvent(false);
        internal void Wake() { changed.Set(); }
        bool WaitChange() { return WaitHandle.WaitAny(new[] { stop.Token.WaitHandle, changed }) == 0; }
        int pendingCommands;
        internal bool Busy { get { return Volatile.Read(ref pendingCommands) != 0; } }
        DiskSnapshot last = new DiskSnapshot(); string lastRoot; bool iconFailed;
        internal DiskExplorerController(string home, Func<string> root, Func<string> bundle, Func<bool> enabled, Func<bool> cleanup, Action<string, bool> notify, Action<string> log,
            DiskExplorerService metadata, DiskExplorerRegistry registry, string diskHome = null)
        {
            this.home = home; this.root = root; this.bundle = bundle; this.enabled = enabled; this.cleanup = cleanup; this.notify = notify; this.log = log;
            this.diskHome = diskHome ?? DefaultDiskHome; this.metadata = metadata; this.registry = registry;
            missing = new DiskMissingFolders(this.diskHome, log);
            worker = Task.Run((Action)Monitor);
            string folderRoot = root();
            Directory.CreateDirectory(folderRoot);
            watcher = new FileSystemWatcher(folderRoot) { NotifyFilter = NotifyFilters.DirectoryName, IncludeSubdirectories = false };
            FileSystemEventHandler update = (s, e) => Task.Run(() => {
                try { var rest = new DiskSyncthingClient(this.diskHome); Refresh(rest, root()); }
                catch (OperationCanceledException) { } catch (Exception) { log("disk.explorer.local-refresh.failed"); }
            });
            watcher.Created += update; watcher.Deleted += update; watcher.Renamed += (s, e) => update(s, e);
            watcher.Error += (s, e) => update(s, null);
            watcher.EnableRaisingEvents = true;
        }
        internal static string DefaultDiskHome { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RemoteDisk"); } }
        internal void Submit(DiskShellRequest request)
        {
            Interlocked.Increment(ref pendingCommands);
            notify("Диск: действие принято", true);
            Task.Run(async () => {
                try {
                    if (!await initialized.Task.ConfigureAwait(false)) throw new IOException("Оформление Диска ещё не готово");
                    await gate.WaitAsync(stop.Token).ConfigureAwait(false);
                    try {
                        if (!enabled()) throw new IOException("Диск отключён в конфиге");
                        var rest = new DiskSyncthingClient(diskHome); string currentRoot = root();
                        var command = Commands(rest, currentRoot);
                        string result = command.Execute(request, stop.Token);
                        try { Publish(currentRoot, command.Read(stop.Token)); } catch (IOException) { log("disk.explorer.refresh.failed"); }
                        log("disk.shell." + request.Action + ".ok"); notify(result, true);
                    } finally { gate.Release(); }
                } catch (OperationCanceledException) { }
                catch (IOException e) { log("disk.shell." + request.Action + ".failed"); notify(e.Message, false); }
                catch (Exception) { log("disk.shell." + request.Action + ".failed"); notify("Действие Диска не выполнено. Проверьте журнал программы", false); }
                finally { Interlocked.Decrement(ref pendingCommands); }
            });
        }
        DiskShellCommands Commands(IDiskRest rest, string currentRoot)
        {
            string rules = File.ReadAllText(Path.Combine(bundle(), "disk", "stignore.txt"));
            return new DiskShellCommands(rest, currentRoot, metadata, new DiskPlaceholderCatalog(diskHome), rules, Recycle, diskHome: diskHome);
        }
        static void Recycle(string path) { DiskRecycle.Move(path); }
        void Monitor()
        {
            try {
                while (!stop.IsCancellationRequested && !cleanup()) if (WaitChange()) return;
                initialized.TrySetResult(!stop.IsCancellationRequested);
                while (!stop.IsCancellationRequested) {
                    try {
                        if (!enabled()) {
                            gate.Wait(stop.Token);
                            try { missing.Reset(); Clear(); } finally { gate.Release(); }
                            if (WaitChange()) break;
                            continue;
                        }
                        string currentRoot = root(); var rest = new DiskSyncthingClient(diskHome); var model = new DiskRestModel(rest);
                        long since = model.Events(0, stop.Token, true).Select(DiskRestModel.EventId).DefaultIfEmpty(0).Max();
                        DateTime xmlTime = File.GetLastWriteTimeUtc(Path.Combine(diskHome, "state", "config.xml"));
                        Refresh(rest, currentRoot);
                        while (!stop.IsCancellationRequested && enabled() && DiskPaths.Same(root(), currentRoot)) {
                            var events = model.Events(since, stop.Token, pollSeconds: 60);
                            if (File.ReadAllText(Path.Combine(diskHome, "server.txt")).TrimStart('\uFEFF').Replace("\r", "").Trim() != rest.Peer) break;
                            bool detached = false;
                            if (events.Length != 0) {
                            gate.Wait(stop.Token);
                            try {
                                detached = missing.Reconcile(rest, currentRoot, stop.Token);
                                ScheduleMissing();
                                // Explorer moves/deletes produce no Syncthing event for an unaccepted
                                // placeholder. Reconcile local decoration from the last offer snapshot.
                                if (!detached && lastRoot != null && DiskPaths.Same(lastRoot, currentRoot) && Directory.Exists(currentRoot)) Publish(currentRoot, last);
                            } finally { gate.Release(); }
                            if (detached) Refresh(rest, currentRoot);
                            }
                            if (events.Length == 0) {
                                // Event IDs restart with Syncthing. Check only its event cursor, never periodic folder status.
                                long tail = model.Events(0, stop.Token, true).Select(DiskRestModel.EventId).DefaultIfEmpty(0).Max();
                                if (tail < since || File.GetLastWriteTimeUtc(Path.Combine(diskHome, "state", "config.xml")) != xmlTime) break;
                                continue;
                            }
                            bool gap = since > 0 && events.Min(DiskRestModel.EventId) > since + 1;
                            since = Math.Max(since, events.Max(DiskRestModel.EventId));
                            if (gap || events.Any(DiskRestModel.ChangesFolders)) {
                                // Coalesce bursts before reading the expensive db/status endpoint.
                                stop.Token.ThrowIfCancellationRequested();
                                Refresh(rest, currentRoot);
                            }
                        }
                    } catch (OperationCanceledException) { break; }
                    catch (Exception) {
                        missing.Reset();
                        log("disk.explorer.unavailable");
                        gate.Wait(stop.Token);
                        try { Unavailable(); } finally { gate.Release(); }
                        if (WaitChange()) break;
                    }
                }
            } catch (OperationCanceledException) { }
            finally {
                log("disk.explorer.stopping");
                initialized.TrySetResult(false);
                gate.Wait(); try { Unavailable(); } catch (Exception) { } finally { gate.Release(); }
                log("disk.explorer.stopped");
            }
        }
        void Refresh(IDiskRest rest, string currentRoot)
        {
            gate.Wait(stop.Token);
            try { missing.Reconcile(rest, currentRoot, stop.Token); ScheduleMissing(); Publish(currentRoot, Commands(rest, currentRoot).Read(stop.Token)); }
            finally { gate.Release(); }
        }
        // One deadline per disappearance, starting after its first observation.
        // Filesystem events cancel/rearm the observation; no periodic status poll.
        void ScheduleMissing()
        {
            string file = Path.Combine(diskHome, "missing-folders.json");
            var pending = File.Exists(file) ? Json.Map(Json.Get(Json.Read(file), "folders")) : new Dictionary<string, object>();
            missingDeadlines.RemoveWhere(id => !pending.ContainsKey(id));
            foreach (string id in pending.Keys) if (missingDeadlines.Add(id))
                Task.Delay(DiskTiming.Milliseconds("MISSING_AFTER", 30000), stop.Token).ContinueWith(t => {
                    if (t.IsCanceled) return;
                    try { Refresh(new DiskSyncthingClient(diskHome), root()); }
                    catch (OperationCanceledException) { } catch (Exception) { log("disk.explorer.missing-refresh.failed"); }
                }, TaskScheduler.Default);
        }
        void Publish(string currentRoot, DiskSnapshot snapshot)
        {
            if (lastRoot != null && !DiskPaths.Same(currentRoot, lastRoot)) Clear();
            string manifest = Path.Combine(diskHome, "explorer-folders.json");
            string[] paths = snapshot.Folders.Where(f => f.Kind != DiskExplorerKind.Local).Select(f => f.Path).ToArray();
            if (File.Exists(manifest)) foreach (string old in Json.Strings(Json.Parse(File.ReadAllText(manifest))))
                if (!paths.Any(p => DiskPaths.Same(p, old))) metadata.CleanupFolder(old, true);
            metadata.Reconcile(currentRoot, snapshot.Folders);
            // Empty placeholders offer download; existing local copies offer an explicit merge.
            registry.Register(ProgramPath, currentRoot, snapshot.Folders.Where(f => !f.ServerOnly || f.Kind == DiskExplorerKind.LocalCopy || metadata.IsPlaceholder(f.Path)), home, MenuIcon());
            string content = Json.Encode(paths);
            if (!File.Exists(manifest) || File.ReadAllText(manifest) != content) Files.Atomic(manifest, content);
            last = snapshot; lastRoot = currentRoot;
        }
        // The program's icon for our menu items. If it cannot be produced the items still work, with the program file's own icon.
        string MenuIcon()
        {
            try { string path = metadata.ApplicationIcon(); iconFailed = false; return path; }
            catch (Exception) { if (!iconFailed) log("disk.explorer.icon.failed"); iconFailed = true; return null; }
        }
        string ProgramPath
        {
            get {
#if PORTABLE_TEST
                return Path.Combine(Path.GetTempPath(), "RemoteAgents.exe");
#else
                string installed = Path.Combine(home, Product.ExeName);
                return File.Exists(installed) ? installed : Program.Exe;
#endif
            }
        }
        void Unavailable()
        {
            if (lastRoot == null) {
                lastRoot = root(); string manifest = Path.Combine(diskHome, "explorer-folders.json");
                if (File.Exists(manifest)) foreach (string path in Json.Strings(Json.Parse(File.ReadAllText(manifest)))) {
                    bool placeholder = metadata.IsPlaceholder(path);
                    last.Folders.Add(new DiskFolderState { Path = path, ServerOnly = placeholder, Kind = placeholder ? DiskExplorerKind.ServerOnly : DiskExplorerKind.Unavailable });
                }
                registry.Register(ProgramPath, lastRoot, last.Folders, home, MenuIcon());
            }
            var rows = last.Folders.Select(f => { var copy = f.Copy(); if (!copy.ServerOnly && copy.Kind != DiskExplorerKind.Local && copy.Kind != DiskExplorerKind.ServerRemoved) copy.Kind = DiskExplorerKind.Unavailable; return copy; }).ToArray();
            metadata.Reconcile(lastRoot, rows);
        }
        void Clear()
        {
            registry.Cleanup();
            foreach (var row in last.Folders) metadata.CleanupFolder(row.Path, true);
            last = new DiskSnapshot(); lastRoot = null;
        }
        public void Dispose() { watcher.Dispose(); stop.Cancel(); changed.Set(); }
        internal bool Wait(int milliseconds) { return worker.Wait(milliseconds); }
        internal static void RemoveIntegration(string root, string diskHome, DiskExplorerService metadata, DiskExplorerRegistry registry)
        {
            registry.Cleanup(); metadata.Cleanup(root, true);
            string manifest = Path.Combine(diskHome, "explorer-folders.json");
            if (File.Exists(manifest)) {
                foreach (string path in Json.Strings(Json.Parse(File.ReadAllText(manifest)))) metadata.CleanupFolder(path, true);
                File.Delete(manifest);
            }
        }
    }
}
