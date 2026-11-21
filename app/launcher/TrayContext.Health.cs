using System;
using System.Collections.Generic;
using System.Linq;
using System.IO;
using System.Threading;
using System.Windows.Forms;

namespace RemoteAgents.Launcher
{
    // Здоровье версии на событиях: после обновления приёмку даёт последний отчитавшийся блок.
    // H2: отказы и предохранитель дают откат; Tick отвечает только за отображение.
    internal sealed partial class TrayContext
    {
        HealthBoard healthBoard; bool vpnReadyPublished, diskReadyPublished, healthSettled;
        readonly object healthGate = new object();
        System.Threading.Timer healthFuse;

        // Вызывается из StartBus после подписок: доска нужна, только пока обновление ждёт приёмки.
        void StartHealth()
        {
            var state = UpdateState();
            if (!Json.Bool(state, "pending") && !engine.Pending && !File.Exists(Path.Combine(engine.Root, "exe-upgrade.json"))) return; // нет ожидающей приёмки транзакции
            healthBoard = new HealthBoard(HealthBoard.ExpectedBlocks(state), DateTime.UtcNow,
                runtimes.Where(r => r.Definition.Critical && r.Enabled).Select(r => r.Definition.Name),
                accepted: UpgradeInstaller.ImageHealthAccepted(home));
            healthFuse = new System.Threading.Timer(_ => HealthFuse(), null, Timeout.Infinite, Timeout.Infinite); // timer-ok: C — последний block.ready недоступен при зависании блока; UpdateNoProgressFuseMs даёт только отказ/откат.
            busParts.Add(healthFuse);
            if (!healthBoard.Accepted) ArmHealthFuse();
            busParts.Add(bus.Subscribe(BusTopics.HealthAccepted, e => PostUi(CommitHealth)));
            busParts.Add(bus.Subscribe(BusTopics.ComponentExit, e => {
                lock (healthGate) { if (healthBoard.ComponentExit(e.Get("name"))) HealthFailed(healthBoard.Failure); }
            }));
            log.Write("health.expected blocks=" + string.Join(",", healthBoard.Expected));
            busParts.Add(bus.Subscribe(BusTopics.BlockReady, e => HealthReport(e, true)));
            busParts.Add(bus.Subscribe(BusTopics.BlockDegraded, e => HealthReport(e, false)));
            busParts.Add(bus.Subscribe(BusTopics.BlockFailed, e => HealthReport(e, false))); // failed тоже снимает прежнюю готовность до приёмки
            busParts.Add(bus.Subscribe(BusTopics.VpnState, e => {
                bool on = e.Get("state") == "on";
                if (on && !vpnReadyPublished) bus.Publish(BusTopics.BlockReady, BusTopics.Sources.Tray, "block", "vpn", "via", "vpn-state");
                vpnReadyPublished = on;
            }));
            EventHandler idle = null; idle = (s, a) => { Application.Idle -= idle; bus.Publish(BusTopics.BlockReady, BusTopics.Sources.Tray, "block", "tray", "via", "idle"); };
            Application.Idle += idle; // источник готовности tray: первый простой цикла сообщений
            if (healthBoard.Accepted) PostUi(CommitHealth); // повторяем только финализацию уже сохранённой приёмки
        }

        void HealthReport(BusEvent e, bool ready)
        {
            lock (healthGate) {
                var board = healthBoard; if (board == null || healthSettled) return;
                string block = e.Get("block");
                // Диск считается готовым только по подтверждённой связи с сервером (как прежняя проверка), а не по файлу статуса.
                if (ready && block == "disk" && e.Get("via") != "server-connected") return;
                var r = ready ? board.Ready(block, DateTime.UtcNow) : board.Degraded(block, e.Get("reason"), DateTime.UtcNow);
                log.Write("health.block block=" + block + " event=" + (ready ? "ready" : "degraded") + " reason=" + e.Get("reason") + " counted=" + r.Counted + " missing=" + string.Join(",", board.Missing));
                if (r.Counted) {
                    // Прогресс сохраняется для независимого наблюдателя, даже если затем UI зависнет.
                    try { UpgradeInstaller.NoteHealthProgress(home, board.LastEventUtc); }
                    catch (Exception ex) { log.Write("update.health.progress.failed kind=" + ex.GetType().Name); }
                    ArmHealthFuse();
                }
                if (!r.Completed) return;
                healthFuse.Change(Timeout.Infinite, Timeout.Infinite);
                bus.Publish(BusTopics.HealthAccepted, BusTopics.Sources.Tray, "blocks", string.Join(",", board.Expected));
                log.Write("health.accepted");
            }
        }

        void ArmHealthFuse()
        {
            int remaining = (int)Math.Max(1, Math.Min(HealthBoard.UpdateNoProgressFuseMs,
                Math.Ceiling(HealthBoard.UpdateNoProgressFuseMs - (DateTime.UtcNow - healthBoard.LastEventUtc).TotalMilliseconds)));
            healthFuse.Change(remaining, Timeout.Infinite);
        }
        void HealthFuse()
        {
            lock (healthGate) {
                if (closing || healthSettled || healthBoard.Accepted || healthBoard.Failure.Length > 0) return;
                if (!healthBoard.FuseExpired(DateTime.UtcNow)) { ArmHealthFuse(); return; }
                if (healthBoard.Fail("no-progress-fuse")) HealthFailed(healthBoard.Failure);
            }
        }
        void HealthFailed(string reason)
        {
            log.Write("update.failed reason=" + reason);
            // Если наблюдатель погиб, SignalFailure заново вооружает прежний EXE, сохраняя отказ.
            bool watching = UpdateWatchdog.SignalFailure(home);
            if (File.Exists(Path.Combine(engine.Root, "exe-upgrade.json")) && watching) return;
            PostUi(() => {
                lock (healthGate) {
                    if (closing || healthSettled) return; healthSettled = true;
                    string version = engine.Current;
                    engine.Observe(false, failed: true);
                    UpgradeInstaller.ObserveImage(home, engine, false, "rollback");
                    UpdateOutcome(version, "здоровье не подтверждено; выполнен откат");
                    log.Write("update.rollback"); RestartRequested = true; ExitThread();
                }
            });
        }
        void CommitHealth()
        {
            lock (healthGate) {
                if (closing || healthSettled || !healthBoard.Accepted || healthBoard.Failure.Length > 0) return;
                try {
                    using (var failed = UpdateWatchdog.FailureEvent(home)) if (failed.WaitOne(0)) return;
                    // Решение доски сохраняется до финализации: ошибка уборки не отвергает принятую версию.
                    UpgradeInstaller.NoteHealthAccepted(home);
                    string result = engine.Observe(true);
                    string image = UpgradeInstaller.ObserveImage(home, engine, true, result);
                    healthSettled = true;
                    if (result == "accepted" || image == "accepted") { log.Write("update.accepted"); UpdateOutcome(engine.Current, ""); }
                    RefreshMenu();
                } catch (Exception ex) { log.Write("update.health.commit.failed kind=" + ex.GetType().Name); }
            }
        }

        // Источник готовности disk: локальный Syncthing подключён к серверу; один раз на подключение.
        void HealthDiskSeen(bool serverConnected)
        {
            if (healthBoard == null || bus == null) return;
            if (serverConnected && !diskReadyPublished) bus.Publish(BusTopics.BlockReady, BusTopics.Sources.Tray, "block", "disk", "via", "server-connected");
            diskReadyPublished = serverConnected;
        }
    }
}
