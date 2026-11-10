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
        public Dictionary<string, object> Data;
        public static Manifest Parse(string text)
        {
            var d = Json.Map(Json.Parse(text)); var launcher = Json.Map(Json.Get(d, "launcher")); long size;
            var m = new Manifest { Data = d, Version = Files.SafeVersion(Json.Str(d, "version")), FileName = Json.Str(d, "file"), Sha256 = Json.Str(d, "sha256"),
                Minimum = Json.Text(d, "minLauncher", "1.0.0"), LauncherVersion = Json.Str(launcher, "version"), LauncherHash = Json.Str(launcher, "sha256") };
            if (!System.Text.RegularExpressions.Regex.IsMatch(m.FileName, "^[A-Za-z0-9][A-Za-z0-9._-]*\\.zip$") || m.FileName.Contains("..")) throw new InvalidDataException("Недопустимое имя архива");
            if (!long.TryParse(Json.Str(d, "size"), out size) || size < 1 || size > 512L * 1024 * 1024) throw new InvalidDataException("Недопустимый размер");
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
        public UpdateEngine(string home, string launcherVersion, Func<DateTime> clock = null)
        { Home = home; Root = Path.Combine(home, Product.BundleDirectory); this.launcherVersion = launcherVersion; now = clock ?? (() => DateTime.UtcNow); Directory.CreateDirectory(Root); }
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
        public string Prepare(Manifest m, Action<string> fetch, Func<string, bool> selftest, Action<BundleDefinition, string> binaries, CancellationToken token, bool downgrade = false)
        {
            if (!Eligible(m, downgrade)) return null;
            var part = Path.Combine(Root, m.Version + ".part"); var tmp = Folder(m.Version) + ".tmp";
            try {
                token.ThrowIfCancellationRequested(); fetch(part); token.ThrowIfCancellationRequested();
                if (new FileInfo(part).Length != m.Size || !Files.Hash(part).Equals(m.Sha256, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Проверка архива не прошла");
                if (Directory.Exists(tmp)) Directory.Delete(tmp, true); Directory.CreateDirectory(tmp);
                Extract(part, tmp); var definition = BundleDefinition.Load(tmp); binaries(definition, tmp); token.ThrowIfCancellationRequested();
                if (m.LauncherVersion.Length > 0) {
                    var exe = Path.Combine(tmp, Product.ExeName);
                    if (!File.Exists(exe) || !Files.Hash(exe).Equals(m.LauncherHash, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Проверка лаунчера не прошла");
                }
                if (File.Exists(Path.Combine(tmp, "selftest.ps1")) && !selftest(tmp)) { MarkBad(m.Version); throw new InvalidDataException("Самопроверка бандла не прошла"); }
                token.ThrowIfCancellationRequested(); Json.Write(Path.Combine(tmp, ".launcher-manifest.json"), m.Data);
                // Rebuild unactivated leftovers after a power loss, never trust their contents.
                if (Directory.Exists(Folder(m.Version))) Directory.Delete(Folder(m.Version), true);
                Directory.Move(tmp, Folder(m.Version)); return m.Version;
            } finally { if (File.Exists(part)) File.Delete(part); if (Directory.Exists(tmp)) Directory.Delete(tmp, true); }
        }
        public void Activate(string version)
        {
            Files.SafeVersion(version); BundleDefinition.Load(Folder(version));
            if (Pending) throw new InvalidOperationException("Уже ожидается проверка здоровья");
            string old = Current;
            if (old.Length == 0) { Files.Atomic(Path.Combine(Root, "current.txt"), version + "\n"); Cleanup(); return; }
            // Write recovery record first; interrupted activation is recognized by Recover().
            Json.Write(PendingPath, new { version, previous = old, startedUtc = now().ToString("o") });
            Files.Atomic(Path.Combine(Root, "previous.txt"), old + "\n");
            Files.Atomic(Path.Combine(Root, "current.txt"), version + "\n"); Cleanup();
        }
        public void Recover()
        {
            if (Pending) {
                var p = Json.Read(PendingPath); string version = Files.SafeVersion(Json.Str(p, "version"));
                if (Current != version) File.Delete(PendingPath); // interrupted activation, or completed rollback
            }
            if (Current.Length == 0) return;
            try { BundleDefinition.Load(Folder(Current)); }
            catch { Rollback(); } // A broken components.json must not prevent reaching the recovery path.
        }
        public string Observe(bool allCriticalHealthy)
        {
            if (!Pending) return "";
            var p = Json.Read(PendingPath);
            if (Current != Json.Str(p, "version")) { Recover(); return ""; }
            DateTime start;
            if (!DateTime.TryParse(Json.Str(p, "startedUtc"), null, System.Globalization.DateTimeStyles.RoundtripKind, out start)) throw new InvalidDataException("Неверная запись обновления");
            if ((now() - start.ToUniversalTime()).TotalSeconds >= 120) { Rollback(); return "rollback"; }
            if (allCriticalHealthy) { File.Delete(PendingPath); Cleanup(); return "accepted"; }
            return "";
        }
        public void Rollback()
        {
            string target = Pending ? Files.SafeVersion(Json.Str(Json.Read(PendingPath), "previous")) : Previous;
            if (target.Length == 0 || target == Current || !Directory.Exists(Folder(target))) throw new InvalidOperationException("Нет предыдущего бандла");
            BundleDefinition.Load(Folder(target)); string bad = Current; MarkBad(bad);
            Files.Atomic(Path.Combine(Root, "current.txt"), target + "\n");
            if (Pending) File.Delete(PendingPath);
            Files.Atomic(Path.Combine(Root, "previous.txt"), ""); Cleanup();
        }
        public void Cleanup()
        {
            var keep = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { Current, Previous };
            if (Pending) { var p = Json.Read(PendingPath); keep.Add(Json.Str(p, "version")); keep.Add(Json.Str(p, "previous")); }
            var versions = Directory.GetDirectories(Root).Where(d => File.Exists(Path.Combine(d, "components.json")) && !d.EndsWith(".tmp", StringComparison.OrdinalIgnoreCase)).OrderByDescending(d => Path.GetFileName(d), Comparer<string>.Create(Files.Compare)).ToList();
            foreach (var dir in versions) if (keep.Count(v => v.Length > 0) < 3) keep.Add(Path.GetFileName(dir));
            foreach (var dir in versions) if (!keep.Contains(Path.GetFileName(dir))) Directory.Delete(dir, true);
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
                    string part = cache + ".part";
                    try {
                        ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
                        var request = (HttpWebRequest)WebRequest.Create(uri); request.Timeout = 90000; request.ReadWriteTimeout = 90000;
                        using (token.Register(() => request.Abort())) using (var response = request.GetResponse()) using (var stream = response.GetResponseStream()) using (var file = File.Create(part)) {
                            var bytes = new byte[65536]; int n; long size = 0;
                            while ((n = stream.Read(bytes, 0, bytes.Length)) > 0) { token.ThrowIfCancellationRequested(); size += n; if (size > 512L * 1024 * 1024) throw new InvalidDataException("Бинарник слишком большой"); file.Write(bytes, 0, n); }
                        }
                        if (!Files.Hash(part).Equals(hash, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Неверный SHA256 бинарника");
                        if (File.Exists(cache)) File.Delete(cache); File.Move(part, cache);
                    } finally { if (File.Exists(part)) File.Delete(part); }
                }
                Directory.CreateDirectory(Path.GetDirectoryName(path)); File.Copy(cache, path, true);
            }
        }
    }
}
