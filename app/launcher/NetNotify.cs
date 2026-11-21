using System;
using System.Collections.Generic;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;

namespace RemoteAgents.Launcher
{
    /// <summary>
    /// Источник уведомлений Windows об изменении сети (W1). Реальный — iphlpapi, в тестах — заглушка.
    /// Обработчики вызываются из потока Windows: только публикуют и выходят.
    /// </summary>
    public interface INetNotifySource : IDisposable
    {
        /// <summary>Начать приём. Каждый обработчик: (family, ifIndex, type).</summary>
        void Start(Action<int, int, int> onRoute, Action<int, int, int> onIface, Action<int, int, int> onAddr, Action<bool> onAvailability, Action<string, int> onError);
    }

    /// <summary>
    /// Публикует win.route.changed / win.iface.changed / win.addr.changed в шину.
    /// Пачки схлопываются по признаку «такое же событие уже в очереди и ещё не доставлено».
    /// </summary>
    public sealed class NetNotify : IDisposable
    {
        private readonly EventBus _bus;
        private readonly INetNotifySource _source;
        private readonly string _busSource;
        private readonly object _lock = new object();
        // Ключ -> событие в очереди шины. Ограничено числом различных (топик, семейство, адаптер, тип).
        private readonly HashSet<string> _pending = new HashSet<string>(StringComparer.Ordinal);
        private IDisposable _deliverySub;
        private bool _started;
        private bool _disposed;

        public NetNotify(EventBus bus, INetNotifySource source, string busSource = BusTopics.Sources.Windows)
        {
            if (bus == null) throw new ArgumentNullException(nameof(bus));
            if (source == null) throw new ArgumentNullException(nameof(source));
            _bus = bus;
            _source = source;
            _busSource = busSource;
        }

        /// <summary>Реальный источник Windows.</summary>
        public static NetNotify CreateWindows(EventBus bus)
        {
            return new NetNotify(bus, new WindowsNetNotifySource());
        }

        public void Start()
        {
            lock (_lock)
            {
                if (_started || _disposed) return;
                _started = true;
            }
            // Подписка снимает признак «в очереди», когда событие дошло до подписчиков.
            IDisposable sub = _bus.Subscribe("win.", OnDelivered);
            lock (_lock)
            {
                if (_disposed) { try { sub.Dispose(); } catch { } return; }
                _deliverySub = sub;
            }
            try
            {
                _source.Start(
                    (f, i, t) => Raise(BusTopics.WinRouteChanged, f, i, t),
                    (f, i, t) => Raise(BusTopics.WinIfaceChanged, f, i, t),
                    (f, i, t) => Raise(BusTopics.WinAddrChanged, f, i, t),
                    available => RaiseAvailability(available),
                    (api, rc) => RaiseError(api, rc));
            }
            catch (Exception ex)
            {
                // Источник не стартовал: сообщаем событием, снимаем источник и подписку, вызывающего не роняем.
                RaiseError("start:" + ex.GetType().Name, -1);
                try { _source.Dispose(); } catch { }
                IDisposable toDrop;
                lock (_lock) { toDrop = _deliverySub; _deliverySub = null; _pending.Clear(); }
                try { if (toDrop != null) toDrop.Dispose(); } catch { }
            }
        }

        private void RaiseError(string api, int rc)
        {
            lock (_lock) { if (_disposed) return; }
            try
            {
                _bus.Publish(BusTopics.WinNotifyError, _busSource, "api", api,
                    "rc", rc.ToString(System.Globalization.CultureInfo.InvariantCulture));
            }
            catch { }
        }

        private static string Key(string topic, string family, string ifIndex, string type, string available)
        {
            return topic + "|" + family + "|" + ifIndex + "|" + type + "|" + available;
        }

        public static string FamilyName(int family)
        {
            if (family == 2) return "ipv4";
            if (family == 23) return "ipv6";
            if (family == 0) return "all";
            return family.ToString(System.Globalization.CultureInfo.InvariantCulture);
        }

