using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace RemoteAgents.Launcher
{
    // Шина событий лаунчера (шаг B2). Блоки публикуют факты, трей подписан; периодика — только tick.* шины.
    internal sealed partial class TrayContext
    {
        EventBus bus; BlockStatusTracker blocks; StatusDirWatcher statusWatcher;
        readonly List<IDisposable> busParts = new List<IDisposable>();
        readonly TickGate trayTickGate = new TickGate(); bool transportReady; readonly DateTime busStartedUtc = DateTime.UtcNow;

        // Период плановой проверки обновлений — из конфига на момент запуска (intervalHours).
        int UpdateTickMs() { return UpdatePolicy.Interval(config.Update) * 3600 * 1000; }

        // Вызывается из UI-потока: обработчики шины работают в потоке диспетчера и сразу передают дело UI-потоку.
        void PostUi(Action action)
        { TryPostUi(action); }
        bool TryPostUi(Action action)
        { try { dispatch.BeginInvoke(action); return true; } catch (InvalidOperationException) { return false; } }

        void StartBus()
        {
            bus = new EventBus();
            busParts.Add(bus);
            // Журнал шины (поток bus): создаётся сразу за шиной; освобождается раньше неё (busParts снимаются с конца), итог повторов пишется до остановки шины.
            busParts.Add(new BusJournal(bus, RaLog.DefaultDir));
            // Подписки раньше источников: готовность блока, уже наступившая к старту, тоже придёт подписчику.
            busParts.Add(TrayBusWiring.WireUpdateRequests(bus, manual => PostUi(() => { if (!closing) ButtonProceed(); })));
            busParts.Add(TrayBusWiring.WireUpdateTick(bus, () => PostUi(() => {
                if (closing || !Json.Bool(config.Update, "enabled", true)) return;
                // Занято (диск, окно настройки): проверка уйдёт при освобождении через PollUpdates.
                if (UpdateOccupied()) checkRequested = true; else StartUpdateCheck(false);
            })));
            busParts.Add(TrayBusWiring.WireTransportReady(bus, () => PostUi(() => { transportReady = true; if (ladder != null) ladder.TransportReady(); })));
            busParts.Add(bus.Subscribe(BusTopics.TickLogship, e => PumpLogs()));
            busParts.Add(bus.Subscribe(BusTopics.TickSupervisor, e => { foreach (var r in runtimes) r.CheckStale(); }));
            busParts.Add(bus.Subscribe(BusTopics.TickTray, e => {
                // Одна невыполненная доставка за раз: если UI занят, тики не копятся; не смогли отправить — счётчик сброшен.
                trayTickGate.Deliver(TryPostUi, Tick);
            }));
            WireRuntimeBus();
            updateSchedule.RetryRequested = () => { checkRequested = true; };
            checkRequested = true; // первая проверка при старте; PollUpdates дождётся готовности и безопасного момента
            busParts.Add(bus.Every(BusTopics.Ticks.Update, UpdateTickMs()));
            // 5 с, а не 60: shipper.Tick сам решает по своему nextAt (60 с) и по Kick (через 5 с), тик лишь будит его.
            busParts.Add(bus.Every(BusTopics.Ticks.Logship, 5000));
            // Тик трея 1 с (§4а-долг: остальное содержимое Tick пока опрашивает состояние само).
            busParts.Add(bus.Every(BusTopics.Ticks.Tray, 1000));
            busParts.Add(bus.Every(BusTopics.Ticks.Supervisor, 1000));
            try {
                blocks = new BlockStatusTracker(bus, busStartedUtc);
                statusWatcher = new StatusDirWatcher(Path.Combine(home, "status"), blocks);
                busParts.Add(statusWatcher);
            } catch (Exception ex) { log.Write("bus.status-watcher.failed err=" + ex.GetType().Name); }
        }

        // tick.logship: отправка журналов и подтяжка журнала помощника (работа сама уходит в фон).
        void PumpLogs()
        {
            var s = shipper; if (s != null) s.Tick();
            var m = mirror;
            if (m != null && DateTime.UtcNow >= nextMirror) { nextMirror = DateTime.UtcNow.AddSeconds(60); Task.Run(() => { try { m.Pull(); } catch { } }); }
        }

        void AttachLadderToBus() { if (transportReady && ladder != null) ladder.TransportReady(); }
        void WireRuntimeBus() { foreach (var r in runtimes) r.Bus = bus; }

        void StopBus()
        {
            for (int i = busParts.Count - 1; i >= 0; i--) { try { busParts[i].Dispose(); } catch { } }
            busParts.Clear();
        }
    }
}
