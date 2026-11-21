using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace RemoteAgents.Launcher
{
    internal sealed partial class TrayContext
    {
        readonly UpdateSchedule updateSchedule = new UpdateSchedule();
        bool updateChecking, checkRequested;
        Manifest offeredUpdate;
        string offeredVersion = "";
        string offeredSettings;

        string UpdateStatePath { get { return Path.Combine(engine.Root, "update-state.json"); } }
        Dictionary<string, object> UpdateState()
        { try { return Json.Read(UpdateStatePath); } catch { return Json.Map(null); } }
        void SaveUpdateState(string summary, string notice = null, bool pending = false)
        {
            var state = UpdateState(); state["summary"] = summary; state["pending"] = pending;
            if (pending && offeredVersion.Length > 0) state["target"] = offeredVersion;
            if (notice != null) state["notice"] = notice;
            Json.Write(UpdateStatePath, state); updateSummary = summary;
        }
        void DeliverUpdateNotice()
        {
            var state = UpdateState(); string failure = Json.Str(state, "queuedFailure");
            if (failure.Length == 0) return;
            state.Remove("queuedFailure"); Json.Write(UpdateStatePath, state);
            UpdateOutcome(failure, "новый EXE не подтвердил здоровье; выполнен откат");
        }
        void UpdateOutcome(string version, string reason)
        {
            string message = reason.Length == 0 ? "Программа обновлена до " + version : "Обновление " + version + " не установлено: " + reason;
            if (closing) return;
            var state = UpdateState(); string key = version + ":" + reason;
            // A config refusal may be retried after the config changes, but gives only one balloon per outcome.
            bool notify = Json.Str(state, "notice") != key;
            try { SaveUpdateState(message, key); } catch { updateSummary = message; log.Write("update.state.write.failed"); }
            if (reason.Length == 0) updateButton.OnUpdated(version); else ButtonDo(b => b.OnFailed(reason));
            if (notify) icon.ShowBalloonTip(8000, Product.Name, message, reason.Length == 0 ? ToolTipIcon.Info : ToolTipIcon.Warning);
        }
        bool UpdateOccupied()
        {
            return UpdateOccupiedReason().Length > 0;
        }
        string SettingsHash() { return Files.Hash(Path.Combine(home, "config.json")); }
        void PollUpdates()
        {
            PollButtonRelease();
            if (engine.Pending || File.Exists(Path.Combine(engine.Root, "exe-upgrade.json")) || updateChecking || closing) return;
            if (offeredUpdate != null) {
                if (!Json.Bool(config.Update, "enabled", true) || !Json.Bool(config.Update, "auto", true)) { offeredUpdate = null; return; }
                if (!UpdateOccupied()) InstallOfferedUpdate();
                return;
            }
            if (checkRequested && !UpdateOccupied()) { StartUpdateCheck(true); return; }
            if (updateSchedule.Due(DateTime.UtcNow, config.Update, UpdateOccupied())) StartUpdateCheck(false);
        }
        async void StartUpdateCheck(bool manual)
        {
            // Кнопка не должна зависнуть в «Проверяю…»: каждый ранний выход переводит её в итоговое состояние (идущую проверку закончит её собственный finally).
            if (updateChecking || engine.Pending || offeredUpdate != null || closing) { if (engine.Pending && !closing) ButtonDo(b => b.OnFailed("предыдущее обновление ещё проверяется")); return; }
            if (!Json.Bool(config.Update, "enabled", true)) { updateSummary = "Обновления выключены в конфиге"; ButtonDo(b => b.OnFailed("обновления выключены в конфиге")); RefreshMenu(); return; }
            if (UpdateOccupied()) { if (manual) ButtonDo(b => b.OnDeferred(UpdateOccupiedReason(), () => new ReleaseWait(this), () => UpdateOccupied())); return; }
            checkRequested = false; updateChecking = true; updateSchedule.Started(DateTime.UtcNow, config.Update);
            string snapshot, hash; Manifest manifest = null; bool installNow = false;
            try {
                snapshot = Json.Encode(config.Update); hash = SettingsHash();
                // Only manifest.json. A failed connection never changes transport, VPN, Disk or server files.
                var probe = await Task.Run(() => UpdateProbe.Read(() => SshSource.Load(Configuration.ForUpdate(snapshot), home).Manifest(home, stop.Token),
                    engine.Current, Program.Version, engine.IsBad, Json.Bool(Configuration.ForUpdate(snapshot).Update, "auto", true)));
                if (probe.Offer == UpdateOffer.Failed) throw new IOException();
                manifest = probe.Manifest;
                if (closing) return;
                var state = UpdateState(); state["checkedUtc"] = DateTime.UtcNow.ToString("o"); Json.Write(UpdateStatePath, state);
                if (probe.Offer == UpdateOffer.Current) {
                    SaveUpdateState("Установлена последняя версия " + engine.Current + ", проверено " + DateTime.Now.ToString("g"));
                    ButtonDo(b => b.OnUpToDate(engine.Current));
                } else if (probe.Offer == UpdateOffer.Bad) {
                    // Keep the original reason instead of repeating the failed install or its notification.
                    updateSummary = Json.Str(state, "notice").StartsWith(manifest.Version + ":", StringComparison.Ordinal) ? Json.Str(state, "summary") : "Обновление " + manifest.Version + " ранее отклонено; сохранена версия " + engine.Current;
                    string rejected = manifest.Version; ButtonDo(b => b.OnFailed("версия " + rejected + " ранее отклонена"));
                } else if (probe.Offer == UpdateOffer.NeedsInstaller) {
                    UpdateOutcome(manifest.Version, "нужна разовая установка нового EXE администратором");
                } else if (Json.Str(state, "blockedVersion") == manifest.Version && Json.Str(state, "blockedConfig") == hash) {
                    updateSummary = Json.Str(state, "summary"); string blocked = updateSummary; ButtonDo(b => b.OnFailed(blocked));
                } else if (probe.Offer == UpdateOffer.Available) {
                    offeredUpdate = manifest; offeredSettings = hash;
                    updateSummary = "Обновляется до " + manifest.Version + "; ожидается безопасный момент";
                    // Нажатая кнопка не ждёт тика: сразу ставим (после finally, чтобы флаги не затёрлись).
                    installNow = updateButton.IsBusy;
                } else { SaveUpdateState("Доступна версия " + manifest.Version + "; автоустановка выключена в конфиге"); string off = manifest.Version; ButtonDo(b => b.OnFailed("доступна версия " + off + ", автоустановка выключена в конфиге")); }
                log.Write("update.check.complete");
            } catch (OperationCanceledException) { }
            catch {
                log.Write("update.check.failed");
                // Connection/manifest failures do not claim the installed version is current.
                updateSummary = "Установлена версия " + engine.Current + "; обновления не проверены: нет связи или неверный манифест";
                ButtonDo(b => b.OnFailed("нет связи или неверный манифест"));
            } finally { updateChecking = false; if (!closing) RefreshMenu(); }
            if (closing) return;
            if (!installNow) { ButtonSettle("проверка не завершена"); return; }
            if (UpdateOccupied()) ButtonDo(b => b.OnDeferred(UpdateOccupiedReason(), () => new ReleaseWait(this), () => UpdateOccupied()));
            else InstallOfferedUpdate();
        }
        async void InstallOfferedUpdate()
        {
            UpdateEnvironment lease = null; Manifest manifest = offeredUpdate;
            try {
                lease = UpdateEnvironment.TryReserve(); if (lease == null) { ButtonDo(b => b.OnFailed("идёт другая операция обновления")); return; }
                if (SettingsHash() != offeredSettings) { offeredUpdate = null; updateSchedule.Retry(); ButtonDo(b => b.OnFailed("конфиг изменился; обновление будет проверено снова")); return; }
                offeredUpdate = null; busy = true; updateChecking = true; updateButton.OnChecking();
                updateSummary = "Обновляется до " + manifest.Version; RefreshMenu();
                var source = SshSource.Load(Configuration.ForUpdate(Json.Encode(config.Update)), home);
                string hash = SettingsHash();
                string ready = await Task.Run(() => engine.Prepare(manifest, p => { source.Fetch(manifest.FileName, p, manifest.Size, stop.Token, ButtonBytes(manifest.Size)); updateButton.OnDownloadProgress(new FileInfo(p).Length, manifest.Size); updateButton.OnVerifying(); },
                    f => External.UpdateSelfTest(f, home, stop.Token), (d, f) => { log.Write("transport.binary." + PinnedTransport.Ensure(home, f)); UpdateEngine.InstallBinaries(d, f, home, stop.Token); }, stop.Token));
                if (closing || ready == null) return;
                if (SettingsHash() != hash) { updateSchedule.Retry(); updateSummary = "Конфиг изменился; обновление будет проверено снова"; ButtonDo(b => b.OnFailed("конфиг изменился; обновление будет проверено снова")); return; }
                offeredVersion = ready; PrepareUpdateRestart();
                SaveUpdateState("Обновляется до " + ready, pending: true); updateButton.OnInstalling();
                if (!TrySelfUpdate(ready)) throw new InvalidDataException();
            } catch (ConfigCompatibilityException) {
                try { var state = UpdateState(); state["blockedVersion"] = manifest.Version; state["blockedConfig"] = SettingsHash(); Json.Write(UpdateStatePath, state); } catch { log.Write("update.state.write.failed"); }
                UpdateOutcome(manifest.Version, new ConfigCompatibilityException().Message); log.Write("update.config.refused"); }
            catch (OperationCanceledException) { }
            catch (InvalidDataException) { try { engine.MarkBad(manifest.Version); } catch { log.Write("update.bad.write.failed"); } UpdateOutcome(manifest.Version, "проверка сборки не прошла; сохранена прежняя версия"); log.Write("update.validation.failed"); }
            catch { if (!closing) UpdateOutcome(manifest.Version, "загрузка или установка не завершена; сохранена прежняя версия"); log.Write("update.install.failed"); }
            finally {
                if (lease != null) try { lease.Dispose(); } catch { log.Write("update.lease.release.failed"); }
                ButtonSettle("обновление не установлено");
                busy = updateChecking = false; if (!closing) RefreshMenu();
            }
        }
    }
}
