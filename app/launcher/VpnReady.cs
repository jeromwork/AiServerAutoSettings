using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Net;
using System.Threading;

namespace RemoteAgents.Launcher
{
    internal enum VpnGateOutcome { Ready, Fatal, CoreExited, Off, Fuse, RoutesOk, RoutesFuse }

    // Ворота готовности VPN (V3, vpn-events-plan 1.3/1.4). Подписаны на шину службы:
    //   готовность ядра = singbox.started core=vpn; падение = singbox.fatal core=vpn или выход процесса;
    //   выключение = vpn.off; перепроверка маршрута = win.route.changed / win.iface.changed / win.addr.changed.
    // Ожидание — по событию. Кусок WaitAny(PollMs) нужен ТОЛЬКО ради пульса аренды (lease.Pulse) и проверки выхода
    // процесса/отмены; он не условие готовности. Подписываться надо ДО запуска ядра (событие не теряется).
    internal sealed class VpnReadyGate : IDisposable
    {
        // Предохранитель (конституция 4а): событие singbox.started недоступно, если ядро зависло внутри Start;
        // при срабатывании — остановить ядро, состояние error/core-not-ready, успех не объявляет.
        // Сумма предохранителей службы при включении: exclusions 15 + check 15 + ready 20 + routes 10 = 60 с; предохранитель клиента HelperClient.VpnStartFuseMs должен быть больше этой суммы.
        internal const int CoreReadyFuseMs = 20000;
        // Предохранитель (конституция 4а): события win.route/iface.changed недоступны (уведомление не зарегистрировано
        // или маршрут так и не появился), если за это время маршрут на TUN не подтверждён; при срабатывании — остановить ядро,
        // состояние error/routes-not-ours, успех не объявляет.
        internal const int RouteFuseMs = 10000;

        readonly List<IDisposable> subs = new List<IDisposable>();
        readonly ManualResetEvent ready = new ManualResetEvent(false), fatal = new ManualResetEvent(false), off = new ManualResetEvent(false);
        readonly AutoResetEvent netChanged = new AutoResetEvent(false);
        volatile string readyLine = "", fatalLine = "", offReason = "";
        readonly string core;

        internal VpnReadyGate(EventBus bus, string core = "vpn")
        {
            if (bus == null) throw new ArgumentNullException("bus");
            this.core = core;
            long after = bus.LastSeq; // Ignore queued events from the previous process.
            subs.Add(bus.Subscribe(BusTopics.SingboxStarted, e => { if (e.Seq > after && e.Get("core") == this.core) { readyLine = e.Get("line"); ready.Set(); } }));
            subs.Add(bus.Subscribe(BusTopics.SingboxFatal, e => { if (e.Seq > after && e.Get("core") == this.core) { fatalLine = e.Get("line"); fatal.Set(); } }));
            subs.Add(bus.Subscribe(BusTopics.VpnOff, e => { offReason = e.Get("reason"); off.Set(); }));
            subs.Add(bus.Subscribe(BusTopics.WinRouteChanged, e => netChanged.Set()));
            subs.Add(bus.Subscribe(BusTopics.WinIfaceChanged, e => netChanged.Set()));
            subs.Add(bus.Subscribe(BusTopics.WinAddrChanged, e => netChanged.Set()));
        }
        internal string ReadyLine { get { return readyLine; } }
        internal string FatalLine { get { return fatalLine; } }
        internal string OffReason { get { return offReason; } }

        // Nonblocking owner-loop view, shared with the initial blocking gate.
        internal VpnGateOutcome? CoreStatus(bool coreExited)
        {
            if (fatal.WaitOne(0)) return VpnGateOutcome.Fatal;
            if (coreExited) return VpnGateOutcome.CoreExited;
            return ready.WaitOne(0) ? (VpnGateOutcome?)VpnGateOutcome.Ready : null;
        }

        // Ждёт первое из: готовность ядра, fatal, выход процесса, выключение, предохранитель. Порядок при одновременности:
        // выключение, fatal, выход процесса, готовность (ядро, которое сказало «started» и тут же упало, готовым не считается).
        internal VpnGateOutcome AwaitCore(Func<bool> coreExited, Func<bool> cancelled, Action pulse, Func<bool> fuse, int sliceMs = VpnWatchdog.PollMs)
        {
            var handles = new WaitHandle[] { ready, fatal, off };
            while (true) {
                if (cancelled()) return VpnGateOutcome.Off;
                off.Reset(); // vpn.off без реальной отмены этой попытки (устаревшее событие прошлого Disable) игнорируется
                var outcome = CoreStatus(coreExited());
                if (outcome.HasValue) return outcome.Value;
                if (fuse()) return VpnGateOutcome.Fuse;
                pulse();
                WaitHandle.WaitAny(handles, sliceMs); // пульс аренды, не условие готовности
            }
        }

        // Первая проверка маршрута сразу; повторная — только после уведомления Windows о смене маршрутов/интерфейсов.
        // result — последняя проверка (для журнала).
        internal VpnGateOutcome AwaitRoute(Func<VpnRouteResult> probe, Func<bool> cancelled, Action pulse, Func<bool> fuse, out VpnRouteResult result, int sliceMs = VpnWatchdog.PollMs)
        {
            var handles = new WaitHandle[] { netChanged, off };
            bool probeNow = true; // первая проверка сразу; дальше — по событию (флаг берётся из WaitAny: он сбрасывает AutoResetEvent)
            result = null;
            while (true) {
                if (cancelled()) return VpnGateOutcome.Off; // устаревший vpn.off без отмены не считается
                off.Reset();
                if (probeNow) {
                    probeNow = false;
                    result = probe();
                    if (result != null && result.Ok) return VpnGateOutcome.RoutesOk;
                }
                if (fuse()) return VpnGateOutcome.RoutesFuse; // на каждом проходе, в том числе после неудачной проверки
                pulse();
                int hit = WaitHandle.WaitAny(handles, sliceMs); // пульс аренды, не условие
                if (hit == 0) probeNow = true;
            }
        }

        // Проверка факта маршрута: Best(1.1.1.1) и Best(проба) == ifIndex TUN.
        internal static VpnRouteResult ProbeRoute(Func<IPAddress, int> best, Func<string, int> indexByName, Func<int, string> nameOf, IPAddress probe, string tunName)
        {
            var r = new VpnRouteResult { TunIf = indexByName(tunName) };
            r.Best1111 = best(IPAddress.Parse("1.1.1.1")); r.BestProbe = best(probe);
            r.Best1111Name = r.Best1111 > 0 ? nameOf(r.Best1111) : ""; r.BestProbeName = r.BestProbe > 0 ? nameOf(r.BestProbe) : "";
            return r;
        }

        // Предохранитель по реальным часам; в тестах подставляется ручной сигнал.
        internal static Func<bool> FuseAfter(int ms)
        {
            var watch = Stopwatch.StartNew();
            return () => watch.ElapsedMilliseconds >= ms;
        }

        public void Dispose()
        {
            foreach (var s in subs) { try { s.Dispose(); } catch { } }
            subs.Clear();
        }
    }
}
