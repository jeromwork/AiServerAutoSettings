using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace RemoteAgents.Launcher
{
    // Explorer has no built-in Syncthing projection. Only presentation is ours; selection and
    // inventory still use ConfigApply/Wizard and the existing REST snapshot.
    internal sealed class DiskExplorerController : IDisposable
    {
        readonly string home;
        readonly Dictionary<string, string> ignoreProofs = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        string preparedIgnores = "";
        readonly object metadataGate = new object();
        readonly Func<string> bundle;
        readonly Action<string> log;
        readonly DiskExplorerService metadata;
        readonly DiskExplorerRegistry registry;
        readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer { Interval = 2500 };
        readonly CancellationTokenSource stop = new CancellationTokenSource();
        readonly Dictionary<string, string> knownConfigured = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        readonly HashSet<string> decoratedExternal = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        readonly Dictionary<string, string> serverFolders = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        string root = "", inventoryBinding = "";
        DateTime nextInventory = DateTime.MinValue, nextIgnoreCheck = DateTime.MinValue;
        bool reading, inventoryReading, cleaned;
        volatile bool disposed;
        internal DiskSyncSnapshot Snapshot { get; private set; } = new DiskSyncSnapshot();
        internal Dictionary<string, string> Paths { get; private set; } = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        internal string ObservedBinding { get; private set; } = "";
        internal event Action Changed = delegate { };
        internal DiskExplorerController(string home, Func<string> bundle, Action<string> log)
        {
            this.home = home; this.bundle = bundle; this.log = log;
            metadata = DiskExplorerNative.CreateService(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RemoteAgents", "icons"), log);
            registry = DiskExplorerNative.CreateRegistry(log);
            timer.Tick += async (s, e) => await Refresh(); timer.Start();
        }
        internal static string Root(Dictionary<string, object> profile)
        { return Json.Text(Json.Map(Json.Get(profile, "disk")), "base", ConfigSession.DiskBase()); }
        internal static string SyncHome(Dictionary<string, object> settings)
        { return Json.Text(Json.Map(Json.Get(settings, "disk")), "home", Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RemoteDisk")); }
        internal async Task Refresh()
        {
            if (disposed || reading) return; reading = true;
            try {
                var settings = new Configuration(home).Data;
                var profile = ConfigProfile.Load(home); string nextRoot = Root(profile);
                bool enabled = Json.Bool(Json.Map(Json.Get(Json.Map(Json.Get(settings, "components")), "disk")), "enabled");
                if (root.Length > 0 && (!DiskSyncSnapshot.SamePath(root, nextRoot) || !enabled && !cleaned)) {
                    string oldRoot = root; await Task.Run(() => { lock (metadataGate) metadata.Cleanup(oldRoot); }, stop.Token); registry.Cleanup(); cleaned = false;
                }
                root = nextRoot;
                if (!enabled) { if (!cleaned) { await CleanupDisabled(); cleaned = true; } Paths = new Dictionary<string, string>(); Snapshot = DiskSyncSnapshot.Unavailable("Диск выключен"); Changed(); return; }
                string binding = root + "|" + SyncHome(settings) + "|" + ConfigSections.Hash(profile, ConfigSections.Server);
                if (binding != inventoryBinding) { serverFolders.Clear(); knownConfigured.Clear(); inventoryBinding = binding; nextInventory = DateTime.MinValue; }
                var choice = DiskChoice.FromProfile(profile);
                var externalFolders = choice.External.Concat(RegisteredExternal(SyncHome(settings))).GroupBy(e => e.Remote, StringComparer.OrdinalIgnoreCase).Select(g => g.First()).ToArray();
                var model = new DiskFoldersModel(choice, ConfigProfile.AppliedDiskChoice(home, profile), ConfigProfile.DiskExclusions(SyncHome(settings)));
                var local = await Task.Run(() => Directory.Exists(root) ? Directory.EnumerateDirectories(root).Select(Path.GetFileName).ToArray() : new string[0], stop.Token);
                var names = serverFolders.Keys.Concat(local).Concat(choice.Folders.Select(f => DiskChoice.Project(f.Path))).Concat(externalFolders.Select(e => e.Remote)).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
                var folders = names.Select(n => new DiskExplorerFolder { Name = n, Selected = model.Includes(n) || model.Partial(n), ServerOnly = serverFolders.ContainsKey(n) }).ToArray();
                var observedPaths = folders.ToDictionary(f => f.Name, f => externalFolders.Any(e => e.Remote.Equals(f.Name, StringComparison.OrdinalIgnoreCase)) ? externalFolders.First(e => e.Remote.Equals(f.Name, StringComparison.OrdinalIgnoreCase)).Path : Path.Combine(root, f.Name), StringComparer.OrdinalIgnoreCase);
                string policyBinding = binding + "|" + SyncHome(settings) + "|" + ConfigSections.Hash(profile, ConfigSections.Disk);
                var snapshot = await Task.Run(() => DiskSyncMonitor.Read(SyncHome(settings), observedPaths, stop.Token), stop.Token);
                if (disposed || binding != inventoryBinding) return;
                // A selection edited while REST was in flight is read on the next tick, never applied as an operation.
                if (ConfigSections.Hash(ConfigProfile.Load(home), ConfigSections.Disk) != ConfigSections.Hash(profile, ConfigSections.Disk)) return;
                foreach (var folder in folders) folder.Selected = DiskExplorerObservation.EffectiveSelection(folder.Selected, folder.Name, observedPaths[folder.Name], snapshot, knownConfigured);
                if (snapshot.Failure.Length == 0) {
                    knownConfigured.Clear();
                    foreach (var pair in snapshot.Folders.Where(p => p.Value.Id.Length > 0 && p.Value.Shared && observedPaths.ContainsKey(p.Key) && DiskSyncSnapshot.SamePath(p.Value.Path, observedPaths[p.Key])))
                        knownConfigured[pair.Key] = pair.Value.Path;
                }
                var paths = folders.Where(f => f.Selected).ToDictionary(f => f.Name, f => observedPaths[f.Name], StringComparer.OrdinalIgnoreCase);
                // Publish REST before the optional cosmetic policy preparation (which may wait for a process).
                ObservedBinding = DiskApplyWait.Binding(profile) + "|" + SyncHome(settings); Snapshot = snapshot; Paths = paths; Changed();
                if ((policyBinding != preparedIgnores || DateTime.UtcNow >= nextIgnoreCheck) && !BackgroundWork.Disk.Busy && DiskRecoverySchedule.Missing(paths, snapshot).Count == 0) {
                    await PrepareIgnores(SyncHome(settings)); preparedIgnores = policyBinding; nextIgnoreCheck = DateTime.UtcNow.AddSeconds(60);
                }
                if (disposed || DiskApplyWait.Binding(profile) != DiskApplyWait.Binding(ConfigProfile.Load(home))) return;
                string currentRoot = root;
                await Task.Run(() => { lock (metadataGate) { if (disposed || stop.IsCancellationRequested) return; var safe = folders.Where(folder => {
                        string path = Path.Combine(currentRoot, folder.Name);
                        bool configured = folder.Selected || snapshot.ConfiguredPaths.Any(p => DiskSyncSnapshot.SamePath(p, path)) || Directory.Exists(Path.Combine(path, ".stfolder"));
                        if (!configured || IgnoreStillConfirmed(path)) return true;
                        log("explorer.ignore.unconfirmed"); return false;
                    }).ToArray();
                    metadata.Reconcile(currentRoot, safe, snapshot);
                    foreach (var folder in folders) folder.ServerOnly = metadata.IsPlaceholder(Path.Combine(currentRoot, folder.Name));
                    foreach (string old in decoratedExternal.Where(p => !externalFolders.Any(e => DiskSyncSnapshot.SamePath(e.Path, p))).ToArray()) { metadata.CleanupExternal(old); decoratedExternal.Remove(old); }
                    foreach (var external in externalFolders) {
                        if (folders.Any(f => f.Name.Equals(external.Remote, StringComparison.OrdinalIgnoreCase) && f.Selected) && IgnoreStillConfirmed(external.Path) && metadata.ReconcileExternal(external.Path, external.Remote, snapshot, true)) decoratedExternal.Add(external.Path);
                        else metadata.CleanupExternal(external.Path);
                    }
                } }, stop.Token);
                if (disposed) return;
                registry.Register(Program.Exe, root, folders, home); cleaned = false;
                ObservedBinding = DiskApplyWait.Binding(profile) + "|" + SyncHome(settings); Snapshot = snapshot; Paths = paths; Changed();
                if (DateTime.UtcNow >= nextInventory && !inventoryReading && !BackgroundWork.Disk.Busy) RefreshInventory(binding, currentRoot);
            } catch (OperationCanceledException) { }
            catch (Exception) { log("explorer.refresh.failed"); }
            finally { reading = false; }
        }
        async void RefreshInventory(string binding, string diskRoot)
        {
            inventoryReading = true; nextInventory = DateTime.UtcNow.AddSeconds(60);
            try {
                string currentBundle = bundle();
                var result = await Task.Run(() => ServerOperations.Invoke(home, currentBundle, "DiskTree", new { @base = diskRoot, path = "" }, stop.Token), stop.Token);
                if (disposed || binding != inventoryBinding) return;
                var union = Json.Map(Json.Get(result, "union"));
                var rows = Json.Array(Json.Get(union, "rows")).Select(Json.Map).ToArray();
                if (!Json.Bool(union, "truncated")) serverFolders.Clear();
                foreach (var row in rows.Where(r => Json.Str(r, "kind") == "directory" && new[] { "server", "both" }.Contains(Json.Str(r, "presence")))) {
                    string name = Json.Str(row, "path");
                    if (name.Length > 0 && name != "." && name != ".." && name.IndexOfAny(new[] { '/', '\\' }) < 0) serverFolders[name] = name;
                }
            } catch (OperationCanceledException) { }
            catch (Exception) { log("explorer.inventory.failed"); }
            finally { inventoryReading = false; }
        }
        static IEnumerable<DiskExternalChoice> RegisteredExternal(string diskHome)
        {
            try {
                var data = Json.Read(Path.Combine(diskHome, "external.json"));
                if (Json.Int(data, "schema", 0) != 1) return new DiskExternalChoice[0];
                return Json.Array(Json.Get(data, "items")).Select(Json.Map)
                    .Where(e => DiskExplorerService.ValidName(Json.Str(e, "remote")) && Path.IsPathRooted(Json.Str(e, "path")))
                    .Select(e => new DiskExternalChoice { Remote = Json.Str(e, "remote"), Path = Json.Str(e, "path") }).ToArray();
            } catch (Exception) { return new DiskExternalChoice[0]; }
        }
        internal void MarkPlaceholder(string path)
        { lock (metadataGate) { if (disposed) throw new OperationCanceledException(); if (!metadata.MarkPlaceholder(path)) throw new IOException("Папка изменилась; заглушка не создана"); } }
        internal static string IgnoreFingerprint(string path)
        {
            string file = Path.Combine(path, ".stignore");
            if (!File.Exists(file) || (File.GetAttributes(file) & FileAttributes.ReparsePoint) != 0) return "";
            using (var sha = System.Security.Cryptography.SHA256.Create())
                return BitConverter.ToString(sha.ComputeHash(Files.Utf8.GetBytes(Files.LF(File.ReadAllText(file)).TrimEnd('\n') + "\n"))).Replace("-", "").ToLowerInvariant();
        }
        bool IgnoreStillConfirmed(string path)
        { string expected; return ignoreProofs.TryGetValue(Path.GetFullPath(path).TrimEnd('\\', '/'), out expected) && expected.Length > 0 && IgnoreFingerprint(path) == expected; }
        async Task PrepareIgnores(string diskHome)
        {
            string diskRoot = root, currentBundle = bundle();
            string output = Path.Combine(home, "state", "explorer-ignore-" + Guid.NewGuid().ToString("N") + ".json");
            var proofs = await Task.Run(() => {
                var found = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                string script = Path.Combine(currentBundle, "disk", "Ensure-DiskExplorerIgnores.ps1");
                try {
                    if (!File.Exists(script)) return found;
                    if (External.Run(Files.Executable("powershell.exe"), new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-Base", diskRoot, "-DiskHome", diskHome, "-OutputFile", output }, currentBundle, null, 45000, 1024, stop.Token) != 0) {
                        log("explorer.ignore.prepare.failed"); return found;
                    }
                    foreach (object item in Json.Array(Json.Get(Json.Read(output), "proofs"))) {
                        var proof = Json.Map(item); string path = Json.Str(proof, "path"), fingerprint = Json.Str(proof, "sha256");
                        if (fingerprint.Length == 64 && IgnoreFingerprint(path) == fingerprint) found[path] = fingerprint;
                    }
                    return found;
                } finally { if (File.Exists(output)) File.Delete(output); }
            }, stop.Token);
            ignoreProofs.Clear(); foreach (var pair in proofs) ignoreProofs[pair.Key] = pair.Value;
        }
        async Task CleanupDisabled()
        {
            string diskRoot = root, currentBundle = bundle(), diskHome = SyncHome(new Configuration(home).Data);
            await Task.Run(() => {
                lock (metadataGate) { metadata.Cleanup(diskRoot); foreach (string path in decoratedExternal) metadata.CleanupExternal(path); decoratedExternal.Clear(); }
                // The existing PowerShell external-folder receipts own the junction lifecycle.
                string script = Path.Combine(currentBundle, "disk", "Remove-DiskExplorer.ps1");
                if (File.Exists(script) && External.Run(Files.Executable("powershell.exe"), new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-Base", diskRoot, "-DiskHome", diskHome, "-KeepJunctions" }, currentBundle, null, 30000, 1024, stop.Token) != 0)
                    throw new IOException("Очистка оформления не завершена");
            }, stop.Token);
            if (disposed) return;
            registry.Cleanup();
            DiskExplorerNative.CleanupIcons(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RemoteAgents", "icons"));
        }
        public void Dispose()
        { if (disposed) return; disposed = true; timer.Stop(); timer.Dispose(); stop.Cancel(); lock (metadataGate) { } }
    }
}
