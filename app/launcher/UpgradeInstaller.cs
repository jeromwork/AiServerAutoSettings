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
        static readonly object ReceiptGate = new object();
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
        public static void Apply(string home, string sourceExe, string zip, string launcherVersion, bool downgrade, Func<string, bool> selftest, CancellationToken token = default(CancellationToken), bool accept = false)
        {
            var engine = new UpdateEngine(home, launcherVersion); engine.Recover();
            if (engine.Pending) throw new InvalidOperationException("Предыдущее обновление ещё проверяется");
            string version = BundleVersion(zip), old = engine.Current;
            if (!downgrade && !accept && IsRejectedImage(home, Files.Hash(sourceExe))) throw new InvalidDataException("Этот EXE ранее отклонён");
            string target = Path.Combine(home, Product.ExeName), backup = Path.Combine(home, Product.Name + ".previous.exe");
            if (File.Exists(Path.Combine(engine.Root, "exe-upgrade.json"))) throw new InvalidOperationException("Лаунчер ещё проверяется");
            if (version != old) {
                var manifest = Manifest.Parse(Json.Encode(new { version, file = "embedded.zip", sha256 = Files.Hash(zip), size = new FileInfo(zip).Length, minLauncher = launcherVersion }));
                string ready = engine.Prepare(manifest, p => File.Copy(zip, p, true), selftest,
                    (d, f) => UpdateEngine.InstallBinaries(d, f, home, token), token, downgrade || accept || old.Length==0);
                if (ready == null) throw new InvalidDataException("Бандл отклонён");
            } else {
                // Even a launcher-only release must check the installed modules before switching images.
                if (!selftest(engine.Folder(old))) throw new InvalidDataException("Самопроверка бандла не прошла");
            }
            token.ThrowIfCancellationRequested();
            bool hadExe = File.Exists(target);
            if (hadExe) File.Copy(target, backup, true);
            try {
                ReplaceImage(sourceExe, target);
                // Write before current.txt: recovery can also restore the image after interrupted activation.
                if (old.Length != 0 && hadExe && !accept) Json.Write(Path.Combine(engine.Root, "exe-upgrade.json"), new {
                    version, previous = old, launcherVersion, startedUtc = DateTime.UtcNow.ToString("o"), previousHash = Files.Hash(backup), currentHash = Files.Hash(sourceExe)
                });
                if (version != old) engine.Activate(version, accept);
            } catch {
                if (hadExe) ReplaceImage(backup, target);
                else if (File.Exists(target)) File.Delete(target);
                if (File.Exists(Path.Combine(engine.Root, "exe-upgrade.json"))) File.Delete(Path.Combine(engine.Root, "exe-upgrade.json"));
                throw;
            }
        }
        // OTA uses the already verified bundle and the same image receipt / rollback as manual upgrades.
        public static void ActivatePrepared(string home, UpdateEngine engine, Manifest manifest)
        {
            string target = Path.Combine(home, Product.ExeName), backup = Path.Combine(home, Product.Name + ".previous.exe");
            string source = Path.Combine(engine.Folder(manifest.Version), Product.ExeName);
            if (engine.Pending || File.Exists(Path.Combine(engine.Root, "exe-upgrade.json"))) throw new InvalidOperationException("Обновление ещё проверяется");
            if (!File.Exists(target) || !Files.Hash(source).Equals(manifest.LauncherHash, StringComparison.OrdinalIgnoreCase) ||
                Files.Compare(FileVersionInfo.GetVersionInfo(source).FileVersion, manifest.LauncherVersion) != 0) throw new InvalidDataException("Проверка EXE не прошла");
            File.Copy(target, backup, true);
            Json.Write(Path.Combine(engine.Root, "exe-upgrade.json"), new { version = manifest.Version, previous = engine.Current,
                launcherVersion = manifest.LauncherVersion, startedUtc = DateTime.UtcNow.ToString("o"), previousHash = Files.Hash(backup), currentHash = Files.Hash(source) });
            try { ReplaceImage(source, target); engine.Activate(manifest.Version); }
            catch {
                if (engine.Pending && engine.Current == manifest.Version) engine.Rollback(); else engine.Recover();
                ReplaceImage(backup, target); File.Delete(Path.Combine(engine.Root, "exe-upgrade.json")); throw;
            }
        }
        public static void NoteImageProcess(string home)
        {
            if (!File.Exists(Path.Combine(home, Product.BundleDirectory, "exe-upgrade.json"))) return;
            using (var process = Process.GetCurrentProcess())
                NoteImageProcess(home, process.Id, process.StartTime.ToUniversalTime().Ticks.ToString(System.Globalization.CultureInfo.InvariantCulture), DateTime.UtcNow, Files.Hash(ProgramImage()));
        }
        internal static void NoteImageProcess(string home, int pid, string processStarted, DateTime utc, string imageHash)
        {
            lock (ReceiptGate) {
                string root = Path.Combine(home, Product.BundleDirectory), receipt = Path.Combine(root, "exe-upgrade.json");
                if (!File.Exists(receipt)) return;
                var record = Json.Read(receipt);
                if (!imageHash.Equals(Json.Str(record, "currentHash"), StringComparison.OrdinalIgnoreCase)) return;
                // Любая новая сессия, в том числе после питания/BSOD, получает свой отсчёт.
                if (!UpdateObservation.SameProcess(record, pid, processStarted)) {
                    record["startedUtc"] = utc.ToString("o"); record.Remove("lastHealthUtc");
                    record.Remove("cleanExit");
                }
                record["pid"] = pid; record["processStarted"] = processStarted;
                Json.Write(receipt, record);
            }
        }
        internal static void PrepareImageLaunch(string home, DateTime utc)
        {
            lock (ReceiptGate) {
                string receipt = Path.Combine(home, Product.BundleDirectory, "exe-upgrade.json");
                if (!File.Exists(receipt)) return;
                var record = Json.Read(receipt);
                // Наблюдатель стартует раньше EXE: не оставляем ему старый PID/отсчёт даже после обрыва.
                record.Remove("cleanExit"); record.Remove("pid"); record.Remove("processStarted"); record.Remove("lastHealthUtc");
                record["startedUtc"] = utc.ToString("o"); Json.Write(receipt, record);
            }
        }
        internal static void NoteHealthProgress(string home, DateTime utc)
        {
            lock (ReceiptGate) {
                string receipt = Path.Combine(home, Product.BundleDirectory, "exe-upgrade.json");
                if (!File.Exists(receipt)) return;
                var record = Json.Read(receipt); record["lastHealthUtc"] = utc.ToString("o"); Json.Write(receipt, record);
            }
        }
        internal static bool ImageHealthAccepted(string home)
        {
            lock (ReceiptGate) {
                string receipt = Path.Combine(home, Product.BundleDirectory, "exe-upgrade.json");
                return File.Exists(receipt) && Json.Bool(Json.Read(receipt), "healthAccepted");
            }
        }
        internal static void NoteHealthAccepted(string home)
        {
            lock (ReceiptGate) {
                string receipt = Path.Combine(home, Product.BundleDirectory, "exe-upgrade.json");
                if (!File.Exists(receipt)) return;
                var record = Json.Read(receipt); if (Json.Bool(record, "healthAccepted")) return;
                record["healthAccepted"] = true; Json.Write(receipt, record);
            }
        }
        internal static int NoteCleanExit(string home, int pid = 0, string processStarted = null)
        {
            lock (ReceiptGate) {
                string receipt = Path.Combine(home, Product.BundleDirectory, "exe-upgrade.json");
                if (!File.Exists(receipt)) return 0;
                var record = Json.Read(receipt);
                // Хэндл мог завершиться одновременно с регистрацией уже следующего процесса.
                if (pid > 0 && !UpdateObservation.SameProcess(record, pid, processStarted)) return -1;
                int count = Math.Max(0, Math.Min(UpdateObservation.CleanExitLimit, Json.Int(record, "cleanExitCount", 0)));
                if (!Json.Bool(record, "healthAccepted") && !Json.Bool(record, "cleanExit"))
                    count = Math.Min(UpdateObservation.CleanExitLimit, count + 1);
                record["cleanExitCount"] = count; record["cleanExit"] = true; Json.Write(receipt, record);
                return count;
            }
        }
        internal static bool IsRejectedImage(string home, string hash)
        {
            string path = Path.Combine(home, Product.BundleDirectory, "rejected-image.json");
            return File.Exists(path) && Json.Str(Json.Read(path), "sha256").Equals(hash, StringComparison.OrdinalIgnoreCase);
        }
        static string ProgramImage() { return Assembly.GetExecutingAssembly().Location; }
        public static void ReplaceImage(string source, string target)
        {
            string tmp = target + ".install.tmp", retired = target + ".retired";
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
        public static string ObserveImage(string home, UpdateEngine engine, bool healthy, string bundleResult)
        {
            lock (ReceiptGate) {
                string record = Path.Combine(engine.Root, "exe-upgrade.json"); if (!File.Exists(record)) return "";
                var p = Json.Read(record);
                if (bundleResult == "rollback" || engine.Current != Json.Str(p, "version")) {
                    string backup = Path.Combine(home, Product.Name + ".previous.exe");
                    if (!File.Exists(backup) || !Files.Hash(backup).Equals(Json.Str(p, "previousHash"), StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Нет прежнего EXE");
                    if (engine.Pending || (engine.Current == Json.Str(p, "version") && engine.Current != Json.Str(p, "previous"))) engine.Rollback();
                    if (engine.Current != Json.Str(p, "version")) engine.MarkBad(Json.Str(p, "version"));
                    // При прежнем бандле нельзя заносить его в bad.txt: отвергнут только образ лаунчера.
                    // Одно последнее значение ограничивает размер хранилища (§4б).
                    if (Json.Str(p, "version") == Json.Str(p, "previous") && Json.Str(p, "currentHash").Length > 0)
                        Json.Write(Path.Combine(engine.Root, "rejected-image.json"), new { sha256 = Json.Str(p, "currentHash"), launcherVersion = Json.Str(p, "launcherVersion") });
                    ReplaceImage(backup, Path.Combine(home, Product.ExeName)); File.Delete(record); return "rollback";
                }
                if (healthy && !engine.Pending) { File.Delete(record); return "accepted"; }
                return "";
            }
        }
    }
}
