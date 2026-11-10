using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Threading;

namespace RemoteAgents.Launcher
{
    // Shared by the downloaded-EXE installer and the upgrade selftest. Never replaces user directories.
    internal static class UpgradeInstaller
    {
        public static string ExtractEmbedded(string destination)
        {
            using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("RemoteAgents.InitialBundle.zip")) {
                if (stream == null) throw new InvalidDataException("Нет начального бандла");
                using (var output = File.Create(destination)) stream.CopyTo(output);
            }
            return BundleVersion(destination);
        }
        public static string BundleVersion(string zip)
        {
            using (var archive = ZipFile.OpenRead(zip)) {
                var entry = archive.GetEntry("bundle-version.txt"); if (entry == null) throw new InvalidDataException("Нет версии бандла");
                using (var reader = new StreamReader(entry.Open())) return Files.SafeVersion(Files.LF(reader.ReadToEnd()).Trim());
            }
        }
        // A mixed release (one part older) requires the same explicit consent as a downgrade.
        public static int Compare(string launcher, string bundle, string installedLauncher, string installedBundle)
        {
            int l = Files.Compare(launcher, installedLauncher), b = Files.Compare(bundle, installedBundle);
            return l < 0 || b < 0 ? -1 : l > 0 || b > 0 ? 1 : 0;
        }
        public static void Apply(string home, string sourceExe, string zip, string launcherVersion, bool downgrade, Func<string, bool> selftest)
        {
            string migration = Path.Combine(home, "state", "migration.json");
            if (File.Exists(migration) && new[] { "preparing", "activating", "pending", "rolling-back" }.Contains(Json.Str(Json.Read(migration), "phase"))) throw new InvalidOperationException("Сначала завершите переход компьютера");
            var engine = new UpdateEngine(home, launcherVersion); engine.Recover();
            if (engine.Pending) throw new InvalidOperationException("Предыдущее обновление ещё проверяется");
            string version = BundleVersion(zip), old = engine.Current;
            string target = Path.Combine(home, "RemoteAgents.exe"), backup = Path.Combine(home, "RemoteAgents.previous.exe");
            if (File.Exists(Path.Combine(home, "bundle", "exe-upgrade.json"))) throw new InvalidOperationException("Лаунчер ещё проверяется");
            if (version != old) {
                var manifest = Manifest.Parse(Json.Encode(new { version, file = "embedded.zip", sha256 = Files.Hash(zip), size = new FileInfo(zip).Length, minLauncher = launcherVersion }));
                string ready = engine.Prepare(manifest, p => File.Copy(zip, p, true), selftest,
                    (d, f) => UpdateEngine.InstallBinaries(d, f, home, CancellationToken.None), CancellationToken.None, downgrade);
                if (ready == null) throw new InvalidDataException("Бандл отклонён");
            } else {
                // Even a launcher-only release must check the installed modules before switching images.
                if (!selftest(engine.Folder(old))) throw new InvalidDataException("Самопроверка бандла не прошла");
            }
            bool hadExe = File.Exists(target);
            if (hadExe) File.Copy(target, backup, true);
            try {
                ReplaceImage(sourceExe, target);
                // Write before current.txt: recovery can also restore the image after interrupted activation.
                if (old.Length != 0 && hadExe) Json.Write(Path.Combine(engine.Root, "exe-upgrade.json"), new {
                    version, previous = old, launcherVersion, startedUtc = DateTime.UtcNow.ToString("o"), previousHash = Files.Hash(backup)
                });
                if (version != old) engine.Activate(version);
            } catch {
                if (hadExe) ReplaceImage(backup, target);
                else if (File.Exists(target)) File.Delete(target);
                if (File.Exists(Path.Combine(engine.Root, "exe-upgrade.json"))) File.Delete(Path.Combine(engine.Root, "exe-upgrade.json"));
                throw;
            }
        }
        public static void ReplaceImage(string source, string target)
        {
            string tmp = target + ".install.tmp", retired = target + ".retired";
            string home = Path.GetDirectoryName(target);
            if (Path.GetFileName(target).Equals("RemoteAgents.exe", StringComparison.OrdinalIgnoreCase) && LauncherRecovery.Accepted(home)) Files.Atomic(LauncherRecovery.Intent(home), "restart\n");
            File.Copy(source, tmp, true);
            using (var flush = new FileStream(tmp, FileMode.Open, FileAccess.Write, FileShare.Read)) flush.Flush(true);
            try {
                // Windows permits renaming an executing image; replacing it directly may be denied.
                if (File.Exists(retired)) File.Delete(retired);
                if (File.Exists(target)) {
                    // Atomic when the image is not executing. A running image may require rename.
                    try { File.Replace(tmp, target, retired); return; }
                    catch (IOException) { }
                    catch (UnauthorizedAccessException) { }
                    File.Move(target, retired);
                }
                try { File.Move(tmp, target); }
                catch { if (File.Exists(retired)) File.Move(retired, target); throw; }
            } finally { if (File.Exists(tmp)) File.Delete(tmp); }
        }
        public static bool RecoverImage(string home, Func<string, bool> valid = null)
        {
            valid = valid ?? (path => { try { AssemblyName.GetAssemblyName(path); return true; } catch { return false; } });
            string target = Path.Combine(home, "RemoteAgents.exe");
            if (File.Exists(target) && valid(target)) return false;
            string source = new[] { target + ".retired", Path.Combine(home, "RemoteAgents.old.exe"), Path.Combine(home, "RemoteAgents.previous.exe"), target + ".install.tmp", target + ".new" }.FirstOrDefault(path => File.Exists(path) && valid(path));
            if (source == null) throw new IOException("Нет исправного образа для восстановления");
            string temp = target + ".recovery." + Guid.NewGuid().ToString("N") + ".tmp";
            try {
                File.Copy(source, temp);
                using (var flush = new FileStream(temp, FileMode.Open, FileAccess.Write, FileShare.Read)) flush.Flush(true);
                if (File.Exists(target)) File.Replace(temp, target, null); else File.Move(temp, target);
            } finally { if (File.Exists(temp)) File.Delete(temp); }
            return true;
        }
        public static string ObserveImage(string home, UpdateEngine engine, bool healthy, string bundleResult, DateTime? utcNow = null)
        {
            string record = Path.Combine(engine.Root, "exe-upgrade.json"); if (!File.Exists(record)) return "";
            var p = Json.Read(record); DateTime start;
            if (!DateTime.TryParse(Json.Str(p, "startedUtc"), null, System.Globalization.DateTimeStyles.RoundtripKind, out start)) throw new InvalidDataException();
            bool expired = ((utcNow ?? DateTime.UtcNow) - start.ToUniversalTime()).TotalSeconds >= 120;
            if (bundleResult == "rollback" || expired || engine.Current != Json.Str(p, "version")) {
                string backup = Path.Combine(home, "RemoteAgents.previous.exe");
                if (!File.Exists(backup) || !Files.Hash(backup).Equals(Json.Str(p, "previousHash"), StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Нет прежнего EXE");
                if (engine.Pending) engine.Rollback();
                ReplaceImage(backup, Path.Combine(home, "RemoteAgents.exe")); File.Delete(record); return "rollback";
            }
            if (healthy && !engine.Pending) { File.Delete(record); return "accepted"; }
            return "";
        }
    }
}
