using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
#if !PORTABLE_TEST
using System.ComponentModel;
using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.ServiceProcess;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;
#endif

namespace RemoteAgents.Launcher
{
    // Pure lifetime policy, shared by the real service and portable tests.
    internal sealed class NetHelperLifetime
    {
        internal const int ConnectionTimeoutMs = 30000;
        readonly Func<long> clock;
        readonly long started;
        readonly Action cleanup, stop;
        readonly object gate = new object();
        readonly List<IDisposable> jobs = new List<IDisposable>();
        bool jobsClosed, connected;
        int ended;
        internal NetHelperLifetime(Func<long> clock, Action cleanup, Action stop)
        { this.clock = clock; started = clock(); this.cleanup = cleanup; this.stop = stop; }
        internal bool ConnectionExpired { get { return !connected && clock() - started >= ConnectionTimeoutMs; } }
        internal void Connected() { connected = true; }
        internal void AddJob(IDisposable job)
        {
            lock (gate) {
                if (jobsClosed) { job.Dispose(); throw new ObjectDisposedException("NetHelperLifetime"); }
                jobs.Add(job);
            }
        }
        internal void RemoveJob(IDisposable job) { lock (gate) jobs.Remove(job); }
        internal void CloseJobs()
        {
            lock (gate) {
                jobsClosed = true;
                // Attempt every Job even when one close fails. No logging/I/O before this.
                foreach (var job in jobs) try { job.Dispose(); } catch { }
                jobs.Clear();
            }
        }
        internal void Shutdown()
        {
            // Even concurrent SCM stop/disconnect callers close the Jobs before doing I/O.
            CloseJobs();
            if (Interlocked.Exchange(ref ended, 1) != 0) return;
            try { cleanup(); } finally { stop(); }
        }
    }

#if !PORTABLE_TEST
    // свой код только как обвязка над SCM и sing-box
    internal sealed class NetHelper : ServiceBase
    {
        readonly string ownerSid, home;
        LanTun lan;
        System.Threading.Timer lanTimer;
        VpnTunSession vpnTun;
        readonly ManualResetEvent stopping = new ManualResetEvent(false), emergency = new ManualResetEvent(false);
        readonly object pipeGate = new object();
        NamedPipeServerStream pipe, eventsPipe;
        Thread worker, eventsWorker;
        EventBus bus;
        HelperBusSender busSender; BusJournal busJournal;
        NetNotify netNotify; // уведомления Windows о маршрутах/интерфейсах -> win.* в шину (W1); нужны воротам VPN (V3)
        // Предохранитель (конституция 4а): событие «клиент прислал hello» недоступно, если клиент подключился и молчит; при срабатывании — канал событий закрывается, успех не объявляет.
        internal const int EventsHelloFuseMs = 10000;
        const int EventsQueueLimit = 2000;
        NetHelperLifetime lifetime;
        NetHelperLog log;
        internal NetHelper(string ownerSid, string home)
        {
            this.home = Path.GetFullPath(home);
            this.ownerSid = new SecurityIdentifier(NetHelperInstall.ValidateSid(ownerSid)).Value;
            ServiceName = NetHelperInstall.ServiceName; CanStop = true; CanShutdown = true; AutoLog = false;
        }
        internal static int Run(string[] args)
        {
            try {
                // Home comes only from the protected SCM command, never from a pipe request.
                string home = Path.GetFullPath(Program.Option(args, "--home") ?? throw new ArgumentException("Нет home"));
                using (var service = new NetHelper(Program.Option(args, "--owner-sid"), home)) ServiceBase.Run(service);
                return 0;
            } catch { return 1; } // Never open a WinForms error dialog in LocalSystem session 0.
        }
        protected override void OnStart(string[] args)
        {
            var clock = Stopwatch.StartNew();
            lifetime = new NetHelperLifetime(() => clock.ElapsedMilliseconds, Cleanup, () => ThreadPool.QueueUserWorkItem(_ => Stop()));
            worker = new Thread(Loop) { IsBackground = true, Name = "RemoteAgentsNet owner" }; worker.Start();
        }
        void Cleanup()
        {
            if (lanTimer != null) lanTimer.Dispose();
            // Never touch foreign policies. LAN disposal also waits out any cancelled command.
            try { if (lan != null) lan.Dispose(); else NetHelperInstall.RemoveNrpt(); if (log != null) log.Write("cleanup", 0); }
            catch { if (log != null) log.Write("cleanup", 1); }
            lock (pipeGate) { if (pipe != null) { pipe.Dispose(); pipe = null; } if (eventsPipe != null) { eventsPipe.Dispose(); eventsPipe = null; } }
            if (netNotify != null) netNotify.Dispose(); // источник Windows — до остановки шины
            if (busJournal != null) busJournal.Dispose(); // итог повторов и шума — до остановки шины
            if (busSender != null) busSender.Dispose();
            if (bus != null) bus.Dispose();
            if (log != null) log.Write("stopped", 0);
            RaLog.FlushLimits();
        }
        protected override void OnStop()
        {
            if (lifetime != null) lifetime.CloseJobs(); // Network FIRST, before pipe disposal, logs or joins.
            stopping.Set();
            lock (pipeGate) { if (pipe != null) pipe.Dispose(); if (eventsPipe != null) eventsPipe.Dispose(); }
            if (worker != null && worker != Thread.CurrentThread) worker.Join(30000);
        }
        protected override void OnShutdown() { OnStop(); base.OnShutdown(); }
        void Loop()
        {
            VpnLease lease = null;
            string outcome = "disconnected"; int outcomeCode = 0;
            try {
                lease = new VpnLease(() => { lifetime.CloseJobs(); emergency.Set(); });
                NetHelperInstall.SecureDirectory(NetHelperInstall.DataDirectory);
                log = new NetHelperLog(NetHelperInstall.DataDirectory); log.Write("starting", 0);
                bus = new EventBus(defaultSource: BusTopics.Sources.Helper);
                busSender = new HelperBusSender(bus);
                busJournal = new BusJournal(bus, sink: l => log.Events.WriteLine(l), excludeTopics: new[] { BusTopics.SingboxLine }); // журнал шины службы: helper-events (singbox.line исключён: уже есть как core.line), на сервере helper.log (comp bus)
                HelperBus.Bus = bus; // читатель вывода ядра (V1) публикует singbox.* через неё
                log.Core.Bus = bus;
                netNotify = NetNotify.CreateWindows(bus); netNotify.Start(); // сбой регистрации не роняет службу: событие win.notify.error
                bus.Publish(BusTopics.HelperVersion, BusTopics.Sources.Helper, "version", NetHelperInstall.HelperVersion);
                bus.Publish(BusTopics.VpnState, BusTopics.Sources.Helper, "state", "off", "reason", "helper-start", "enabled", "false", "ok", "false", "name", "");
                var lanClock = Stopwatch.StartNew();
                var lanPlatform = new WindowsLanTun(home, config => {
                    IDisposable job; var process = StartSingBox(Core.Lan, config, out job);
                    return new LanTunProcess(process, job, () => lifetime.RemoveJob(job));
                }, log.Write, lifetime.AddJob, lifetime.RemoveJob);
                // Names of the LAN for programs that cannot use NRPT (another VPN client blocks DNS port 53): a hosts block kept by this service.
                lan = new LanTun(lanPlatform, () => lanClock.ElapsedMilliseconds, new LanHosts(new WindowsLanHosts(lanPlatform.Credentials, log.Write), a => Task.Run(a)));
                // Only one callback may do network I/O. Status/commands also serialize in LanTun.
                int lanTicking = 0;
                lanTimer = new System.Threading.Timer(_ => {
                    if (stopping.WaitOne(0) || Interlocked.Exchange(ref lanTicking, 1) != 0) return;
                    try { lan.Tick(); } finally { Interlocked.Exchange(ref lanTicking, 0); }
                }, null, 1000, 1000);
                lock (pipeGate) {
                    if (stopping.WaitOne(0)) return;
                    pipe = CreatePipe(ownerSid, NetHelperProtocol.PipeName);
                }
                eventsWorker = new Thread(EventsLoop) { IsBackground = true, Name = "RemoteAgentsNet events" }; eventsWorker.Start();
                Task connection = pipe.WaitForConnectionAsync();
                if (!Wait(connection, lease, true)) return;
                connection.GetAwaiter().GetResult();
                bool authenticated = false;
                var reader = new NetHelperProtocol.Reader(pipe);
                while (!stopping.WaitOne(0) && !emergency.WaitOne(0)) {
                    var read = reader.ReadLine();
                    if (!Wait(read, lease, !authenticated)) break;
                    string line;
                    try { line = read.GetAwaiter().GetResult(); }
                    catch (InvalidDataException) {
                        lifetime.CloseJobs(); outcome = "bad-request"; outcomeCode = 87;
                        var rejected = NetHelperProtocol.WriteLine(pipe, NetHelperProtocol.BadRequest);
                        if (Wait(rejected, lease, false)) rejected.GetAwaiter().GetResult();
                        break; // Cannot safely resynchronize an oversized/incomplete frame.
                    }
                    if (line == null) break;
                    if (!authenticated) {
                        if (!IsOwner(pipe, ownerSid)) { outcome = "client-denied"; outcomeCode = 5; break; }
                        authenticated = true; lifetime.Connected(); log.Write("connected", 0);
                    }
                    // NRPT, route inspection and probes may take seconds. Keep the independent
                    // fail-open lease advancing on the owner loop while the operation is awaited.
                    var dispatch = Task.Run(() => NetHelperProtocol.Reply(line, log.Recent, Execute));
                    if (!Wait(dispatch, lease, false)) break;
                    string reply = dispatch.GetAwaiter().GetResult();
                    var write = NetHelperProtocol.WriteLine(pipe, reply);
                    if (!Wait(write, lease, false)) break;
                    write.GetAwaiter().GetResult();
                }
            } catch {
                lifetime.CloseJobs(); // No error log until every network Job has closed.
                outcome = "loop-error"; outcomeCode = 1;
            } finally {
                lifetime.CloseJobs();
                if (lease != null) lease.Dispose();
                if (emergency.WaitOne(0)) { outcome = "lease-expired"; outcomeCode = 1460; }
                else if (lifetime.ConnectionExpired) { outcome = "connection-timeout"; outcomeCode = 1460; }
                else if (stopping.WaitOne(0)) { outcome = "scm-stop"; outcomeCode = 0; }
                if (log != null) log.Write(outcome, outcomeCode);
                lifetime.Shutdown();
            }
        }
        // Второй pipe: помощник -> трей, только события шины из белого списка. Основной pipe команд не занят.
        void EventsLoop()
        {
            while (!stopping.WaitOne(0) && !emergency.WaitOne(0)) {
                NamedPipeServerStream channel = null;
                try {
                    lock (pipeGate) {
                        if (stopping.WaitOne(0)) return;
                        channel = CreatePipe(ownerSid, NetHelperProtocol.EventsPipeName); eventsPipe = channel;
                    }
                } catch { return; } // События необязательны: без второго pipe команды и VPN работают как раньше.
                try {
                    channel.WaitForConnectionAsync().GetAwaiter().GetResult(); // остановка службы закрывает pipe и прерывает ожидание
                    var reader = new NetHelperProtocol.Reader(channel);
                    var hello = reader.ReadLine();
                    if (!hello.Wait(EventsHelloFuseMs) || hello.GetAwaiter().GetResult() != NetHelperProtocol.EventsHello || !IsOwner(channel, ownerSid)) continue;
                    using (var queue = new System.Collections.Concurrent.BlockingCollection<string>(EventsQueueLimit)) {
                        // Клиент после hello молчит: завершение чтения = он отключился.
                        reader.ReadLine().ContinueWith(_ => { try { queue.CompleteAdding(); } catch { } }, TaskContinuationOptions.ExecuteSynchronously);
                        using (busSender.Attach(frame => { try { queue.TryAdd(frame); } catch { } })) {
                            foreach (string line in queue.GetConsumingEnumerable()) NetHelperProtocol.WriteLine(channel, line).GetAwaiter().GetResult();
                        }
                    }
                } catch { /* клиент ушёл или pipe закрыт при остановке: новый экземпляр pipe */ }
                finally { lock (pipeGate) { if (eventsPipe == channel) eventsPipe = null; } channel.Dispose(); }
            }
        }
        string Execute(string command, Dictionary<string, object> request)
        {
            if (command == "log.read") {
                ulong after; ulong.TryParse(Json.Str(request, "after", "0"), out after);
                log.Core.Flush();
                return HelperEventLog.Reply(log.Events.Read(after, Json.Int(request, "max", HelperEventLog.MaxRead)), NetHelperInstall.HelperVersion);
            }
            bool noisy = command == "status";
            var timer = Stopwatch.StartNew();
            if (!noisy) log.Events.Write(LogLevel.Info, "helper", "cmd.recv", "cmd", command);
            string reply = null;
            try { reply = ExecuteCommand(command, request); return reply; }
            finally { if (!noisy) log.Events.Write(LogLevel.Info, "helper", "cmd.done", "cmd", command, "ms", timer.ElapsedMilliseconds.ToString(System.Globalization.CultureInfo.InvariantCulture), "ok", (reply != null && reply.StartsWith("{\"ok\":false") ? "false" : "true")); }
        }
        string ExecuteCommand(string command, Dictionary<string, object> request)
        {
            if (command == "lan.apply") return Json.Encode(lan.Apply(request));
            if (command == "lan.stop") return Json.Encode(lan.Stop());
            try {
                if (command == "vpn.on") {
                    var options = VpnTun.Read(request);
                    if (vpnTun == null) {
                        vpnTun = new VpnTunSession(home, NetHelperInstall.DataDirectory, Path.Combine(NetHelperInstall.InstallDirectory, "sing-box.exe"), action => {
                            // User-controlled files are opened under the authenticated pipe owner,
                            // never with SYSTEM's file access (including reparse targets).
                            NamedPipeServerStream channel; lock (pipeGate) channel = pipe;
                            if (channel == null) throw new IOException("Клиент отключился");
                            channel.RunAsClient(() => action());
                        }, log.Write) { Events = log.Events, CorePump = log.Core, Bus = bus };
                        lifetime.AddJob(vpnTun);
                    }
                    vpnTun.Enable(options);
                } else if (command == "vpn.off") {
                    if (vpnTun != null) vpnTun.Disable();
                } else if (command != "status") return "{\"ok\":false,\"error\":\"not-implemented\"}";
                var vpn = vpnTun == null ? VpnTun.D("owner", "net-helper", "enabled", false, "ok", false, "state", "off", "summary", "VPN выключен", "updatedAt", DateTime.UtcNow.ToString("o")) : vpnTun.Status();
                return NetHelperProtocol.Status(log.Recent, lan.Status(), vpn);
            } catch (Exception error) {
                log.Write(command == "vpn.on" ? "vpn-on" : command == "vpn.off" ? "vpn-off" : "status", TickFailureLog.ErrorCode(error), error.GetType().Name);
                return Json.Encode(new { ok = false, error = "vpn-command-failed", errorCode = TickFailureLog.ErrorCode(error) });
            }
        }
        bool Wait(Task operation, VpnLease lease, bool waitingForClient)
        {
            while (true) {
                if (stopping.WaitOne(0) || emergency.WaitOne(0) || lease.Expired || (waitingForClient && lifetime.ConnectionExpired)) return false;
                lease.Pulse();
                if (operation.IsCompleted) return true;
                stopping.WaitOne(50);
            }
        }
        internal enum Core { Lan, Vpn }
        // Only service-built configs enter this method. No client paths, executable names or JSON configs.
        internal Process StartSingBox(Core kind, object serviceConfig)
        { IDisposable owned; return StartSingBox(kind, serviceConfig, out owned); }
        Process StartSingBox(Core kind, object serviceConfig, out IDisposable owned)
        {
            owned = null;
            if (kind != Core.Lan && kind != Core.Vpn) throw new ArgumentException("Неизвестное ядро");
            string config = Path.Combine(NetHelperInstall.DataDirectory, kind == Core.Lan ? "lan.json" : "vpn.json");
            NetHelperInstall.RejectReparse(NetHelperInstall.DataDirectory);
            if (File.Exists(config) && (File.GetAttributes(config) & FileAttributes.ReparsePoint) != 0) throw new IOException("Небезопасный конфиг");
            Files.Atomic(config, Json.Encode(serviceConfig)); // Inherits SYSTEM + Administrators only.
            var job = new NativeJob(); lifetime.AddJob(job); owned = job;
            try {
                if (kind == Core.Lan) {
                    using (var check = job.Start(Path.Combine(NetHelperInstall.InstallDirectory, "sing-box.exe"), new[] { "check", "-c", config }, NetHelperInstall.InstallDirectory))
                        if (!check.WaitForExit(10000) || check.ExitCode != 0) throw new InvalidDataException("Конфиг ЛВС не прошёл проверку");
                }
                return job.Start(Path.Combine(NetHelperInstall.InstallDirectory, "sing-box.exe"), new[] { "run", "-c", config }, NetHelperInstall.InstallDirectory);
            } catch { job.Dispose(); lifetime.RemoveJob(job); throw; }
        }
        static NamedPipeServerStream CreatePipe(string sid, string pipeName)
        {
            var acl = new PipeSecurity(); acl.SetAccessRuleProtection(true, false);
            acl.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(sid), PipeAccessRights.ReadWrite, AccessControlType.Allow));
            acl.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), PipeAccessRights.FullControl, AccessControlType.Allow));
            byte[] descriptor = acl.GetSecurityDescriptorBinaryForm();
            var pinned = GCHandle.Alloc(descriptor, GCHandleType.Pinned);
            try {
                var security = new SecurityAttributes { length = Marshal.SizeOf(typeof(SecurityAttributes)), descriptor = pinned.AddrOfPinnedObject() };
                // FIRST_PIPE_INSTANCE refuses a squatted name; REJECT_REMOTE_CLIENTS makes PID identity local.
                var handle = CreateNamedPipe(@"\\.\pipe\" + pipeName, 0x40080003, 0x8, 1, 65536, 65536, 0, ref security);
                if (handle.IsInvalid) { handle.Dispose(); throw new Win32Exception(); }
                try { return new NamedPipeServerStream(PipeDirection.InOut, true, false, handle); }
                catch { handle.Dispose(); throw; }
            } finally { pinned.Free(); }
        }
        static bool IsOwner(NamedPipeServerStream stream, string owner)
        {
            uint pid;
            if (!GetNamedPipeClientProcessId(stream.SafePipeHandle, out pid) || pid == 0 || pid > int.MaxValue) return false;
            using (var process = OpenProcess(0x1000, false, pid)) {
                if (process.IsInvalid) return false;
                SafeFileHandle token;
                if (!OpenProcessToken(process, 8, out token)) return false;
                using (token)
                using (var identity = new WindowsIdentity(token.DangerousGetHandle())) {
                    if (identity.User == null || identity.User.Value != owner) return false;
                    // Also compare the kernel's pipe impersonation identity, guarding PID exit/reuse.
                    bool same = false;
                    stream.RunAsClient(() => { using (var client = WindowsIdentity.GetCurrent()) same = client.User != null && client.User.Value == owner; });
                    return same;
                }
            }
        }
        [StructLayout(LayoutKind.Sequential)] struct SecurityAttributes { public int length; public IntPtr descriptor; [MarshalAs(UnmanagedType.Bool)] public bool inherit; }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern SafePipeHandle CreateNamedPipe(string name, uint openMode, uint pipeMode, uint instances, uint outputSize, uint inputSize, uint timeout, ref SecurityAttributes security);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe, out uint pid);
        [DllImport("kernel32.dll", SetLastError = true)] static extern SafeFileHandle OpenProcess(uint access, bool inherit, uint pid);
        [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(SafeFileHandle process, uint access, out SafeFileHandle token);
    }

    internal sealed class NetHelperLog
    {
        const int Limit = 1024 * 1024;
        readonly string file;
        readonly Queue<string> recent = new Queue<string>();
        readonly object gate = new object();
        internal readonly HelperEventLog Events;
        internal readonly CoreLogPump Core;
        internal NetHelperLog(string directory)
        {
            file = Path.Combine(directory, "helper.log");
            Events = new HelperEventLog(directory); Core = new CoreLogPump(directory, Events);
            foreach (string path in new[] { file + ".old", file }) {
                if (!File.Exists(path)) continue;
                if (new FileInfo(path).Length > Limit) continue;
                foreach (string line in File.ReadLines(path)) {
                    // Only our fixed categories, timestamps and numeric codes can enter status.
                    if (System.Text.RegularExpressions.Regex.IsMatch(line, @"\A[0-9T:Z.+-]+ stage=[a-z-]+ code=-?[0-9]+(?: type=[A-Za-z0-9]+)?\z")) Remember(line);
                }
            }
        }
        void Remember(string line) { recent.Enqueue(line); while (recent.Count > 50) recent.Dequeue(); }
        internal void Write(string stage, int code) { Write(stage, code, null); }
        internal void Write(string stage, int code, string type)
        {
            string line = DateTime.UtcNow.ToString("o") + " stage=" + stage + " code=" + code.ToString(System.Globalization.CultureInfo.InvariantCulture) + (type == null ? "" : " type=" + type);
            // Тот же факт — в едином формате (helper-events.log), чтобы его видно в серверных журналах.
            Events.Write(code != 0 ? LogLevel.Warn : LogLevel.Info, "helper", "stage", "stage", stage, "code", code.ToString(System.Globalization.CultureInfo.InvariantCulture), "type", type ?? "");
            lock (gate) {
                Remember(line);
                try {
                    if (File.Exists(file) && new FileInfo(file).Length + NetHelperProtocol.Utf8.GetByteCount(line + "\n") > Limit) {
                        if (File.Exists(file + ".old")) File.Delete(file + ".old"); File.Move(file, file + ".old");
                    }
                    File.AppendAllText(file, line + "\n", NetHelperProtocol.Utf8);
                } catch { /* Lease and network shutdown must survive disk failures. */ }
            }
        }
        internal string[] Recent() { lock (gate) return recent.ToArray(); }
    }
#endif
}
