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
                // Write ahead: every step below is idempotent after process/power loss. No H2 receipt is made.
                Json.Write(ManualRollbackPath(home), p);
                CompletePreviousRollback(home, engine, p);
                return version;
            }
        }
        internal static void RecoverPreviousRollback(string home)
        {
            if (!File.Exists(ManualRollbackPath(home))) return;
            using (LockReceipt(home, default(CancellationToken), ReceiptWorkerFuseMs)) {
                if (!File.Exists(ManualRollbackPath(home))) return;
                CompletePreviousRollback(home, new UpdateEngine(home, "0.0.0"), UpdateObservation.ReadReceipt(ManualRollbackPath(home)));
            }
        }
        static void CompletePreviousRollback(string home, UpdateEngine engine, Dictionary<string, object> p)
        {
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
            if (!File.Exists(PreviousImage(home)) || !Files.Hash(PreviousImage(home)).Equals(hash, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Образ ручного отката отсутствует или SHA256 не совпадает");
            if (File.Exists(PreviousPath(home)) && Files.Hash(PreviousPath(home)) != descriptorHash)
                throw new InvalidDataException("Описание предыдущей версии изменилось");
            string target = Path.Combine(home, Product.ExeName);
            // ReplaceImage's Windows rename fallback can be interrupted with only .retired present.
            string actual = File.Exists(target) ? Files.Hash(target) : Files.Hash(target + ".retired");
            if (!actual.Equals(fromHash, StringComparison.OrdinalIgnoreCase) && !actual.Equals(hash, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Установленный EXE изменился во время отката");
            if (!File.Exists(target) || !actual.Equals(hash, StringComparison.OrdinalIgnoreCase)) ReplaceImage(PreviousImage(home), target);
            Files.Atomic(Path.Combine(engine.Root, "current.txt"), version + "\n");
            Files.Atomic(Path.Combine(engine.Root, "previous.txt"), "");
            if (Json.Bool(p, "blockCurrent")) engine.MarkBad(from);
            string statePath = Path.Combine(engine.Root, "update-state.json");
            var state = File.Exists(statePath) ? Json.Read(statePath) : Json.Map(null);
            state["pending"] = false; state.Remove("queuedFailure"); state.Remove("failureReason"); state.Remove("target");
            state["summary"] = "Возвращена предыдущая версия " + version; Json.Write(statePath, state);
            // Consume the descriptor: a second click/restart cannot bounce between images.
            if (File.Exists(PreviousPath(home))) File.Delete(PreviousPath(home));
            engine.Cleanup();
            File.Delete(ManualRollbackPath(home));
            new Journal(home).Write("update.rollback.manual version=" + version + " blocked=" + Json.Bool(p, "blockCurrent"));
        }
    }
}
