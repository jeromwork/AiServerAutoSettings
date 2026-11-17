using System;
using System.ComponentModel;
using System.Collections.Generic;
using System.Linq;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Pipes;
using System.Security.Principal;
using System.ServiceProcess;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace RemoteAgents.Launcher
{
    // Owns one authenticated connection for precisely the tray's lifetime.
    internal sealed class HelperClient : IDisposable
    {
        internal const string PermissionRequired = "Локальные сети и VPN недоступны: помощник не установлен (нужно разрешение Windows)";
        internal const string UpdateRequired = "Обновился сетевой помощник — нужно одно разрешение Windows";
        readonly string home;
        readonly Control ui;
        readonly object gate = new object(), exchangeGate = new object();
        NetHelperProtocol.Reader connectionReader;
        NamedPipeClientStream pipe;
        Form notice;
        Label summary;
        Button install;
        volatile bool disposed;
        bool busy;
        internal string Status { get; private set; }
        internal HelperClient(string home, Control ui) { this.home = home; this.ui = ui; }
        internal void EnsureRunning()
        {
            if (disposed || busy) return;
            busy = true;
            Task.Run(() => {
                bool reinstall = true;
                string message;
                try {
                    string version = NetHelperInstall.InstalledVersion;
                    bool exists = NetHelperInstall.Exists();
                    reinstall = !exists || NetHelperInstall.NeedsInstall(version);
                    if (reinstall) { message = version.Length == 0 || !exists ? PermissionRequired : UpdateRequired; }
                    else { Connect(); message = "Сетевой помощник подключён"; }
                } catch { message = "Локальные сети и VPN недоступны: не удалось подключиться к помощнику"; }
                Post(() => {
                    busy = false; Status = message;
                    if (notice != null && !notice.IsDisposed && !reinstall && Connected) { notice.Close(); return; }
                    if (!Connected) ShowNotice(message, reinstall);
                });
            });
        }
        string lanWanted = "{\"cmd\":\"lan.stop\"}";
        Dictionary<string, object> lanState = Json.Map(null);
        DateTime lanUpdated;
        internal bool Installed { get { return NetHelperInstall.InstalledVersion.Length > 0; } }
        internal void UpdateLan(Dictionary<string, object> config, Dictionary<string, object> transport)
        {
            try {
                var request = LanTunNetwork.Request(Json.Map(Json.Get(config, "profile")), Json.Int(Json.Map(Json.Get(transport, "helper")), "lanInPort", 0));
                // Wait for the effective port; never guess it from a default or send invalid input.
                if (Json.Str(request, "cmd") == "lan.apply" && Json.Int(request, "socksPort", 0) == 0) return;
                string wanted = Json.Encode(request); lock (gate) lanWanted = wanted;
            } catch { Status = "Локальные сети: неверный конфиг"; }
        }
        internal Dictionary<string, object> LanStatus(Dictionary<string, object> config)
        {
            lock (gate) {
                if (Connected && lanState.Count > 0 && (DateTime.UtcNow - lanUpdated).TotalSeconds <= 15) return lanState;
                try {
                    var networks = LanAccess.Read(Json.Map(Json.Get(config, "profile"))).Networks.Where(n => Json.Bool(n, "enabled") && Json.Strings(Json.Get(n, "subnets")).Length > 0)
                        .Select(n => { var row = new Dictionary<string, object>(n); row["state"] = Installed ? "channel-down" : "no-helper"; row["reason"] = Installed ? (Connected ? "ожидается проверка локальных сетей" : "нет связи с помощником") : "помощник не установлен"; return (object)row; }).ToArray();
                    return new Dictionary<string, object> { { "enabled", networks.Length > 0 }, { "networks", networks } };
                } catch { return Json.Map(null); }
            }
        }
        internal bool Ready { get { return Connected; } }
        bool Connected { get { lock (gate) return !disposed && pipe != null && pipe.IsConnected; } }
        void Connect()
        {
            if (disposed) return;
            using (var service = new ServiceController(NetHelperInstall.ServiceName)) {
                service.Refresh();
                if (service.Status == ServiceControllerStatus.StopPending) service.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(15));
                service.Refresh();
                if (service.Status == ServiceControllerStatus.Stopped) service.Start();
                service.WaitForStatus(ServiceControllerStatus.Running, TimeSpan.FromSeconds(15));
            }
            var channel = new NamedPipeClientStream(".", NetHelperProtocol.PipeName, PipeDirection.InOut, PipeOptions.Asynchronous, TokenImpersonationLevel.Impersonation);
            lock (gate) { if (disposed) { channel.Dispose(); return; } if (pipe != null) pipe.Dispose(); pipe = channel; }
            try {
                channel.Connect(10000);
                // A squatted pipe must not be mistaken for the LocalSystem service.
                uint serverPid;
                if (!GetNamedPipeServerProcessId(channel.SafePipeHandle, out serverPid) || !IsServiceProcess(serverPid)) throw new IOException("Недостоверный помощник");
                var reader = new NetHelperProtocol.Reader(channel);
                lock (exchangeGate) { connectionReader = reader; Exchange(channel, reader, "ping"); }
                Task.Run(() => Monitor(channel, reader));
            } catch { lock (gate) { if (pipe == channel) pipe = null; } channel.Dispose(); throw; }
        }
        System.Collections.Generic.Dictionary<string, object> Exchange(NamedPipeClientStream channel, NetHelperProtocol.Reader reader, string command)
        { return ExchangeRequest(channel, reader, new { cmd = command }, command == "ping"); }
        System.Collections.Generic.Dictionary<string, object> ExchangeRequest(NamedPipeClientStream channel, NetHelperProtocol.Reader reader, object request, bool ping = false)
        {
            string encoded = Json.Encode(request);
            string command = Json.Str(Json.Map(Json.Parse(encoded)), "cmd");
            var write = NetHelperProtocol.WriteLine(channel, encoded);
            if (!write.Wait(5000)) throw new IOException("Помощник не отвечает");
            var read = reader.ReadLine();
            if (!read.Wait(command == "lan.apply" || command == "lan.stop" ? 120000 : 15000)) throw new IOException("Помощник не отвечает");
            string response = read.GetAwaiter().GetResult();
            if (response == null) throw new IOException("Помощник отключился");
            var result = Json.Map(Json.Parse(response));
            if (!Json.Bool(result, "ok") || (ping && Json.Str(result, "reply") != "pong")) throw new IOException("Ошибка помощника");
            var vpn = Json.Map(Json.Get(result, "vpn"));
            if (vpn.Count > 0) Files.Atomic(Path.Combine(home, "status/vpn.json"), Json.Encode(vpn));
            return result;
        }
        System.Collections.Generic.Dictionary<string, object> Request(object request)
        {
            lock (exchangeGate) {
                NamedPipeClientStream channel;
                lock (gate) { if (disposed || pipe == null || !pipe.IsConnected || connectionReader == null) throw new IOException(PermissionRequired); channel = pipe; }
                try { return ExchangeRequest(channel, connectionReader, request); }
                catch { channel.Dispose(); throw; } // A timed-out frame must never be reused.
            }
        }
        internal Task<System.Collections.Generic.Dictionary<string, object>> VpnOn(VpnTun options)
        {
            return Task.Run(() => {
                var result = Json.Map(Json.Get(Request(options.Request()), "vpn"));
                var wait = Stopwatch.StartNew();
                while (Json.Str(result, "state") == "starting" && wait.ElapsedMilliseconds < 45000) {
                    Thread.Sleep(200);
                    result = Json.Map(Json.Get(Request(new { cmd = "status" }), "vpn"));
                }
                if (Json.Str(result, "state") == "starting") { Request(new { cmd = "vpn.off" }); throw new IOException("Подготовка VPN не завершена"); }
                return result;
            });
        }
        internal Task VpnOff() { return Task.Run(() => { Request(new { cmd = "vpn.off" }); }); }
        void Monitor(NamedPipeClientStream channel, NetHelperProtocol.Reader reader)
        {
            string applied = null;
            try {
                while (true) {
                    // No reconnect/autorestart: a failed session stays off until an explicit retry.
                    lock (gate) { if (disposed || pipe != channel) return; }
                    lock (exchangeGate) {
                        lock (gate) { if (disposed || pipe != channel) return; }
                        string wanted; lock (gate) wanted = lanWanted;
                        if (wanted != applied) { ExchangeRequest(channel, reader, Json.Parse(wanted)); applied = wanted; }
                        var status = Exchange(channel, reader, "status");
                        lock (gate) { lanState = Json.Map(Json.Get(status, "lan")); lanUpdated = DateTime.UtcNow; }
                    }
                    for (int i = 0; i < 20; i++) {
                        lock (gate) { if (disposed || pipe != channel) return; }
                        Thread.Sleep(100);
                    }
                }
            } catch {
                try { Files.Atomic(Path.Combine(home, "status/vpn.json"), Json.Encode(new { owner = "net-helper", enabled = false, ok = false, state = "core-exited", stage = "helper-disconnected", summary = "VPN выключен: сетевой помощник отключился", updatedAt = DateTime.UtcNow.ToString("o") })); } catch { }
                lock (gate) { if (pipe == channel) pipe = null; channel.Dispose(); }
                Post(() => { if (!disposed) { Status = "Локальные сети и VPN недоступны: помощник отключился"; ShowNotice(Status, false); } });
            }
        }
        void Post(Action action)
        { try { if (!disposed && !ui.IsDisposed) ui.BeginInvoke(new Action(() => { if (!disposed) action(); })); } catch (InvalidOperationException) { } }
        void ShowNotice(string message, bool needsInstall)
        {
            if (disposed) return;
            if (notice == null || notice.IsDisposed) {
                notice = new Form { Text = "RemoteAgents — сетевой помощник", ClientSize = new Size(510, 155), StartPosition = FormStartPosition.CenterScreen, FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false, AutoScaleMode = AutoScaleMode.Dpi };
                summary = new Label { Location = new Point(16, 16), Size = new Size(478, 78) };
                install = new Button { Location = new Point(260, 108), Size = new Size(234, 30) };
                install.Click += async (s, e) => {
                    if (busy || disposed) return;
                    if (!(bool)install.Tag) { EnsureRunning(); return; }
                    busy = true; install.Enabled = false;
                    string result;
                    try {
                        int code = await Task.Run(() => InstallElevated());
                        result = code == 0 ? "" : "Локальные сети и VPN недоступны: установка помощника не завершена";
                    } catch (Win32Exception ex) { result = ex.NativeErrorCode == 1223 ? PermissionRequired : "Не удалось установить сетевой помощник"; }
                    catch { result = "Не удалось установить сетевой помощник"; }
                    busy = false;
                    if (disposed) return;
                    if (!install.IsDisposed) install.Enabled = true;
                    if (result.Length == 0) EnsureRunning(); else { Status = result; ShowNotice(result, true); }
                };
                notice.Controls.Add(summary); notice.Controls.Add(install);
            }
            summary.Text = message; install.Text = needsInstall ? (NetHelperInstall.InstalledVersion.Length == 0 ? "Установить помощник" : "Обновить помощник") : "Подключить помощник";
            install.Tag = needsInstall; install.Enabled = !busy;
            notice.Show();
        }
        int InstallElevated()
        {
            var engine = new UpdateEngine(home, Program.Version);
            if (engine.Current.Length == 0) throw new IOException("Нет установленного бандла");
            string sid;
            using (var identity = WindowsIdentity.GetCurrent()) sid = identity.User.Value;
            return Elevated(new[] { "--net-helper-install", "--home", home, "--owner-sid", sid, "--helper-bundle", engine.Folder(engine.Current) });
        }
        internal static void UninstallElevated()
        {
            if (!NetHelperInstall.Exists() && !Directory.Exists(NetHelperInstall.InstallDirectory) && !Directory.Exists(NetHelperInstall.DataDirectory)) return;
            int code = NetHelperInstall.IsAdministrator ? NetHelperInstall.Uninstall() : Elevated(new[] { "--net-helper-uninstall" });
            if (code != 0) throw new IOException("Сетевой помощник не удалён");
        }
        static int Elevated(string[] args)
        {
            using (var process = Process.Start(new ProcessStartInfo(Program.Exe, Files.Arguments(args)) { UseShellExecute = true, Verb = "runas", WorkingDirectory = Path.GetDirectoryName(Program.Exe) })) {
                if (process == null) throw new IOException("Установка не запущена");
                process.WaitForExit(); return process.ExitCode;
            }
        }
        public void Dispose()
        {
            lock (gate) { if (disposed) return; disposed = true; if (pipe != null) { pipe.Dispose(); pipe = null; } }
            if (notice != null && !notice.IsDisposed) notice.Dispose();
        }
        static bool IsServiceProcess(uint pid)
        {
            // ServiceController.ServiceHandle requests ALL_ACCESS on Framework. Open only
            // QUERY_STATUS: the owner's service DACL deliberately grants no config/write rights.
            using (var manager = OpenSCManager(null, null, 1)) {
                if (manager.IsInvalid) return false;
                using (var service = OpenService(manager, NetHelperInstall.ServiceName, 4)) {
                    if (service.IsInvalid) return false;
                    ServiceStatusProcess status; int needed;
                    if (!QueryServiceStatusEx(service, 0, out status, System.Runtime.InteropServices.Marshal.SizeOf(typeof(ServiceStatusProcess)), out needed)) return false;
                    return pid != 0 && status.pid == pid && status.state == 4;
                }
            }
        }
        sealed class ServiceHandle : Microsoft.Win32.SafeHandles.SafeHandleZeroOrMinusOneIsInvalid
        {
            public ServiceHandle() : base(true) { }
            protected override bool ReleaseHandle() { return CloseServiceHandle(handle); }
        }
        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        struct ServiceStatusProcess { public uint type, state, accepted, win32Exit, specificExit, checkpoint, waitHint, pid, flags; }
        [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)] static extern bool GetNamedPipeServerProcessId(Microsoft.Win32.SafeHandles.SafePipeHandle pipe, out uint pid);
        [System.Runtime.InteropServices.DllImport("advapi32.dll", SetLastError = true)] static extern bool QueryServiceStatusEx(ServiceHandle service, int level, out ServiceStatusProcess status, int length, out int needed);
        [System.Runtime.InteropServices.DllImport("advapi32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)] static extern ServiceHandle OpenSCManager(string machine, string database, uint access);
        [System.Runtime.InteropServices.DllImport("advapi32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)] static extern ServiceHandle OpenService(ServiceHandle manager, string name, uint access);
        [System.Runtime.InteropServices.DllImport("advapi32.dll", SetLastError = true)] static extern bool CloseServiceHandle(IntPtr handle);
    }
}
