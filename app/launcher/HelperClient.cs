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
        internal const string PermissionRequired = NetHelperSetup.PermissionRequired;
        readonly string home;
        readonly Control ui;
        readonly Journal journal;
        readonly object gate = new object(), exchangeGate = new object();
        NetHelperProtocol.Reader connectionReader;
        NamedPipeClientStream pipe;
        Form notice;
        Label summary;
        Button install;
        volatile bool disposed;
        bool busy, connectionAttempted;
        static readonly NetHelperSetup setup = new NetHelperSetup();
        static event Action<bool> SetupCompleted;
        internal static string SetupWarning { get { return setup.Warning; } }
        internal string Status { get; private set; }
        internal HelperClient(string home, Control ui) { this.home = home; this.ui = ui; journal = new Journal(home); SetupCompleted += OnSetupCompleted; }
        // Every new tray (including the EXE started after OTA) enters this shared setup gate.
        internal void EnsureRunning()
        {
            if (disposed || busy) return;
            busy = true; connectionAttempted = true;
            Task.Run(async () => {
                bool reinstall = false, needed = false;
                string message = "";
                try {
                    needed = NetHelperSetup.Required(new Configuration(home).Data);
                    if (needed) {
                        var engine = new UpdateEngine(home, Program.Version);
                        reinstall = !await EnsureInstalled(home, engine.Current.Length == 0 ? home : engine.Folder(engine.Current),
                            text => Post(() => { Status = text; ShowNotice(text, true); }), CancellationToken.None);
                        if (reinstall) message = setup.Warning;
                        else { Connect(); message = "Сетевой помощник подключён"; }
                    }
                } catch (Exception error) { journal.Write(TickFailureLog.HelperFailure("connect", error)); message = "Локальные сети и VPN недоступны: не удалось подключиться к помощнику"; }
                Post(() => {
                    busy = false; if (!needed) connectionAttempted = false; Status = message;
                    if (notice != null && !notice.IsDisposed && !reinstall && Connected) { notice.Close(); return; }
                    if (needed && !Connected) ShowNotice(message, reinstall);
                });
            });
        }
        void OnSetupCompleted(bool ready)
        {
            Post(() => {
                if (ready) { if (!busy) { connectionAttempted = false; EnsureRunning(); } }
                else { connectionAttempted = true; Status = setup.Warning; ShowNotice(Status, true); }
            });
        }
        // A config can first acquire lan[] while the initial wizard is still open.
        internal void ConnectWhenInstalled(bool required)
        {
            if (required && !connectionAttempted && setup.Warning.Length == 0 && !NetHelperInstall.NeedsInstall(NetHelperInstall.InstalledVersion)) EnsureRunning();
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
                    return HelperLanStatus.Unavailable(config, Installed, Connected);
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
            if (!Json.Bool(result, "ok") || (ping && Json.Str(result, "reply") != "pong")) {
                // No remote message/secret enters the journal; the service records the original exception.
                journal.Write("helper.reply.failed stage=" + command + " code=" + Json.Int(result, "errorCode", 0).ToString(System.Globalization.CultureInfo.InvariantCulture));
                throw new IOException("Ошибка помощника");
            }
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
                catch (Exception error) { journal.Write(TickFailureLog.HelperFailure("request", error)); channel.Dispose(); throw; } // A timed-out frame must never be reused.
            }
        }
        // A deliberate VPN-on action can be the first request for a helper in this session.
        internal async Task<bool> EnsureReady(CancellationToken token)
        {
            while (busy) { await Task.Delay(100, token); }
            if (Connected) return true;
            busy = true; connectionAttempted = true;
            try {
                var engine = new UpdateEngine(home, Program.Version);
                bool ready = await EnsureInstalled(home, engine.Current.Length == 0 ? home : engine.Folder(engine.Current),
                    text => { Status = text; ShowNotice(text, true); }, token, required: true);
                if (!ready) return false;
                await Task.Run(() => Connect(), token);
                Status = "Сетевой помощник подключён";
                if (notice != null && !notice.IsDisposed) notice.Close();
                return true;
            } finally { busy = false; if (install != null && !install.IsDisposed) install.Enabled = true; }
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
            } catch (Exception error) {
                journal.Write(TickFailureLog.HelperFailure("monitor", error));
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
                        var engine = new UpdateEngine(home, Program.Version);
                        if (engine.Current.Length == 0) throw new IOException("Нет установленного бандла");
                        bool ready = await EnsureInstalled(home, engine.Folder(engine.Current), text => { Status = text; summary.Text = text; }, CancellationToken.None, retry: true);
                        result = ready ? "" : setup.Warning;
                    } catch (Exception error) { journal.Write(TickFailureLog.HelperFailure("install", error)); result = "Не удалось установить сетевой помощник"; }
                    busy = false;
                    if (disposed) return;
                    if (!install.IsDisposed) install.Enabled = true;
                    if (result.Length == 0) EnsureRunning(); else { Status = result; ShowNotice(result, true); }
                };
                notice.Controls.Add(summary); notice.Controls.Add(install);
            }
            summary.Text = message; install.Text = needsInstall ? "Установить помощника" : "Подключить помощник";
            install.Tag = needsInstall; install.Enabled = !busy;
            notice.Show();
        }
        // Setup errors are warnings: unrelated config sections and wizard actions must still run.
        internal static async Task<bool> EnsureInstalled(string home, string bundle, Action<string> progress, CancellationToken token,
            bool retry = false, bool? required = null)
        {
            int generation = setup.InstallGeneration;
            bool ready = await NetHelperSetup.ContinueApply(() => setup.Ensure(
                required ?? NetHelperSetup.Required(new Configuration(home).Data),
                () => NetHelperInstall.IsCurrent,
                () => Task.Run(() => PinnedTransport.Ensure(home, bundle), token),
                () => Task.Run(() => InstallElevated(home, bundle)), progress, token, retry),
                error => new Journal(home).Write(TickFailureLog.HelperFailure(
                    error is Win32Exception && ((Win32Exception)error).NativeErrorCode == 1223 ? "setup-uac" : "setup", error)));
            if (!ready) progress(setup.Warning);
            // Do not signal an installation for a config that needs no helper.
            if (!ready || setup.InstallGeneration != generation) {
                var changed = SetupCompleted; if (changed != null) changed(ready);
            }
            return ready;
        }
        static int InstallElevated(string home, string bundle)
        {
            string sid;
            using (var identity = WindowsIdentity.GetCurrent()) sid = identity.User.Value;
            var args = new[] { "--net-helper-install", "--home", home, "--owner-sid", sid, "--helper-bundle", bundle };
            return NetHelperInstall.IsAdministrator ? NetHelperInstall.Install(args) : Elevated(args);
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
            SetupCompleted -= OnSetupCompleted;
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