        public static string TypeName(int type)
        {
            switch (type)
            {
                case 0: return "parameter";
                case 1: return "add";
                case 2: return "delete";
                case 3: return "initial";
                default: return type.ToString(System.Globalization.CultureInfo.InvariantCulture);
            }
        }

        private void Raise(string topic, int family, int ifIndex, int type)
        {
            Publish(topic, FamilyName(family), ifIndex.ToString(System.Globalization.CultureInfo.InvariantCulture), TypeName(type), null);
        }

        private void RaiseAvailability(bool available)
        {
            Publish(BusTopics.WinIfaceChanged, "all", "0", "availability", available ? "true" : "false");
        }

        private void Publish(string topic, string family, string ifIndex, string type, string available)
        {
            string key = Key(topic, family, ifIndex, type, available ?? "");
            lock (_lock)
            {
                if (_disposed) return;
                if (_pending.Contains(key)) return; // такое же событие ещё не доставлено
                _pending.Add(key);
            }
            long seq = available == null
                ? _bus.Publish(topic, _busSource, "family", family, "ifIndex", ifIndex, "type", type)
                : _bus.Publish(topic, _busSource, "family", family, "ifIndex", ifIndex, "type", type, "available", available);
            if (seq < 0)
            {
                // Шина отбросила событие: признак не должен залипнуть.
                lock (_lock) { _pending.Remove(key); }
            }
        }

        private void OnDelivered(BusEvent e)
        {
            string key = Key(e.Topic, e.Get("family"), e.Get("ifIndex"), e.Get("type"), e.Get("available"));
            lock (_lock) { _pending.Remove(key); }
        }

        public int PendingCount
        {
            get { lock (_lock) { return _pending.Count; } }
        }

        public void Dispose()
        {
            lock (_lock)
            {
                if (_disposed) return;
                _disposed = true;
            }
            try { _source.Dispose(); } catch { }
            try { if (_deliverySub != null) _deliverySub.Dispose(); } catch { }
        }
    }

    /// <summary>Реальный источник: NotifyRouteChange2, NotifyIpInterfaceChange, NotifyUnicastIpAddressChange, NetworkAvailabilityChanged.</summary>
    public sealed class WindowsNetNotifySource : INetNotifySource
    {
        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        private delegate void ChangeCallback(IntPtr callerContext, IntPtr row, uint notificationType);

        [DllImport("iphlpapi.dll")]
        private static extern int NotifyRouteChange2(ushort addressFamily, ChangeCallback callback, IntPtr callerContext,
            [MarshalAs(UnmanagedType.U1)] bool initialNotification, out IntPtr notificationHandle);

        [DllImport("iphlpapi.dll")]
        private static extern int NotifyIpInterfaceChange(ushort addressFamily, ChangeCallback callback, IntPtr callerContext,
            [MarshalAs(UnmanagedType.U1)] bool initialNotification, out IntPtr notificationHandle);

        [DllImport("iphlpapi.dll")]
        private static extern int NotifyUnicastIpAddressChange(ushort addressFamily, ChangeCallback callback, IntPtr callerContext,
            [MarshalAs(UnmanagedType.U1)] bool initialNotification, out IntPtr notificationHandle);

        [DllImport("iphlpapi.dll")]
        private static extern int CancelMibChangeNotify2(IntPtr notificationHandle);

        private const ushort AfUnspec = 0;
        private const int InitialNotificationType = 3;

        // Делегаты держим в статическом списке: иначе GC соберёт их, пока Windows ещё может вызвать колбэк.
        private static readonly List<ChangeCallback> KeepAlive = new List<ChangeCallback>();

        private readonly object _lock = new object();
        private readonly List<IntPtr> _handles = new List<IntPtr>();
        private readonly List<ChangeCallback> _mine = new List<ChangeCallback>();
        private Action<bool> _onAvailability;
        private NetworkAvailabilityChangedEventHandler _availHandler;
        private bool _disposed;

