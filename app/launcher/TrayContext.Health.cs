using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows.Forms;

namespace RemoteAgents.Launcher
{
    // Здоровье версии на событиях (шаг H1): после обновления приёмку даёт последний отчитавшийся блок, а не окно 120 с.
    // Откат (H2) и 120/125 с здесь не трогаются.
    internal sealed partial class TrayContext
    {
        HealthBoard healthBoard; bool vpnReadyPublished, diskReadyPublished;

        // Блоки, работавшие до обновления: tray и transport всегда, остальные (disk, control=bridge, vpn) — из update-state.json.
        static string[] ExpectedBlocks(Dictionary<string, object> state)
        {
            var set = new List<string> { "tray", "transport" };
            set.AddRange(Json.Strings(Json.Get(state, "runningComponents")));
            if (Json.Bool(state, "vpnOn")) set.Add("vpn");
            return set.Where(x => x.Length > 0).Distinct(StringComparer.Ordinal).ToArray();
        }

        // Вызывается из StartBus после подписок: доска нужна, только пока обновление ждёт приёмки.
        void StartHealth()
        {
            var state = UpdateState();
            if (!Json.Bool(state, "pending") && !engine.Pending) return;
            healthBoard = new HealthBoard(ExpectedBlocks(state), DateTime.UtcNow);
            log.Write("health.expected blocks=" + string.Join(",", healthBoard.Expected));
            busParts.Add(bus.Subscribe(BusTopics.BlockReady, e => HealthReport(e, true)));
            busParts.Add(bus.Subscribe(BusTopics.BlockDegraded, e => HealthReport(e, false)));
            busParts.Add(bus.Subscribe(BusTopics.VpnState, e => {
                bool on = e.Get("state") == "on";
                if (on && !vpnReadyPublished) bus.Publish(BusTopics.BlockReady, BusTopics.Sources.Tray, "block", "vpn", "via", "vpn-state");
                vpnReadyPublished = on;
            }));
            EventHandler idle = null; idle = (s, a) => { Application.Idle -= idle; bus.Publish(BusTopics.BlockReady, BusTopics.Sources.Tray, "block", "tray", "via", "idle"); };
            Application.Idle += idle; // источник готовности tray: первый простой цикла сообщений
        }

        void HealthReport(BusEvent e, bool ready)
        {
            var board = healthBoard; if (board == null) return;
            string block = e.Get("block");
            // Диск считается готовым только по подтверждённой связи с сервером (как прежняя проверка), а не по файлу статуса.
            if (block == "disk" && e.Get("via") != "server-connected") return;
            var r = ready ? board.Ready(block, DateTime.UtcNow) : board.Degraded(block, e.Get("reason"), DateTime.UtcNow);
            log.Write("health.block block=" + block + " event=" + (ready ? "ready" : "degraded") + " reason=" + e.Get("reason") + " counted=" + r.Counted + " missing=" + string.Join(",", board.Missing));
            if (!r.Completed) return;
            bus.Publish(BusTopics.HealthAccepted, BusTopics.Sources.Tray, "blocks", string.Join(",", board.Expected));
            log.Write("health.accepted");
            // Приёмка сразу: прогон Tick на UI-потоке вместо ожидания очередного тика.
            PostUi(() => { if (!closing) Tick(); });
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
