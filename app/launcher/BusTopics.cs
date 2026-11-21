using System;
using System.Collections.Generic;

namespace RemoteAgents.Launcher
{
    /// <summary>
    /// Единый список топиков шины событий (план vpn-master, шаг B1).
    /// </summary>
    public static class BusTopics
    {
        // TODO (B2): retained block.ready хранит один ключ на топик ("block.ready"), для нескольких блоков нужен ключ на блок (например, "block.ready." + block).
        // Готовность блоков: block.ready|block.degraded|block.failed {block, reason}
        public const string BlockReady = "block.ready";
        public const string BlockDegraded = "block.degraded";
        public const string BlockFailed = "block.failed";

        // Supervisor: component.start|component.exit|component.stale-restart {name, code}
        public const string ComponentStart = "component.start";
        public const string ComponentExit = "component.exit";
        public const string ComponentStaleRestart = "component.stale-restart";

        // Аварийные топики
        public const string Unhandled = "unhandled";

        // sing-box: singbox.started|singbox.fatal|singbox.line|singbox.iface {core: vpn|transport, line}
        public const string SingboxStarted = "singbox.started";
        public const string SingboxFatal = "singbox.fatal";
        public const string SingboxLine = "singbox.line";
        public const string SingboxIface = "singbox.iface";

        // Уведомления Windows (W1): win.route.changed|win.iface.changed|win.addr.changed {family, ifIndex}
        public const string WinRouteChanged = "win.route.changed";
        public const string WinIfaceChanged = "win.iface.changed";
        public const string WinAddrChanged = "win.addr.changed";
        // Сбой регистрации уведомления Windows: win.notify.error {api, rc}
        public const string WinNotifyError = "win.notify.error";

        // Сеть (Q): net.change {id, class}, net.quality {...}, net.e2e
        public const string NetChange = "net.change";
        public const string NetQuality = "net.quality";
        public const string NetE2E = "net.e2e";

        // Транспорт (T0/T2): transport.status, transport.episode, transport.switch, transport.mem, transport.command, transport.mem-high
        public const string TransportStatus = "transport.status";
        public const string TransportEpisode = "transport.episode";
        public const string TransportSwitch = "transport.switch";
        public const string TransportMem = "transport.mem";
        public const string TransportCommand = "transport.command";
        public const string TransportMemHigh = "transport.mem-high";

        // VPN: vpn.state {state, reason, seq}, vpn.step, vpn.rollback, vpn.off, vpn.on, vpn.health, vpn.config
        public const string VpnState = "vpn.state";
        public const string VpnStep = "vpn.step";
        public const string VpnRollback = "vpn.rollback";
        public const string VpnOff = "vpn.off";
        public const string VpnOn = "vpn.on";
        public const string VpnHealth = "vpn.health";
        public const string VpnConfig = "vpn.config";

        // Помощник (Helper): helper.version, helper.updated, helper.update.rejected
        public const string HelperVersion = "helper.version";
        public const string HelperUpdated = "helper.updated";
        public const string HelperUpdateRejected = "helper.update.rejected";

        // Обновление: update.requested|update.phase|update.progress {pct, bytes}|update.result
        public const string UpdateRequested = "update.requested";
        public const string UpdatePhase = "update.phase";
        public const string UpdateProgress = "update.progress";
        public const string UpdateResult = "update.result";

        // Здоровье: health.accepted|health.rollback|health.fuse
        public const string HealthAccepted = "health.accepted";
        public const string HealthRollback = "health.rollback";
        public const string HealthFuse = "health.fuse";

        // Периодика: tick.<имя>
        public const string TickPrefix = "tick.";

        // Константы тиков (полные имена топиков)
        public const string TickTray = "tick.tray";
        public const string TickSupervisor = "tick.supervisor";
        public const string TickVpnScan = "tick.vpn-scan";
        public const string TickTransportMem = "tick.transport-mem";
        public const string TickTransportEpisode = "tick.transport-episode";
        public const string TickTransportDecide = "tick.transport-decide";
        public const string TickUpdate = "tick.update";
        public const string TickLogship = "tick.logship";

        // Внутренние события шины: bus.overflow, bus.handler-error, bus.noise-summary
        public const string BusOverflow = "bus.overflow";
        public const string BusHandlerError = "bus.handler-error";
        public const string BusNoiseSummary = "bus.noise-summary";

        /// <summary>
        /// Имена тиков без префикса (для вызова Every/FireTick).
        /// </summary>
        public static class Ticks
        {
            public const string Tray = "tray";
            public const string Supervisor = "supervisor";
            public const string VpnScan = "vpn-scan";
            public const string TransportMem = "transport-mem";
            public const string TransportEpisode = "transport-episode";
            public const string TransportDecide = "transport-decide";
            public const string Update = "update";
            public const string Logship = "logship";
        }

        /// <summary>
        /// Источники событий (BusEvent.Source): tray|helper|transport|vpn-core|transport-core|windows|timer
        /// </summary>
        public static class Sources
        {
            public const string Tray = "tray";
            public const string Helper = "helper";
            public const string Transport = "transport";
            public const string VpnCore = "vpn-core";
            public const string TransportCore = "transport-core";
            public const string Windows = "windows";
            public const string Timer = "timer";
        }

        // TODO (B2): retained block.ready хранит один ключ на топик ("block.ready"), для нескольких блоков нужен ключ на блок.
        private static readonly HashSet<string> RetainedTopicSet = new HashSet<string>(StringComparer.Ordinal)
        {
            VpnState,
            VpnHealth,
            NetQuality,
            TransportStatus,
            TransportMem,
            TransportMemHigh,
            HelperVersion,
            BlockReady,
            BlockDegraded,
            BlockFailed
        };

        /// <summary>
        /// Топики с сохраняемым (retained) состоянием: мост помощника шлёт их новому клиенту первыми.
        /// </summary>
        public static IEnumerable<string> RetainedTopics { get { return RetainedTopicSet; } }

        /// <summary>
        /// Проверка, входит ли топик в белый список сохраняемых (retained) состояний.
        /// </summary>
        public static bool IsRetainedTopic(string topic)
        {
            return topic != null && RetainedTopicSet.Contains(topic);
        }
    }
}
