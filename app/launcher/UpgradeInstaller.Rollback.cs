using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;

namespace RemoteAgents.Launcher
{
    internal static partial class UpgradeInstaller
    {
        internal static string PreviousPath(string home) { return Path.Combine(home, "state", "previous.json"); }
        internal static string ManualRollbackPath(string home) { return Path.Combine(home, "state", "rollback-previous.json"); }
        static string PreviousImage(string home) { return Path.Combine(home, Product.Name + ".previous.exe"); }

        // Caller owns receipt-mutex. The existing current/previous EXEs and bundle Cleanup own retention.
        internal static void SavePrevious(string home, UpdateEngine engine, string version, string image)
        {
            Files.SafeVersion(version);
            Json.Write(PreviousPath(home), new { ver = version, exeSha256 = Files.Hash(image),
                bundleDir = engine.Folder(version), helperBuild = NetHelperInstall.HelperVersion });
        }
        internal static void SaveBundlePrevious(string home, UpdateEngine engine, string version)
        {
            // EXE installers already saved the paired image; bundle-only activation keeps the same EXE.
            if (version.Length == 0 || File.Exists(ReceiptPath(home))) return;
            string target = Path.Combine(home, Product.ExeName);
            if (!File.Exists(target)) return;
            File.Copy(target, PreviousImage(home), true);
            SavePrevious(home, engine, version, PreviousImage(home));
        }
        internal static void DiscardPrevious(string home)
        {
            // An H2 rollback consumes this image. A stale menu record must never block H2 recovery.
            try { if (File.Exists(PreviousPath(home))) File.Delete(PreviousPath(home)); }
            catch (Exception ex) { try { new Journal(home).Write("update.previous.discard.failed kind=" + ex.GetType().Name); } catch { } }
        }
        static Dictionary<string, object> ReadPrevious(string home, UpdateEngine engine)
        {
            if (!File.Exists(PreviousPath(home))) throw new InvalidOperationException("Нет сохранённой предыдущей версии");
            Dictionary<string, object> p;
            try { p = UpdateObservation.ReadReceipt(PreviousPath(home)); }
            catch (UpdateObservation.InvalidReceiptException ex) { throw new InvalidDataException("Повреждён файл предыдущей версии", ex); }
            string version = Files.SafeVersion(Json.Str(p, "ver")), hash = Json.Str(p, "exeSha256");
            Files.HashValid(hash);
            string folder = Json.Str(p, "bundleDir");
            if (folder.Length == 0 || !Path.GetFullPath(folder).Equals(Path.GetFullPath(engine.Folder(version)), StringComparison.OrdinalIgnoreCase) ||
                Json.Str(p, "helperBuild").Length == 0) throw new InvalidDataException("Неверные данные предыдущей версии");
            if (!Directory.Exists(folder)) throw new InvalidOperationException("Образ предыдущего бандла отсутствует: " + version);
            BundleDefinition.Load(folder);
            if (!File.Exists(PreviousImage(home))) throw new InvalidOperationException("Образ предыдущего EXE отсутствует");
            if (!Files.Hash(PreviousImage(home)).Equals(hash, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("SHA256 предыдущего EXE не совпадает; откат отменён");
            return p;
        }
        static void RequireManualIdle(string home, UpdateEngine engine)
        {
            // A manual request never repairs/consumes someone else's pending receipt.
            if (ReceiptRecoveryBlocked(home) || File.Exists(ReceiptPath(home)) || engine.Pending || File.Exists(ManualRollbackPath(home)))
                throw new InvalidOperationException("Идёт другое обновление или восстановление квитанции; откат недоступен");
        }
        internal static string PreviousVersion(string home, UpdateEngine engine)
        {
            using (LockReceipt(home, default(CancellationToken), ReceiptWorkerFuseMs)) {
                RequireManualIdle(home, engine);
                var p = ReadPrevious(home, engine);
                string version = Json.Str(p, "ver");
                if (engine.Previous != version && engine.Current != version) throw new InvalidOperationException("Предыдущая версия больше не соответствует установленной");
                string target = Path.Combine(home, Product.ExeName);
                if (!File.Exists(target)) throw new InvalidOperationException("Установленный EXE отсутствует");
                if (version == engine.Current && Files.Hash(target).Equals(Json.Str(p, "exeSha256"), StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("Предыдущая версия уже установлена");
                return version;
            }
        }
        // Called on a worker (or the CLI startup thread), never on the tray UI thread.
        internal static string RollbackPrevious(string home, UpdateEngine engine, bool blockCurrent, string expectedVersion = null, string installerMutexName = null)
        {
            // Same nonblocking gate as downloaded installers. Preparation may run outside receipt-mutex.
            if (installerMutexName != null) using (var installer = new Mutex(false, installerMutexName)) {
                bool owned; try { owned = installer.WaitOne(0); } catch (AbandonedMutexException) { owned = true; }
                if (!owned) throw new InvalidOperationException("Идёт другая установка; откат недоступен");
                try { return RollbackPrevious(home, engine, blockCurrent, expectedVersion); }
                finally { installer.ReleaseMutex(); }
            }
            using (LockReceipt(home, default(CancellationToken), ReceiptWorkerFuseMs)) {
                string version = PreviousVersion(home, engine);
                if (expectedVersion != null && version != expectedVersion) throw new InvalidOperationException("Предыдущая версия изменилась; повторите подтверждение");
                var p = ReadPrevious(home, engine);
                p["fromVersion"] = engine.Current; p["fromHash"] = Files.Hash(Path.Combine(home, Product.ExeName));
                p["previousVersion"] = engine.Previous; p["blockCurrent"] = blockCurrent;
                p["descriptorHash"] = Files.Hash(PreviousPath(home));
                // Prove atomic replacement of this target before ANY durable state changes.
                using (var image = Json.Str(p, "fromHash").Equals(Json.Str(p, "exeSha256"), StringComparison.OrdinalIgnoreCase) ? null :
                    new PreviousReplacement(PreviousImage(home), Path.Combine(home, Product.ExeName), Json.Str(p, "exeSha256"))) {
                    Json.Write(ManualRollbackPath(home), p);
                    PreviousRollbackBoundary("journal");
                    CompletePreviousRollback(home, engine, p, image, starting: true);
                }
                return version;
            }
        }
        internal static bool RecoverPreviousRollback(string home)
        {
            if (!File.Exists(ManualRollbackPath(home))) return false;
            using (LockReceipt(home, default(CancellationToken), ReceiptWorkerFuseMs)) {
                if (!File.Exists(ManualRollbackPath(home))) return false;
                try {
                    return CompletePreviousRollback(home, new UpdateEngine(home, "0.0.0"), UpdateObservation.ReadReceipt(ManualRollbackPath(home)));
                } catch (Exception ex) {
                    new Journal(home).Write("update.rollback.manual.journal.failed kind=" + ex.GetType().Name);
                    throw;
                }
            }
        }
#if PORTABLE_TEST && !UPDATE_HEALTH_TESTS
        [ThreadStatic] internal static Action<string> PreviousRollbackCheckpoint;
#endif
        static void PreviousRollbackBoundary(string step)
        {
#if PORTABLE_TEST && !UPDATE_HEALTH_TESTS
            if (PreviousRollbackCheckpoint != null) PreviousRollbackCheckpoint(step);
#endif
        }
        // Separate from H2's ReplaceImage: never rename away the installed executable.
        sealed class PreviousReplacement : IDisposable
        {
            readonly string target, temp;
            internal PreviousReplacement(string source, string target, string expectedHash)
            {
                this.target = target; temp = target + ".rollback.tmp";
                string check = target + ".rollback-check.tmp", backup = target + ".rollback-probe.bak";
                try {
                    File.Copy(source, temp, true); FlushImage(temp);
                    if (!Files.Hash(temp).Equals(expectedHash, StringComparison.OrdinalIgnoreCase))
                        throw new InvalidDataException("SHA256 подготовленного EXE ручного отката не совпадает");
                    // A byte-identical atomic swap tests target ACLs, image locks and filesystem support.
                    // A failure leaves the original target and ALL state files untouched; no rename fallback.
                    File.Copy(target, check, true); FlushImage(check);
                    ReplaceAtomic(check, target, backup);
                    File.Delete(backup);
                    PreviousRollbackBoundary("preflight");
                } catch {
                    Dispose(); throw;
                } finally { if (File.Exists(check)) File.Delete(check); }
            }
            static void FlushImage(string path)
            { using (var f = new FileStream(path, FileMode.Open, FileAccess.Write, FileShare.Read)) f.Flush(true); }
            internal void Commit() { ReplaceAtomic(temp, target, null); }
            static void ReplaceAtomic(string source, string target, string backup)
            {
                try { File.Replace(source, target, backup); }
                catch (Exception ex) {
                    if (!(ex is IOException) && !(ex is UnauthorizedAccessException) && !(ex is PlatformNotSupportedException)) throw;
                    throw new IOException("Атомарная замена EXE недоступна; состояние сохранено. Устраните отказ доступа и повторите запуск.", ex);
                }
            }
            public void Dispose() { if (File.Exists(temp)) File.Delete(temp); }
        }
        // Only the initiating call may advance Current from the source version. After a restart,
        // Current must already be the target AND the EXE must still belong to this transaction.
        // A pre-Current interruption is cancelled; a later pre-H4 update owns its own H2 state.
        static bool CompletePreviousRollback(string home, UpdateEngine engine, Dictionary<string, object> p, PreviousReplacement prepared = null, bool starting = false)
        {
            string target = Path.Combine(home, Product.ExeName);
            // A different Current alone proves staleness; do not require access to its EXE.
            bool targetCurrent = engine.Current == Json.Str(p, "ver");
            string actual = (starting || targetCurrent) && File.Exists(target) ? Files.Hash(target) : "";
            if (!starting && (!targetCurrent || actual.Length == 0 ||
                (!actual.Equals(Json.Str(p, "fromHash"), StringComparison.OrdinalIgnoreCase) &&
                 !actual.Equals(Json.Str(p, "exeSha256"), StringComparison.OrdinalIgnoreCase)))) {
                // Caller owns receipt-mutex. Do not inspect or consume another transaction's
                // receipt/pending, previous descriptor or backup before retiring stale evidence.
                File.Delete(ManualRollbackPath(home));
                new Journal(home).Write("update.rollback.manual.journal.stale");
                return false;
            }
            if (ReceiptRecoveryBlocked(home) || File.Exists(ReceiptPath(home)) || engine.Pending)
                throw new InvalidOperationException("Ручной откат заблокирован другой квитанцией обновления");
            string version = Files.SafeVersion(Json.Str(p, "ver")), from = Files.SafeVersion(Json.Str(p, "fromVersion"));
            string hash = Json.Str(p, "exeSha256"), fromHash = Json.Str(p, "fromHash"), descriptorHash = Json.Str(p, "descriptorHash");
            Files.HashValid(hash); Files.HashValid(fromHash); Files.HashValid(descriptorHash);
            string previous = Json.Str(p, "previousVersion"); if (previous.Length > 0) Files.SafeVersion(previous);
            if ((engine.Current != from && engine.Current != version) || (engine.Previous != previous && engine.Previous.Length != 0))
                throw new InvalidDataException("Состояние ручного отката изменилось");
            if (!Path.GetFullPath(Json.Str(p, "bundleDir")).Equals(Path.GetFullPath(engine.Folder(version)), StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Путь ручного отката изменился");
            BundleDefinition.Load(engine.Folder(version));
            if (File.Exists(PreviousPath(home)) && Files.Hash(PreviousPath(home)) != descriptorHash)
                throw new InvalidDataException("Описание предыдущей версии изменилось");
            if (!File.Exists(target)) throw new InvalidDataException("Установленный EXE ручного отката отсутствует");
            bool installed = actual.Equals(hash, StringComparison.OrdinalIgnoreCase);
            if (!actual.Equals(fromHash, StringComparison.OrdinalIgnoreCase) && !installed)
                throw new InvalidDataException("Установленный EXE изменился во время отката");
            if (!installed && (!File.Exists(PreviousImage(home)) || !Files.Hash(PreviousImage(home)).Equals(hash, StringComparison.OrdinalIgnoreCase)))
                throw new InvalidDataException("Образ ручного отката отсутствует или SHA256 не совпадает");
            // On recovery, preflight before resuming state writes. A final-swap failure keeps the
            // journal and coherent target-version state for the next startup/Apply/OTA attempt.
            using (var image = prepared ?? (installed ? null : new PreviousReplacement(PreviousImage(home), target, hash))) {
                Files.Atomic(Path.Combine(engine.Root, "current.txt"), version + "\n");
                PreviousRollbackBoundary("current");
                Files.Atomic(Path.Combine(engine.Root, "previous.txt"), "");
                PreviousRollbackBoundary("previous");
                if (Json.Bool(p, "blockCurrent")) engine.MarkBad(from);
                PreviousRollbackBoundary("bad");
                string statePath = Path.Combine(engine.Root, "update-state.json");
                var state = File.Exists(statePath) ? Json.Read(statePath) : Json.Map(null);
                state["pending"] = false; state.Remove("queuedFailure"); state.Remove("failureReason"); state.Remove("target");
                state["summary"] = "Возвращена предыдущая версия " + version; Json.Write(statePath, state);
                PreviousRollbackBoundary("update-state");
                if (File.Exists(PreviousPath(home))) File.Delete(PreviousPath(home));
                PreviousRollbackBoundary("descriptor");
                engine.Cleanup();
                PreviousRollbackBoundary("bundle");
                new Journal(home).Write("update.rollback.manual.prepared version=" + version + " blocked=" + Json.Bool(p, "blockCurrent"));
                PreviousRollbackBoundary("before-exe");
                // LAST mutation except journal removal. The previous EXE may predate H4 entirely.
                if (!installed) image.Commit();
                PreviousRollbackBoundary("exe");
                PreviousRollbackBoundary("before-journal-delete");
                File.Delete(ManualRollbackPath(home));
            }
            return true;
        }
    }
}
