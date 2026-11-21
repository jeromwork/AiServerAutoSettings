using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

namespace RemoteAgents.Launcher
{
    // Shared by the downloaded-EXE installer and the upgrade selftest. Never replaces user directories.
    internal static class UpgradeInstaller
    {
        // Один замок на home для установщика, трея и внешнего наблюдателя; Mutex рекурсивен.
        internal static string ReceiptMutexName(string home)
        {
            string canonical = Path.GetFullPath(home).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar).ToUpperInvariant();
            using (var sha = SHA256.Create())
                return "Global\\RemoteAgents.UpdateReceipt." + BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(canonical))).Replace("-", "");
        }
        internal const int ReceiptUiWaitMs = 25;
        const int ReceiptWorkerWaitMs = 1000;
        internal sealed class ReceiptBusyException : IOException
        { internal ReceiptBusyException() : base("Квитанция обновления занята; повторите действие позже") { } }
        sealed class ReceiptLease : IDisposable
        {
            readonly Mutex mutex;
            internal ReceiptLease(string home, CancellationToken token, int timeoutMs)
            {
                if (timeoutMs < 0) throw new ArgumentOutOfRangeException("timeoutMs");
                token.ThrowIfCancellationRequested();
                mutex = new Mutex(false, ReceiptMutexName(home));
                bool owned = false;
                try {
                    try {
                        var deadline = Stopwatch.StartNew();
                        do {
                            token.ThrowIfCancellationRequested();
                            int remaining = Math.Max(0, timeoutMs - (int)deadline.ElapsedMilliseconds);
                            // timer-ok: C — живой владелец может не отдать mutex; только
                            // отказ по дедлайну/отмене, никогда запись без владения.
                            owned = mutex.WaitOne(token.CanBeCanceled ? Math.Min(25, remaining) : remaining);
                        } while (!owned && deadline.ElapsedMilliseconds < timeoutMs);
                    } catch (AbandonedMutexException) { owned = true; }
                    token.ThrowIfCancellationRequested();
                    if (!owned) throw new ReceiptBusyException();
                } catch {
                    if (owned) mutex.ReleaseMutex();
                    mutex.Dispose(); throw;
                }
            }
            public void Dispose() { mutex.ReleaseMutex(); mutex.Dispose(); }
        }
        // UI и синхронные записи имеют короткий предел; подготовка может ждать с отменой.
        // При таймауте тело using не выполняется: писать без владения запрещено.
        internal static IDisposable LockReceipt(string home, CancellationToken token = default(CancellationToken), int timeoutMs = ReceiptUiWaitMs)
        { return new ReceiptLease(home, token, timeoutMs); }
        internal static string ReceiptPath(string home) { return Path.Combine(home, Product.BundleDirectory, "exe-upgrade.json"); }
        internal static string RecoveryBlockPath(string home) { return Path.Combine(home, "state", "exe-upgrade-recovery-blocked"); }
        internal static bool ReceiptRecoveryBlocked(string home) { return File.Exists(RecoveryBlockPath(home)); }
        internal static bool HasObservableReceipt(string home) { return !ReceiptRecoveryBlocked(home) && File.Exists(ReceiptPath(home)); }
        internal static void RequireReceiptRecovery(string home)
        {
            if (ReceiptRecoveryBlocked(home)) throw new InvalidDataException("Восстановление повреждённой квитанции остановлено. Устраните отказ доступа к bundle/exe-upgrade.json и его .invalid, затем удалите state/exe-upgrade-recovery-blocked для ручного повтора.");
        }
        // Писатели не чинят повреждение самостоятельно: старый EXE обработает его до запуска доски.
        static Dictionary<string, object> ReadForWriter(string home, string path)
        {
            if (ReceiptRecoveryBlocked(home)) return null;
            try { return UpdateObservation.ReadReceipt(path); }
            catch (UpdateObservation.InvalidReceiptException) { new Journal(home).Write("update.receipt.invalid"); return null; }
        }
        // Завершение наблюдателя и регистрация следующей пары должны иметь общий порядок.
        internal static bool TryFinishObservation(string home, Action releaseObserver)
        {
            using (LockReceipt(home)) {
                string path = ReceiptPath(home);
                if (HasObservableReceipt(home)) {
                    Dictionary<string, object> record;
                    try { record = UpdateObservation.TryRead(() => UpdateObservation.ReadReceipt(path)); }
                    catch (UpdateObservation.InvalidReceiptException) { return false; }
                    if (record == null || (!Json.Bool(record, "healthAccepted") &&
                        (!Json.Bool(record, "cleanExit") || Json.Int(record, "cleanExitCount", 0) >= UpdateObservation.CleanExitLimit))) return false;
                }
                releaseObserver(); return true;
            }
        }
        internal static void RollbackObservedImage(string home, UpdateEngine engine, string reason)
        {
            using (LockReceipt(home)) {
                string receipt = ReceiptPath(home);
                if (!HasObservableReceipt(home)) return;
                Dictionary<string, object> record;
                try {
                    record = UpdateObservation.ReadReceipt(receipt);
                    DateTime progress;
                    if (reason == "invalid-receipt" && !DateTime.TryParse(Json.Text(record, "lastHealthUtc", Json.Str(record, "startedUtc")), null,
                        System.Globalization.DateTimeStyles.RoundtripKind, out progress))
                        throw new UpdateObservation.InvalidReceiptException("Receipt progress is invalid");
                }
                catch (UpdateObservation.InvalidReceiptException) {
                    // Без previousHash нельзя доверять резервному EXE. Сохраняем одну улику,
                    // снимаем блокирующую квитанцию, откатываем бандл по его отдельной транзакции.
                    // Write-ahead запрет: даже отказ Copy/Delete и следующий запуск не
                    // повторят остановку EXE. Снять его можно лишь после успешной уборки.
                    Files.Atomic(RecoveryBlockPath(home), "invalid-receipt\n");
                    try {
                        File.Copy(receipt, receipt + ".invalid", true); File.Delete(receipt);
                        File.Delete(RecoveryBlockPath(home));
                    } finally { if (engine.Pending) engine.Rollback(); }
                    throw new UpdateObservation.InvalidReceiptException("EXE rollback unavailable: receipt is invalid");
                }
                if (Json.Bool(record, "healthAccepted")) return;
                string version = Json.Str(record, "version");
                ObserveImage(home, engine, false, "rollback");
                string path = Path.Combine(engine.Root, "update-state.json");
                var state = File.Exists(path) ? Json.Read(path) : Json.Map(null);
                state["queuedFailure"] = version; state["pending"] = false; state["failureReason"] = reason; Json.Write(path, state);
            }
        }
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
            token.ThrowIfCancellationRequested();
            RequireReceiptRecovery(home);
            var engine = new UpdateEngine(home, launcherVersion);
            string version = BundleVersion(zip), sourceHash = Files.Hash(sourceExe), old;
            using (LockReceipt(home, token, ReceiptWorkerWaitMs)) {
                engine.Recover();
                if (engine.Pending || File.Exists(ReceiptPath(home))) throw new InvalidOperationException("Предыдущее обновление ещё проверяется");
                if (!downgrade && !accept && IsRejectedImage(home, sourceHash)) throw new InvalidDataException("Этот EXE ранее отклонён");
                old = engine.Current;
            }
            // Распаковка, загрузка бинарников и selftest не держат замок квитанции.
            if (version != old) {
                var manifest = Manifest.Parse(Json.Encode(new { version, file = "embedded.zip", sha256 = Files.Hash(zip), size = new FileInfo(zip).Length, minLauncher = launcherVersion }));
                string ready = engine.Prepare(manifest, p => File.Copy(zip, p, true), selftest,
                    (d, f) => UpdateEngine.InstallBinaries(d, f, home, token), token, downgrade || accept || old.Length == 0);
                if (ready == null) throw new InvalidDataException("Бандл отклонён");
            } else if (!selftest(engine.Folder(old))) throw new InvalidDataException("Самопроверка бандла не прошла");
            token.ThrowIfCancellationRequested();
            using (LockReceipt(home, token, ReceiptWorkerWaitMs)) {
                RequireReceiptRecovery(home);
                // Состояние могло измениться, пока готовился бандл; чужую активацию не заменяем.
                if (engine.Current != old || engine.Pending || File.Exists(ReceiptPath(home)))
                    throw new InvalidOperationException("Состояние обновления изменилось; повторите установку");
                string target = Path.Combine(home, Product.ExeName), backup = Path.Combine(home, Product.Name + ".previous.exe");
                token.ThrowIfCancellationRequested();
                bool hadExe = File.Exists(target);
                if (hadExe) File.Copy(target, backup, true);
                try {
                    ReplaceImage(sourceExe, target);
                    // Write before current.txt: recovery can also restore the image after interrupted activation.
                    if (old.Length != 0 && hadExe && !accept) Json.Write(Path.Combine(engine.Root, "exe-upgrade.json"), new {
                        version, previous = old, launcherVersion, startedUtc = DateTime.UtcNow.ToString("o"), previousHash = Files.Hash(backup), currentHash = sourceHash
                    });
                    if (version != old) engine.Activate(version, accept);
                } catch {
                    if (hadExe) ReplaceImage(backup, target);
                    else if (File.Exists(target)) File.Delete(target);
                    if (File.Exists(Path.Combine(engine.Root, "exe-upgrade.json"))) File.Delete(Path.Combine(engine.Root, "exe-upgrade.json"));
                    throw;
                }
            }
        }
        // OTA uses the already verified bundle and the same image receipt / rollback as manual upgrades.
        public static void ActivatePrepared(string home, UpdateEngine engine, Manifest manifest)
        {
            using (LockReceipt(home)) {
                RequireReceiptRecovery(home);
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
        }
        public static void NoteImageProcess(string home)
        {
            RequireReceiptRecovery(home);
            if (!File.Exists(Path.Combine(home, Product.BundleDirectory, "exe-upgrade.json"))) return;
            using (var process = Process.GetCurrentProcess())
                NoteImageProcess(home, process.Id, process.StartTime.ToUniversalTime().Ticks.ToString(System.Globalization.CultureInfo.InvariantCulture), DateTime.UtcNow, Files.Hash(ProgramImage()));
        }
        internal static void NoteImageProcess(string home, int pid, string processStarted, DateTime utc, string imageHash)
        {
            using (LockReceipt(home)) {
                string root = Path.Combine(home, Product.BundleDirectory), receipt = Path.Combine(root, "exe-upgrade.json");
                if (!File.Exists(receipt)) return;
                var record = ReadForWriter(home, receipt); if (record == null) return;
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
            RequireReceiptRecovery(home);
            using (LockReceipt(home)) {
                string receipt = Path.Combine(home, Product.BundleDirectory, "exe-upgrade.json");
                if (!File.Exists(receipt)) return;
                var record = ReadForWriter(home, receipt); if (record == null) return;
                // Наблюдатель стартует раньше EXE: не оставляем ему старый PID/отсчёт даже после обрыва.
                record.Remove("cleanExit"); record.Remove("pid"); record.Remove("processStarted"); record.Remove("lastHealthUtc");
                record["startedUtc"] = utc.ToString("o"); Json.Write(receipt, record);
            }
        }
        internal static void NoteHealthProgress(string home, DateTime utc)
        {
            using (LockReceipt(home)) {
                string receipt = Path.Combine(home, Product.BundleDirectory, "exe-upgrade.json");
                if (!File.Exists(receipt)) return;
                var record = ReadForWriter(home, receipt); if (record == null) return;
                record["lastHealthUtc"] = utc.ToString("o"); Json.Write(receipt, record);
            }
        }
        internal static bool ImageHealthAccepted(string home)
        {
            using (LockReceipt(home)) {
                string receipt = Path.Combine(home, Product.BundleDirectory, "exe-upgrade.json");
                return File.Exists(receipt) && Json.Bool(ReadForWriter(home, receipt), "healthAccepted");
            }
        }
        internal static void NoteHealthAccepted(string home)
        {
            using (LockReceipt(home)) {
                string receipt = Path.Combine(home, Product.BundleDirectory, "exe-upgrade.json");
                if (!File.Exists(receipt)) return;
                var record = ReadForWriter(home, receipt); if (record == null || Json.Bool(record, "healthAccepted")) return;
                record["healthAccepted"] = true; Json.Write(receipt, record);
            }
        }
        internal static void NoteCurrentImageCleanExit(string home)
        {
            using (var process = Process.GetCurrentProcess())
                NoteCleanExit(home, process.Id, process.StartTime.ToUniversalTime().Ticks.ToString(System.Globalization.CultureInfo.InvariantCulture));
        }
        internal static int NoteCleanExit(string home, int pid, string processStarted)
        {
            if (!HasObservableReceipt(home)) return 0;
            using (LockReceipt(home)) {
                string receipt = Path.Combine(home, Product.BundleDirectory, "exe-upgrade.json");
                if (!File.Exists(receipt)) return 0;
                var record = ReadForWriter(home, receipt); if (record == null) return -1;
                // Хэндл мог завершиться одновременно с регистрацией уже следующего процесса.
                if (pid <= 0 || string.IsNullOrEmpty(processStarted) || !UpdateObservation.SameProcess(record, pid, processStarted)) return -1;
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
            using (LockReceipt(home)) {
                string record = Path.Combine(engine.Root, "exe-upgrade.json"); if (!HasObservableReceipt(home)) return "";
                var p = UpdateObservation.ReadReceipt(record);
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
