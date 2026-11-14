using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
#if !PORTABLE_TEST
using Microsoft.VisualBasic.FileIO;
#endif

namespace RemoteAgents.Launcher
{
    // One in-process long-poll, with a separate connection for shell commands. No subprocess or SSH status monitor.
    internal sealed class DiskExplorerController : IDisposable
    {
        readonly string home, diskHome; readonly Func<string> root, bundle; readonly Func<bool> enabled, cleanup;
        readonly Action<string, bool> notify; readonly Action<string> log;
        readonly CancellationTokenSource stop = new CancellationTokenSource();
        readonly SemaphoreSlim gate = new SemaphoreSlim(1, 1);
        readonly DiskExplorerService metadata; readonly DiskExplorerRegistry registry;
        readonly Task worker; readonly TaskCompletionSource<bool> initialized = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        DiskSnapshot last = new DiskSnapshot(); string lastRoot;
        internal DiskExplorerController(string home, Func<string> root, Func<string> bundle, Func<bool> enabled, Func<bool> cleanup, Action<string, bool> notify, Action<string> log,
            DiskExplorerService metadata, DiskExplorerRegistry registry, string diskHome = null)
        {
            this.home = home; this.root = root; this.bundle = bundle; this.enabled = enabled; this.cleanup = cleanup; this.notify = notify; this.log = log;
            this.diskHome = diskHome ?? DefaultDiskHome; this.metadata = metadata; this.registry = registry;
            worker = Task.Run((Action)Monitor);
        }
        internal static string DefaultDiskHome { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RemoteDisk"); } }
        internal void Submit(DiskShellRequest request)
        {
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
            });
        }
        DiskShellCommands Commands(IDiskRest rest, string currentRoot)
        {
            string rules = File.ReadAllText(Path.Combine(bundle(), "disk", "stignore.txt"));
            return new DiskShellCommands(rest, currentRoot, metadata, new DiskPlaceholderCatalog(diskHome), rules, Recycle);
        }
        static void Recycle(string path)
        {
#if !PORTABLE_TEST
            // A network share has no local Recycle Bin. Refuse instead of falling back to permanent deletion.
            var drive = new DriveInfo(Path.GetPathRoot(path));
            if (drive.DriveType != DriveType.Fixed) throw new IOException("Для этой папки недоступна локальная Корзина");
            FileSystem.DeleteDirectory(path, UIOption.OnlyErrorDialogs, RecycleOption.SendToRecycleBin, UICancelOption.ThrowException);
#else
            throw new IOException("Корзина проверяется только на Windows");
#endif
        }
        void Monitor()
        {
            try {
                while (!stop.IsCancellationRequested && !cleanup()) if (stop.Token.WaitHandle.WaitOne(5000)) return;
                initialized.TrySetResult(!stop.IsCancellationRequested);
                while (!stop.IsCancellationRequested) {
                    try {
                        if (!enabled()) {
                            gate.Wait(stop.Token);
                            try { Clear(); } finally { gate.Release(); }
                            if (stop.Token.WaitHandle.WaitOne(5000)) break;
                            continue;
                        }
                        string currentRoot = root(); var rest = new DiskSyncthingClient(diskHome); var model = new DiskRestModel(rest);
                        long since = model.Events(0, stop.Token, true).Select(DiskRestModel.EventId).DefaultIfEmpty(0).Max();
                        DateTime xmlTime = File.GetLastWriteTimeUtc(Path.Combine(diskHome, "state", "config.xml"));
                        Refresh(rest, currentRoot);
                        while (!stop.IsCancellationRequested && enabled() && DiskPaths.Same(root(), currentRoot)) {
                            var events = model.Events(since, stop.Token);
                            if (File.ReadAllText(Path.Combine(diskHome, "server.txt")).TrimStart('\uFEFF').Replace("\r", "").Trim() != rest.Peer) break;
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
                                if (stop.Token.WaitHandle.WaitOne(150)) break;
                                Refresh(rest, currentRoot);
                            }
                        }
                    } catch (OperationCanceledException) { break; }
                    catch (Exception) {
                        log("disk.explorer.unavailable");
                        gate.Wait(stop.Token);
                        try { Unavailable(); } finally { gate.Release(); }
                        if (stop.Token.WaitHandle.WaitOne(5000)) break;
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
            try { Publish(currentRoot, Commands(rest, currentRoot).Read(stop.Token)); }
            finally { gate.Release(); }
        }
        void Publish(string currentRoot, DiskSnapshot snapshot)
        {
            if (lastRoot != null && !DiskPaths.Same(currentRoot, lastRoot)) Clear();
            string manifest = Path.Combine(diskHome, "explorer-folders.json");
            string[] paths = snapshot.Folders.Where(f => f.Kind != DiskExplorerKind.Local).Select(f => f.Path).ToArray();
            if (File.Exists(manifest)) foreach (string old in Json.Strings(Json.Parse(File.ReadAllText(manifest))))
                if (!paths.Any(p => DiskPaths.Same(p, old))) metadata.CleanupFolder(old, true);
            metadata.Reconcile(currentRoot, snapshot.Folders);
            // Download is offered only on our empty placeholders, never on an unrelated directory of the same name.
            registry.Register(ProgramPath, currentRoot, snapshot.Folders.Where(f => !f.ServerOnly || metadata.IsPlaceholder(f.Path)), home);
            string content = Json.Encode(paths);
            if (!File.Exists(manifest) || File.ReadAllText(manifest) != content) Files.Atomic(manifest, content);
            last = snapshot; lastRoot = currentRoot;
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
                registry.Register(ProgramPath, lastRoot, last.Folders, home);
            }
            var rows = last.Folders.Select(f => { var copy = f.Copy(); if (!copy.ServerOnly && copy.Kind != DiskExplorerKind.Local) copy.Kind = DiskExplorerKind.Unavailable; return copy; }).ToArray();
            metadata.Reconcile(lastRoot, rows);
        }
        void Clear()
        {
            registry.Cleanup();
            foreach (var row in last.Folders) metadata.CleanupFolder(row.Path, true);
            last = new DiskSnapshot(); lastRoot = null;
        }
        public void Dispose() { stop.Cancel(); }
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
