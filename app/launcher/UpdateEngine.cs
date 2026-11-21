using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Threading;

namespace RemoteAgents.Launcher
{
    internal sealed class Manifest
    {
        public string Version, FileName, Sha256, Minimum, LauncherVersion, LauncherHash; public long Size;
        public int ConfigSchema;
        public Dictionary<string, object> Data;
        public static Manifest Parse(string text)
        {
            var d = Json.Map(Json.Parse(text)); var launcher = Json.Map(Json.Get(d, "launcher")); long size;
            var m = new Manifest { Data = d, Version = Files.SafeVersion(Json.Str(d, "version")), FileName = Json.Str(d, "file"), Sha256 = Json.Str(d, "sha256"),
                Minimum = Json.Text(d, "minLauncher", "1.0.0"), LauncherVersion = Json.Str(launcher, "version"), LauncherHash = Json.Str(launcher, "sha256") };
            if (!System.Text.RegularExpressions.Regex.IsMatch(m.FileName, "^[A-Za-z0-9][A-Za-z0-9._-]*\\.zip$") || m.FileName.Contains("..")) throw new InvalidDataException("Недопустимое имя архива");
            if (!long.TryParse(Json.Str(d, "size"), out size) || size < 1 || size > 512L * 1024 * 1024) throw new InvalidDataException("Недопустимый размер");
            m.ConfigSchema = Json.Int(d, "configSchema", 1); if (d.ContainsKey("configSchema") && (d["configSchema"] is string || d["configSchema"] is bool || !int.TryParse(Json.Str(d, "configSchema"), out m.ConfigSchema)) || m.ConfigSchema < 1) throw new InvalidDataException("Неверная схема конфига в манифесте");
            m.Size = size; Files.HashValid(m.Sha256); Files.SafeVersion(m.Minimum);
            if (m.LauncherVersion.Length != 0) { Files.SafeVersion(m.LauncherVersion); Files.HashValid(m.LauncherHash); }
            return m;
        }
    }
    // Filesystem transaction only. No UI, process launching, registry, SSH or Windows dependencies.
    // Tests inject download/selftest and clock; production performs them over SSH / PowerShell 5.1.
    internal sealed class UpdateEngine
    {
        public readonly string Home, Root; readonly string launcherVersion;
        readonly Func<DateTime> now;
        // Injection keeps cleanup tests about operations / ownership, independent of disk speed.
        internal sealed class CleanupOperations
        {
            internal Action<string, string> Move = Directory.Move;
            internal Action<string> Delete = path => Directory.Delete(path, true);
            internal Action<Action> Queue = work => ThreadPool.QueueUserWorkItem(_ => work());
        }
        readonly CleanupOperations cleanup;
        int cleanupQueued, cleanupRequested;
        public UpdateEngine(string home, string launcherVersion, Func<DateTime> clock = null, CleanupOperations cleanup = null)
        {
            Home = home; Root = Path.Combine(home, Product.BundleDirectory); this.launcherVersion = launcherVersion;
            now = clock ?? (() => DateTime.UtcNow); this.cleanup = cleanup ?? new CleanupOperations(); Directory.CreateDirectory(Root);
            QueueTrashCleanup(); // Retry detached leftovers after an interrupted / denied deletion.
        }
        static bool IsTrash(string path)
        {
            string name = Path.GetFileName(path); Guid id;
            return name.StartsWith(".trash-", StringComparison.Ordinal) && Guid.TryParseExact(name.Substring(7), "N", out id);
        }
        void QueueTrashCleanup()
        {
            Interlocked.Exchange(ref cleanupRequested, 1);
            if (Interlocked.CompareExchange(ref cleanupQueued, 1, 0) != 0) return;
            cleanup.Queue(() => {
                try {
                    do {
                        Interlocked.Exchange(ref cleanupRequested, 0);
                        try {
                            // .trash paths cannot be Current/Previous/Pending (SafeVersion rejects them).
                            // No receipt lease is held here; failures leave resumable detached leftovers.
                            foreach (string path in Directory.GetDirectories(Root, ".trash-*")) if (IsTrash(path)) {
                                try { cleanup.Delete(path); }
                                catch (IOException) { }
                                catch (UnauthorizedAccessException) { }
                            }
                        } catch (IOException) { }
                        catch (UnauthorizedAccessException) { }
                    } while (Volatile.Read(ref cleanupRequested) != 0);
                } finally {
                    Interlocked.Exchange(ref cleanupQueued, 0);
                    // Do not lose a detach arriving between the final scan and releasing worker ownership.
                    if (Volatile.Read(ref cleanupRequested) != 0) QueueTrashCleanup();
                }
            });
        }
        void DetachTrash(string path)
        { cleanup.Move(path, Path.Combine(Root, ".trash-" + Guid.NewGuid().ToString("N"))); }
        public string Current { get { var s = Files.ReadLine(Path.Combine(Root, "current.txt")); return s.Length == 0 ? "" : Files.SafeVersion(s); } }
        public string Previous { get { var s = Files.ReadLine(Path.Combine(Root, "previous.txt")); return s.Length == 0 ? "" : Files.SafeVersion(s); } }
        public string Folder(string version) { return Path.Combine(Root, Files.SafeVersion(version)); }
        string PendingPath { get { return Path.Combine(Root, "pending.json"); } }
        public bool Pending { get { return File.Exists(PendingPath); } }
        public bool IsBad(string version) { return Files.LF(Files.ReadLine(Path.Combine(Root, "bad.txt"))).Split('\n').Contains(version); }
        public void MarkBad(string version)
        { Files.SafeVersion(version); var values = Files.LF(Files.ReadLine(Path.Combine(Root, "bad.txt"))).Split('\n').Where(v => v.Length != 0).ToList(); if (!values.Contains(version)) values.Add(version); Files.Atomic(Path.Combine(Root, "bad.txt"), string.Join("\n", values) + "\n"); }
        public bool Eligible(Manifest m, bool downgrade = false)
        { return !Pending && (downgrade || !IsBad(m.Version)) && (Current.Length == 0 || Files.Compare(m.Version, Current) > 0 || (downgrade && m.Version != Current)) && Files.Compare(m.Minimum, launcherVersion) <= 0; }
        // A preparation owns only this random directory; Cleanup and concurrent calls ignore it.
        internal sealed class PreparedBundle : IDisposable
        {
            internal readonly Manifest Manifest;
            internal readonly string DirectoryPath, BundlePath, Current, Previous;
            internal readonly bool Downgrade;
            internal PreparedBundle(UpdateEngine engine, Manifest manifest, bool downgrade)
            {
                Manifest = manifest; Downgrade = downgrade; Current = engine.Current; Previous = engine.Previous;
                DirectoryPath = Path.Combine(engine.Root, ".stage-" + manifest.Version + "-" + Guid.NewGuid().ToString("N") + ".tmp");
                BundlePath = Path.Combine(DirectoryPath, "bundle");
            }
            public void Dispose() { if (Directory.Exists(DirectoryPath)) Directory.Delete(DirectoryPath, true); }
        }
        internal PreparedBundle Stage(Manifest m, Action<string> fetch, Func<string, bool> selftest, Action<BundleDefinition, string> binaries, CancellationToken token, bool downgrade)
        {
            PreparedBundle staged;
            using (UpgradeInstaller.LockReceipt(Home, token, 1000)) {
                UpgradeInstaller.RequireReceiptRecovery(Home);
                if (!Eligible(m, downgrade) || File.Exists(UpgradeInstaller.ReceiptPath(Home))) return null;
                staged = new PreparedBundle(this, m, downgrade);
            }
            try {
                string part = Path.Combine(staged.DirectoryPath, "archive.part"), tmp = staged.BundlePath;
                Directory.CreateDirectory(tmp);
                token.ThrowIfCancellationRequested(); fetch(part); token.ThrowIfCancellationRequested();
                if (new FileInfo(part).Length != m.Size || !Files.Hash(part).Equals(m.Sha256, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Проверка архива не прошла");
                Extract(part, tmp); var definition = BundleDefinition.Load(tmp); binaries(definition, tmp); token.ThrowIfCancellationRequested();
                if (m.LauncherVersion.Length > 0) {
                    var exe = Path.Combine(tmp, Product.ExeName);
                    if (!File.Exists(exe) || !Files.Hash(exe).Equals(m.LauncherHash, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Проверка лаунчера не прошла");
                }
                if (m.Data.ContainsKey("configSchema") && !File.Exists(Path.Combine(tmp, "selftest.ps1"))) throw new InvalidDataException("Нет самопроверки бандла");
                if (File.Exists(Path.Combine(tmp, "selftest.ps1")) && !selftest(tmp)) {
                    using (UpgradeInstaller.LockReceipt(Home, token, 1000)) { if (Eligible(m, downgrade)) MarkBad(m.Version); }
                    throw new InvalidDataException("Самопроверка бандла не прошла");
                }
                token.ThrowIfCancellationRequested(); Json.Write(Path.Combine(tmp, ".launcher-manifest.json"), m.Data);
                return staged;
            } catch { staged.Dispose(); throw; }
        }
        // Caller holds receipt-mutex through publication and (for Apply) activation.
        internal string Publish(PreparedBundle staged, CancellationToken token)
        {
            UpgradeInstaller.RequireReceiptRecovery(Home);
            var m = staged.Manifest;
            if (Current != staged.Current || Previous != staged.Previous || !Eligible(m, staged.Downgrade) ||
                File.Exists(UpgradeInstaller.ReceiptPath(Home)) || string.Equals(m.Version, Current, StringComparison.OrdinalIgnoreCase) || string.Equals(m.Version, Previous, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Состояние обновления изменилось; повторите установку");
            token.ThrowIfCancellationRequested();
            // Only unreferenced leftovers can be rebuilt. Active and rollback bundles are immutable.
            try {
                if (Directory.Exists(Folder(m.Version))) DetachTrash(Folder(m.Version));
                Directory.Move(staged.BundlePath, Folder(m.Version)); return m.Version;
            } finally { QueueTrashCleanup(); }
        }
        public string Prepare(Manifest m, Action<string> fetch, Func<string, bool> selftest, Action<BundleDefinition, string> binaries, CancellationToken token, bool downgrade = false)
        {
            using (var staged = Stage(m, fetch, selftest, binaries, token, downgrade)) {
                if (staged == null) return null;
                using (UpgradeInstaller.LockReceipt(Home, token, 1000)) return Publish(staged, token);
            }
        }
        public void Activate(string version, bool accept = false, bool imagePrepared = false)
        {
            using (UpgradeInstaller.LockReceipt(Home)) {
                UpgradeInstaller.RecoverPreviousRollback(Home);
                Files.SafeVersion(version); BundleDefinition.Load(Folder(version));
                if (Pending) throw new InvalidOperationException("Уже ожидается проверка здоровья");
                string old = Current;
                if (!imagePrepared) UpgradeInstaller.SaveBundlePrevious(Home, this, old);
                // Accepted activation (unfinished first setup): nothing works yet, so no health deadline or rollback.
                if (accept && old.Length != 0) { Files.Atomic(Path.Combine(Root, "previous.txt"), old + "\n"); Files.Atomic(Path.Combine(Root, "current.txt"), version + "\n"); Cleanup(); return; }
                if (old.Length == 0) { Files.Atomic(Path.Combine(Root, "current.txt"), version + "\n"); Cleanup(); return; }
                // Write recovery record first; interrupted activation is recognized by Recover().
                Json.Write(PendingPath, new { version, previous = old, startedUtc = now().ToString("o") });
                Files.Atomic(Path.Combine(Root, "previous.txt"), old + "\n");
                Files.Atomic(Path.Combine(Root, "current.txt"), version + "\n"); Cleanup();
            }
        }
        public void Recover()
        {
            using (UpgradeInstaller.LockReceipt(Home)) {
                if (Pending) {
                    var p = Json.Read(PendingPath); string version = Files.SafeVersion(Json.Str(p, "version"));
                    if (Current != version) File.Delete(PendingPath); // interrupted activation, or completed rollback
                }
                if (Current.Length == 0) return;
                try { BundleDefinition.Load(Folder(Current)); }
                catch { Rollback(); } // A broken components.json must not prevent reaching the recovery path.
            }
        }
        public string Observe(bool allCriticalHealthy, bool failed = false)
        {
            using (UpgradeInstaller.LockReceipt(Home)) {
                if (!Pending) return "";
                var p = Json.Read(PendingPath);
                if (Current != Json.Str(p, "version")) { Recover(); return ""; }
                if (failed) { Rollback(); return "rollback"; }
                if (allCriticalHealthy) { File.Delete(PendingPath); Cleanup(); return "accepted"; }
                return "";
            }
        }
        public void Rollback()
        {
            using (UpgradeInstaller.LockReceipt(Home)) {
                string target = Pending ? Files.SafeVersion(Json.Str(Json.Read(PendingPath), "previous")) : Previous;
                if (target.Length == 0 || target == Current || !Directory.Exists(Folder(target))) throw new InvalidOperationException("Нет предыдущего бандла");
                BundleDefinition.Load(Folder(target)); string bad = Current; MarkBad(bad);
                Files.Atomic(Path.Combine(Root, "current.txt"), target + "\n");
                if (Pending) File.Delete(PendingPath);
                Files.Atomic(Path.Combine(Root, "previous.txt"), ""); UpgradeInstaller.DiscardPrevious(Home); Cleanup();
            }
        }
        public void Cleanup()
        {
            try {
                using (UpgradeInstaller.LockReceipt(Home)) {
                    var keep = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { Current, Previous };
                    if (Pending) { var p = Json.Read(PendingPath); keep.Add(Json.Str(p, "version")); keep.Add(Json.Str(p, "previous")); }
                    var versions = Directory.GetDirectories(Root).Where(d => !Path.GetFileName(d).StartsWith(".", StringComparison.Ordinal) &&
                        File.Exists(Path.Combine(d, "components.json")) && !d.EndsWith(".tmp", StringComparison.OrdinalIgnoreCase))
                        .OrderByDescending(d => Path.GetFileName(d), Comparer<string>.Create(Files.Compare)).ToList();
                    foreach (var dir in versions) if (keep.Count(v => v.Length > 0) < 3) keep.Add(Path.GetFileName(dir));
                    // Under receipt-mutex only detach unreferenced versions, never traverse/delete files.
                    foreach (var dir in versions) if (!keep.Contains(Path.GetFileName(dir))) DetachTrash(dir);
                }
            } finally { QueueTrashCleanup(); }
        }
        public static void Extract(string zip, string folder)
        {
            using (var archive = ZipFile.OpenRead(zip)) {
                long total = 0; var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (var entry in archive.Entries) {
                    // No links or Windows special filenames / ADS. Also reject case-folded duplicates.
                    string name = entry.FullName.Replace('\\', '/');
                    var parts = name.TrimEnd('/').Split('/');
                    if (parts.Any(s => s.Length == 0 || s == "." || s == ".." || s.EndsWith(" ") || s.EndsWith(".") ||
                        s.IndexOfAny(new[] { '<', '>', '"', '|', '?', '*', ':' }) >= 0 ||
                        System.Text.RegularExpressions.Regex.IsMatch(s, "^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])($|\\.)", System.Text.RegularExpressions.RegexOptions.IgnoreCase))) throw new InvalidDataException("Недопустимое имя ZIP");
                    if (!seen.Add(name.TrimEnd('/'))) throw new InvalidDataException("Повтор имени ZIP");
                    if (((entry.ExternalAttributes >> 16) & 0xF000) == 0xA000) throw new InvalidDataException("Ссылки в ZIP запрещены");
                    string dest = Files.Under(folder, name);
                    total += entry.Length; if (total > 1024L * 1024 * 1024) throw new InvalidDataException("Слишком большой бандл");
                    if (name.EndsWith("/")) Directory.CreateDirectory(dest);
                    else { Directory.CreateDirectory(Path.GetDirectoryName(dest)); using (var source = entry.Open()) using (var target = new FileStream(dest, FileMode.CreateNew)) source.CopyTo(target); }
                }
            }
        }
        public static void InstallBinaries(BundleDefinition definition, string folder, string home, CancellationToken token)
        {
            foreach (var binary in definition.Binaries) {
                token.ThrowIfCancellationRequested(); string hash = Json.Str(binary, "sha256"); Files.HashValid(hash); hash = hash.ToLowerInvariant();
                string path = Files.Under(Path.Combine(folder, "bin"), Json.Str(binary, "path"));
                string cache = Path.Combine(home, "cache", hash); Directory.CreateDirectory(Path.GetDirectoryName(cache));
                if (!File.Exists(cache) || !Files.Hash(cache).Equals(hash, StringComparison.OrdinalIgnoreCase)) {
                    var uri = new Uri(Json.Str(binary, "url")); if (uri.Scheme != "https") throw new InvalidDataException("Бинарники требуют HTTPS");
                    string part = cache + "." + Guid.NewGuid().ToString("N") + ".part";
                    try {
                        ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
                        var request = (HttpWebRequest)WebRequest.Create(uri); request.Timeout = 90000; request.ReadWriteTimeout = 90000;
                        using (token.Register(() => request.Abort())) using (var response = request.GetResponse()) using (var stream = response.GetResponseStream()) using (var file = File.Create(part)) {
                            var bytes = new byte[65536]; int n; long size = 0;
                            while ((n = stream.Read(bytes, 0, bytes.Length)) > 0) { token.ThrowIfCancellationRequested(); size += n; if (size > 512L * 1024 * 1024) throw new InvalidDataException("Бинарник слишком большой"); file.Write(bytes, 0, n); }
                        }
                        if (!Files.Hash(part).Equals(hash, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Неверный SHA256 бинарника");
                        using (UpgradeInstaller.LockReceipt(home, token, 1000)) {
                            if (!File.Exists(cache) || !Files.Hash(cache).Equals(hash, StringComparison.OrdinalIgnoreCase)) {
                                if (File.Exists(cache)) File.Delete(cache); File.Move(part, cache);
                            }
                        }
                    } finally { if (File.Exists(part)) File.Delete(part); }
                }
                Directory.CreateDirectory(Path.GetDirectoryName(path)); File.Copy(cache, path, true);
            }
        }
    }
}