        public void Start(Action<int, int, int> onRoute, Action<int, int, int> onIface, Action<int, int, int> onAddr, Action<bool> onAvailability, Action<string, int> onError)
        {
            // Смещения структур: MIB_IPFORWARD_ROW2 — ifIndex 8, family 12; MIB_IPINTERFACE_ROW — family 0, ifIndex 16;
            // MIB_UNICASTIPADDRESS_ROW — family 0, ifIndex 40.
            Register(onRoute, onError, "NotifyRouteChange2", 12, 8, NotifyRouteChange2);
            Register(onIface, onError, "NotifyIpInterfaceChange", 0, 16, NotifyIpInterfaceChange);
            Register(onAddr, onError, "NotifyUnicastIpAddressChange", 0, 40, NotifyUnicastIpAddressChange);

            lock (_lock)
            {
                if (_disposed) return;
                _onAvailability = onAvailability;
                _availHandler = (s, e) =>
                {
                    Action<bool> cb = _onAvailability;
                    if (cb != null) cb(e.IsAvailable);
                };
            }
            NetworkChange.NetworkAvailabilityChanged += _availHandler;
        }

        private delegate int RegisterFn(ushort family, ChangeCallback cb, IntPtr ctx, bool initial, out IntPtr handle);

        private void Register(Action<int, int, int> handler, Action<string, int> onError, string api, int familyOffset, int ifIndexOffset, RegisterFn fn)
        {
            // В колбэке только читаем поля строки и вызываем обработчик; iphlpapi отсюда не вызывается.
            ChangeCallback cb = (ctx, row, type) =>
            {
                try
                {
                    if (type == InitialNotificationType) return;
                    int family = 0, ifIndex = 0;
                    if (row != IntPtr.Zero)
                    {
                        family = (ushort)Marshal.ReadInt16(row, familyOffset);
                        ifIndex = Marshal.ReadInt32(row, ifIndexOffset);
                    }
                    handler(family, ifIndex, (int)type);
                }
                catch { }
            };
            lock (_lock)
            {
                if (_disposed) return;
                _mine.Add(cb);
            }
            lock (KeepAlive) { KeepAlive.Add(cb); }
            IntPtr h = IntPtr.Zero;
            int rc;
            try
            {
                rc = fn(AfUnspec, cb, IntPtr.Zero, false, out h);
            }
            catch (Exception ex) when (ex is DllNotFoundException || ex is EntryPointNotFoundException)
            {
                rc = -1;
                h = IntPtr.Zero;
            }
            bool keep = false;
            bool closed = false;
            if (rc == 0 && h != IntPtr.Zero)
            {
                lock (_lock)
                {
                    if (_disposed) closed = true;
                    else { _handles.Add(h); keep = true; }
                }
            }
            if (closed)
            {
                // Dispose успел раньше: сами снимаем регистрацию, и только потом отпускаем делегат.
                try { CancelMibChangeNotify2(h); } catch { }
            }
            if (!keep)
            {
                lock (_lock) { _mine.Remove(cb); }
                lock (KeepAlive) { KeepAlive.Remove(cb); }
            }
            if (rc != 0 && onError != null)
            {
                try { onError(api, rc); } catch { }
            }
        }

        public void Dispose()
        {
            List<IntPtr> handles;
            List<ChangeCallback> mine;
            NetworkAvailabilityChangedEventHandler ah;
            lock (_lock)
            {
                if (_disposed) return;
                _disposed = true;
                handles = new List<IntPtr>(_handles);
                mine = new List<ChangeCallback>(_mine);
                ah = _availHandler;
                _handles.Clear();
                _mine.Clear();
                _onAvailability = null;
                _availHandler = null;
            }
            if (ah != null) { try { NetworkChange.NetworkAvailabilityChanged -= ah; } catch { } }
            foreach (IntPtr h in handles)
            {
                try { CancelMibChangeNotify2(h); } catch { }
            }
            lock (KeepAlive) { foreach (ChangeCallback cb in mine) KeepAlive.Remove(cb); }
        }
    }
}
