namespace RemoteAgents.Launcher
{
    /// <summary>
    /// Единый список топиков шины событий (план vpn-master, шаг B1).
    /// </summary>
    public static class BusTopics
    {
        // Готовность блоков: block.ready|block.degraded|block.failed {block, reason}
        public const string BlockReady = "block.ready";
        public const string BlockDegraded = "block.degraded";
        public const string BlockFailed = "block.failed";

        // Supervisor: component.start|component.exit {name, code}
        public const string ComponentStart = "component.start";
        public const string ComponentExit = "component.exit";

        // sing-box: singbox.started|singbox.fatal|singbox.line|singbox.iface {core: vpn|transport, line}
        public const string SingboxStarted = "singbox.started";
        public const string SingboxFatal = "singbox.fatal";
        public const string SingboxLine = "singbox.line";
        public const string SingboxIface = "singbox.iface";

        // Уведомления Windows (W1): win.route.changed|win.iface.changed|win.addr.changed {family, ifIndex}
        public const string WinRouteChanged = "win.route.changed";
        public const string WinIfaceChanged = "win.iface.changed";
        public const string WinAddrChanged = "win.addr.changed";

        // Сеть (Q): net.change {id, class} и net.quality {...}
        public const string NetChange = "net.change";
        public const string NetQuality = "net.quality";

        // Транспорт (T0/T2): transport.status, transport.episode, transport.switch, transport.mem
        public const string TransportStatus = "transport.status";
        public const string TransportEpisode = "transport.episode";
        public const string TransportSwitch = "transport.switch";
        public const string TransportMem = "transport.mem";

        // VPN: vpn.state {state, reason, seq}, vpn.step, vpn.rollback
        public const string VpnState = "vpn.state";
        public const string VpnStep = "vpn.step";
        public const string VpnRollback = "vpn.rollback";

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

        // Внутренние события шины: bus.overflow, bus.handler-error
        public const string BusOverflow = "bus.overflow";
        public const string BusHandlerError = "bus.handler-error";

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
    }
}
