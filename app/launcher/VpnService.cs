using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Net.NetworkInformation;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.ServiceProcess;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace RemoteAgents.Launcher
{
    internal static class VpnServiceProgram
    {
        internal static string Image { get { using (var p = Process.GetCurrentProcess()) return p.MainModule.FileName; } }
        internal static string DirectoryName { get { string pf = Environment.GetEnvironmentVariable("ProgramW6432"); return VpnServiceNames.InstallDirectory(string.IsNullOrEmpty(pf) ? Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles) : pf); } }
        internal static string PinnedHash()
        {
            using (var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("RemoteAgents.BundleBinaries.json"))
            using (var r = new StreamReader(s, Encoding.UTF8)) return VpnServiceSetupPlan.PinnedSingBoxSha256(r.ReadToEnd());
        }
        public static bool Handles(string[] args)
        {
            return Path.GetFileName(Image).Equals(VpnServiceNames.ExeName, StringComparison.OrdinalIgnoreCase) || (args.Length > 0 && new[] { "--vpn-service", "--vpn-service-install", "--vpn-service-uninstall" }.Contains(args[0]));
        }
        internal static bool Administrator() { using (var id = WindowsIdentity.GetCurrent()) return new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator); }
        public static int Run(string[] args)
        {
            if (Path.GetFileName(Image).Equals(VpnServiceNames.ExeName, StringComparison.OrdinalIgnoreCase) && (args.Length == 0 || args[0] != "--vpn-service")) return 2;
            try {
                if (args.Length > 0 && args[0] == "--vpn-service") { ServiceBase.Run(new VpnWindowsService()); return 0; }
                if (!Administrator()) return 5;
                if (args[0] == "--vpn-service-install") return Install(args);
                if (args[0] == "--vpn-service-uninstall") { Uninstall(); return 0; }
                return 2;
            } catch { VpnWindowsHost.WriteLog(Path.Combine(DirectoryName, "run", "install.log"), "setup-failed"); return 1; }
        }
        internal static bool Exists()
        {
            var services = ServiceController.GetServices(); try { return services.Any(s => s.ServiceName.Equals(VpnServiceNames.ServiceName, StringComparison.OrdinalIgnoreCase)); } finally { foreach (var s in services) s.Dispose(); }
        }
        public static bool RequestUninstall()
        {
            if (!Exists()) return true;
            try {
                using (var p = Process.Start(new ProcessStartInfo(Image, "--vpn-service-uninstall") { UseShellExecute = true, Verb = "runas", WindowStyle = ProcessWindowStyle.Hidden })) return p.WaitForExit(120000) && p.ExitCode == 0;
            } catch (Win32Exception ex) { if (ex.NativeErrorCode == 1223) return false; throw; }
        }
        static void Sc(string[] args)
        {
            using (var p = Process.Start(new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "sc.exe"), Files.Arguments(args)) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true })) {
                var output = p.StandardOutput.ReadToEndAsync(); var error = p.StandardError.ReadToEndAsync();
                if (!p.WaitForExit(30000)) { p.Kill(); throw new IOException("sc-timeout"); }
                Task.WaitAll(new Task[] { output, error }, 1000); if (p.ExitCode != 0) throw new IOException("sc-failed");
            }
        }
        static void StopInstalled()
        {
            if (!Exists()) return;
            using (var service = new ServiceController(VpnServiceNames.ServiceName)) {
                NativeVpn.ServiceStatus status; int needed;
                Process process = null;
                try {
                    if (!NativeVpn.QueryServiceStatusEx(service.ServiceHandle.DangerousGetHandle(), 0, out status, Marshal.SizeOf(typeof(NativeVpn.ServiceStatus)), out needed)) throw new Win32Exception();
                    if (status.pid != 0) try { process = Process.GetProcessById((int)status.pid); var handle = process.Handle; } catch (ArgumentException) { }
                    if (service.Status != ServiceControllerStatus.Stopped) { if (service.Status != ServiceControllerStatus.StopPending) service.Stop(); service.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(30)); }
                    if (process != null && !process.WaitForExit(30000)) throw new IOException("service-exit-timeout");
                } finally { if (process != null) process.Dispose(); }
            }
        }
        static void SecureDirectory(string dir, string sddl)
        {
            if (Directory.Exists(dir) || File.Exists(dir)) {
                if ((File.GetAttributes(dir) & FileAttributes.ReparsePoint) != 0) { if (Directory.Exists(dir)) Directory.Delete(dir); else File.Delete(dir); }
            }
            Directory.CreateDirectory(dir); var security = new DirectorySecurity(); security.SetSecurityDescriptorSddlForm(sddl); security.SetAccessRuleProtection(true, false); Directory.SetAccessControl(dir, security); CheckDirectory(dir);
        }
        internal static void CheckDirectory(string dir)
        {
            if ((File.GetAttributes(dir) & FileAttributes.ReparsePoint) != 0) throw new IOException("reparse-directory");
            var security = Directory.GetAccessControl(dir); var raw = new RawSecurityDescriptor(security.GetSecurityDescriptorBinaryForm(), 0);
            if (raw.DiscretionaryAcl == null) throw new IOException("null-acl");
            var aces = security.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().Select(a => new VpnAce { Sid = a.IdentityReference.Value, Rights = (int)a.FileSystemRights, Allow = a.AccessControlType == AccessControlType.Allow });
            string reason; if (!VpnServiceAcl.IsProtectedAcl(aces, out reason)) throw new IOException(reason);
        }
        static int Install(string[] args)
        {
            string owner = Program.Option(args, "--owner-sid"); VpnServiceAcl.ValidateOwnerSid(owner);
            // Read untrusted sources once. Only the embedded manifest approves sing-box.
            string pinned = PinnedHash(); var singbox = VpnServiceSetupPlan.ReadLimited(Program.Option(args, "--sing-box"), 256L * 1024 * 1024);
            if (VpnServiceSetupPlan.Hash(singbox) != pinned) throw new VpnPolicyException("binary-mismatch");
            var image = VpnServiceSetupPlan.ReadLimited(Image, 256L * 1024 * 1024); string exeHash = VpnServiceSetupPlan.Hash(image);
            bool exists = Exists(); StopInstalled();
            string dir = DirectoryName, run = VpnServiceNames.RunDirectory(dir);
            SecureDirectory(Path.GetDirectoryName(dir), VpnServiceAcl.InstallDirectorySddl); SecureDirectory(dir, VpnServiceAcl.InstallDirectorySddl);
            // Discard old run files, including explicit file ACLs and reparse links.
            if (Directory.Exists(run) || File.Exists(run)) DeleteTree(run);
            SecureDirectory(run, VpnServiceAcl.RunDirectorySddl);
            // ReplaceFile preserves destination ACLs. Remove old entries before publishing new files.
            foreach (string name in new[] { VpnServiceNames.SingBoxName, VpnServiceNames.ExeName, "owner.json" }) {
                string target = Path.Combine(dir, name);
                if (Directory.Exists(target)) throw new IOException("file-is-directory");
                if (File.Exists(target) || IsReparse(target)) File.Delete(target);
            }
            VpnServiceSetupPlan.CopyVerified(singbox, pinned, dir, VpnServiceNames.SingBoxName);
            VpnServiceSetupPlan.CopyVerified(image, exeHash, dir, VpnServiceNames.ExeName);
            Files.Atomic(VpnServiceNames.OwnerFile(dir), VpnServiceSetupPlan.OwnerJson(owner, pinned, exeHash));
            CheckDirectory(dir); CheckDirectory(run);
            Sc(exists ? VpnServiceSetupPlan.ConfigArguments(dir) : VpnServiceSetupPlan.CreateArguments(dir)); Sc(VpnServiceSetupPlan.DescriptionArguments()); Sc(VpnServiceSetupPlan.FailureArguments()); Sc(VpnServiceSetupPlan.SdsetArguments(owner));
            using (var s = new ServiceController(VpnServiceNames.ServiceName)) { s.Start(); s.WaitForStatus(ServiceControllerStatus.Running, TimeSpan.FromSeconds(30)); }
            VpnWindowsHost.WriteLog(Path.Combine(run, "install.log"), "installed"); return 0;
        }
        static bool IsReparse(string path)
        {
            try { return (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0; }
            catch (FileNotFoundException) { return false; } catch (DirectoryNotFoundException) { return false; }
        }
        static void DeleteTree(string path)
        {
            var attr = File.GetAttributes(path);
            if ((attr & FileAttributes.ReparsePoint) != 0) { if ((attr & FileAttributes.Directory) != 0) Directory.Delete(path); else File.Delete(path); return; }
            if ((attr & FileAttributes.Directory) == 0) { File.SetAttributes(path, FileAttributes.Normal); File.Delete(path); return; }
            foreach (string child in Directory.GetFileSystemEntries(path)) DeleteTree(child); Directory.Delete(path);
        }
        static void DelayDelete(string path)
        {
            var attr = File.GetAttributes(path);
            if ((attr & FileAttributes.Directory) != 0 && (attr & FileAttributes.ReparsePoint) == 0) foreach (string child in Directory.GetFileSystemEntries(path)) DelayDelete(child);
            if (!NativeVpn.MoveFileEx(path, null, 4)) throw new Win32Exception();
        }
        static void Uninstall()
        {
            StopInstalled(); if (Exists()) Sc(VpnServiceSetupPlan.DeleteArguments());
            string dir = DirectoryName; var wait = Stopwatch.StartNew();
            while (Directory.Exists(dir) || File.Exists(dir)) {
                try { DeleteTree(dir); break; } catch (IOException) { } catch (UnauthorizedAccessException) { }
                if (wait.ElapsedMilliseconds >= 10000) { DelayDelete(dir); break; } Thread.Sleep(200);
            }
            string parent = Path.GetDirectoryName(dir); if (Directory.Exists(parent) && !Directory.EnumerateFileSystemEntries(parent).Any()) Directory.Delete(parent);
        }
    }
    internal sealed class VpnWindowsService : ServiceBase
    {
        VpnServiceCore core; VpnWindowsHost host; NamedPipeServerStream pipe; Timer timer; Thread listener; volatile bool stopping;
        public VpnWindowsService() { ServiceName = VpnServiceNames.ServiceName; CanShutdown = true; AutoLog = false; }
        protected override void OnStart(string[] args)
        {
            string dir = Path.GetDirectoryName(VpnServiceProgram.Image);
            try {
                VpnServiceProgram.CheckDirectory(dir); VpnServiceProgram.CheckDirectory(VpnServiceNames.RunDirectory(dir));
                var owner = VpnServiceSetupPlan.ParseOwner(Json.Parse(Encoding.UTF8.GetString(VpnServiceSetupPlan.ReadLimited(VpnServiceNames.OwnerFile(dir), 65536))));
                string pinned = VpnServiceProgram.PinnedHash(); if (owner.SingBoxSha256 != pinned) throw new VpnPolicyException("binary-mismatch");
                host = new VpnWindowsHost(dir); core = new VpnServiceCore(host, owner, pinned); pipe = CreatePipe(owner.OwnerSid);
                stopping = false; listener = new Thread(Listen) { IsBackground = true, Name = "vpn-pipe" }; listener.Start();
                timer = new Timer(_ => core.Tick(), null, 1000, 1000); host.Log("service-started");
            } catch {
                VpnWindowsHost.WriteLog(Path.Combine(dir, "run", "service.log"), "service-start-failed");
                try { EventLog.WriteEntry("Application", "remoteagents-vpn.service-start-failed", EventLogEntryType.Error); } catch { }
                if (pipe != null) pipe.Dispose(); if (core != null) core.Shutdown(); throw;
            }
        }
        static NamedPipeServerStream CreatePipe(string owner)
        {
            IntPtr descriptor; uint size;
            if (!NativeVpn.ConvertStringSecurityDescriptorToSecurityDescriptor(VpnServiceAcl.PipeSddl(owner), 1, out descriptor, out size)) throw new Win32Exception();
            try {
                var sa = new NativeVpn.SecurityAttributes { length = Marshal.SizeOf(typeof(NativeVpn.SecurityAttributes)), descriptor = descriptor };
                var handle = NativeVpn.CreateNamedPipe(@"\\.\pipe\" + VpnServiceNames.PipeName, 0x3 | 0x00080000 | 0x40000000, 0x8, 1, 65536, 65536, 0, ref sa);
                if (handle.IsInvalid) { handle.Dispose(); throw new Win32Exception(); }
                try { return new NamedPipeServerStream(PipeDirection.InOut, true, false, handle); } catch { handle.Dispose(); throw; }
            } finally { NativeVpn.LocalFree(descriptor); }
        }
        void Listen()
        {
            while (!stopping) {
                try {
                    pipe.WaitForConnection(); uint pid;
                    if (!NativeVpn.GetNamedPipeClientProcessId(pipe.SafePipeHandle, out pid) || pid == 0 || pid > int.MaxValue) throw new Win32Exception();
                    // Keep the authenticated process handle open through the request.
                    using (var process = NativeVpn.OpenProcess(0x1000 | 0x100000, false, (int)pid)) {
                        string sid; bool admin; NativeVpn.Identity(process, out sid, out admin);
                        string line, response;
                        try { line = ReadLine(pipe); response = core.Handle(line, (int)pid, sid, admin); }
                        catch (VpnPolicyException ex) { response = Json.Encode(VpnServicePolicy.Obj("ok", false, "protocol", 1, "error", ex.Code)); }
                        catch (DecoderFallbackException) { response = Json.Encode(VpnServicePolicy.Obj("ok", false, "protocol", 1, "error", "bad-json")); }
                        byte[] bytes = new UTF8Encoding(false, true).GetBytes(response + "\n");
                        var write = pipe.WriteAsync(bytes, 0, bytes.Length); if (!write.Wait(10000)) throw new System.TimeoutException();
                        pipe.Flush(); var drain = Task.Run(() => pipe.WaitForPipeDrain()); if (!drain.Wait(2000)) throw new System.TimeoutException();
                    }
                } catch { if (!stopping) host.Log("pipe-request-failed"); }
                finally { try { NativeVpn.CancelIoEx(pipe.SafePipeHandle, IntPtr.Zero); if (pipe.IsConnected) pipe.Disconnect(); } catch { } }
            }
        }
        static string ReadLine(NamedPipeServerStream stream)
        {
            var clock = Stopwatch.StartNew(); using (var result = new MemoryStream()) {
                var buffer = new byte[1];
                while (true) {
                    int remaining = 10000 - (int)clock.ElapsedMilliseconds; if (remaining <= 0) throw new System.TimeoutException();
                    var read = stream.ReadAsync(buffer, 0, 1); if (!read.Wait(remaining)) throw new System.TimeoutException(); if (read.Result == 0) throw new EndOfStreamException();
                    if (buffer[0] == 10) return new UTF8Encoding(false, true).GetString(result.ToArray());
                    if (result.Length >= VpnServicePolicy.MaxRequestBytes) throw new VpnPolicyException("too-large"); result.WriteByte(buffer[0]);
                }
            }
        }
        protected override void OnStop()
        {
            stopping = true; if (timer != null) timer.Dispose(); if (pipe != null) pipe.Dispose(); if (core != null) core.Shutdown(); if (listener != null) listener.Join(12000);
        }
        protected override void OnShutdown() { OnStop(); }
    }
    internal sealed class VpnWindowsHost : IVpnServiceHost
    {
        readonly string dir, run; NativeJob job; Process process;
        static readonly object logGate = new object();
        public VpnWindowsHost(string directory) { dir = directory; run = VpnServiceNames.RunDirectory(dir); }
        public DateTime UtcNow { get { return DateTime.UtcNow; } }
        public string NewSession() { return Guid.NewGuid().ToString("N"); }
        public IVpnProcessWatch Watch(int pid)
        {
            var h = NativeVpn.OpenProcess(0x100000 | 0x1000, false, pid); if (h.IsInvalid) { h.Dispose(); return null; } return new VpnWindowsWatch(h);
        }
        public bool ProcessOwnedBy(int pid, string sid)
        {
            using (var h = NativeVpn.OpenProcess(0x1000, false, pid)) { try { string actual; bool admin; NativeVpn.Identity(h, out actual, out admin); return actual == sid; } catch { return false; } }
        }
        public bool InterfaceExists(string name) { return NetworkInterface.GetAllNetworkInterfaces().Any(n => n.Name.Equals(name, StringComparison.OrdinalIgnoreCase)); }
        public string InstalledSingBoxSha256() { return VpnServiceSetupPlan.Hash(VpnServiceSetupPlan.ReadLimited(Path.Combine(dir, VpnServiceNames.SingBoxName), 256L * 1024 * 1024)); }
        public void CheckConfig(string json)
        {
            string config = Path.Combine(run, "config-check.json"); Files.Atomic(config, json);
            try { using (var checkJob = new NativeJob()) using (var check = checkJob.StartRedirected(Path.Combine(dir, VpnServiceNames.SingBoxName), new[] { "check", "-c", config }, run, Path.Combine(run, "check.out"))) { if (!check.WaitForExit(15000) || check.ExitCode != 0) throw new IOException("config-rejected"); } }
            finally { File.Delete(config); }
        }
        public void StartTun(string json)
        {
            Files.Atomic(Path.Combine(run, "config.json"), json); job = new NativeJob();
            try { process = job.StartRedirected(Path.Combine(dir, VpnServiceNames.SingBoxName), new[] { "run", "-c", Path.Combine(run, "config.json") }, run, Path.Combine(run, "sing-box.out")); } catch { job.Dispose(); job = null; throw; }
        }
        public bool TunAlive { get { return process != null && !process.HasExited; } }
        public bool StopTun(string interfaceName)
        {
            var clock = Stopwatch.StartNew(); bool exited = true;
            if (job != null) { job.Dispose(); job = null; }
            if (process != null) { try { exited = process.WaitForExit(10000); } finally { process.Dispose(); process = null; } }
            while (!string.IsNullOrEmpty(interfaceName) && InterfaceExists(interfaceName)) { if (clock.ElapsedMilliseconds >= 10000) return false; Thread.Sleep(100); }
            if (!exited) return false;
            try { File.Delete(Path.Combine(run, "config.json")); } catch { } return true;
        }
        public void Log(string evt) { WriteLog(Path.Combine(run, "service.log"), evt); }
        internal static void WriteLog(string path, string evt)
        {
            lock (logGate) try {
                if (!System.Text.RegularExpressions.Regex.IsMatch(evt, @"\A[a-z0-9.-]+\z")) return;
                string directory = Path.GetDirectoryName(path);
                VpnServiceProgram.CheckDirectory(Path.GetDirectoryName(directory)); VpnServiceProgram.CheckDirectory(directory);
                if (File.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) return;
                if (File.Exists(path) && new FileInfo(path).Length >= 1048576) { if (File.Exists(path + ".old")) File.Delete(path + ".old"); File.Move(path, path + ".old"); }
                File.AppendAllText(path, DateTime.UtcNow.ToString("o") + " " + evt + "\r\n", new UTF8Encoding(false));
            } catch { }
        }
    }
    internal sealed class VpnWindowsWatch : IVpnProcessWatch
    {
        readonly SafeProcessHandle handle; public VpnWindowsWatch(SafeProcessHandle handle) { this.handle = handle; }
        public bool Alive { get { return NativeVpn.WaitForSingleObject(handle, 0) == 258; } }
        public void Dispose() { handle.Dispose(); }
    }
    internal static class NativeVpn
    {
        [StructLayout(LayoutKind.Sequential)] internal struct SecurityAttributes { public int length; public IntPtr descriptor; public int inherit; }
        [StructLayout(LayoutKind.Sequential)] internal struct ServiceStatus { public uint type, state, accepted, win32Exit, serviceExit, checkPoint, waitHint, pid, flags; }
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string sddl, uint revision, out IntPtr descriptor, out uint size);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern SafePipeHandle CreateNamedPipe(string name, uint access, uint mode, uint instances, uint outSize, uint inSize, uint timeout, ref SecurityAttributes security);
        [DllImport("kernel32.dll")] internal static extern IntPtr LocalFree(IntPtr value);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool CancelIoEx(SafePipeHandle handle, IntPtr overlapped);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe, out uint pid);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern SafeProcessHandle OpenProcess(uint access, bool inherit, int pid);
        [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(SafeProcessHandle process, uint access, out SafeAccessTokenHandle token);
        [DllImport("kernel32.dll")] internal static extern uint WaitForSingleObject(SafeProcessHandle process, uint timeout);
        [DllImport("advapi32.dll", SetLastError = true)] internal static extern bool QueryServiceStatusEx(IntPtr service, int level, out ServiceStatus status, int size, out int needed);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern bool MoveFileEx(string source, string destination, uint flags);
        internal static void Identity(SafeProcessHandle process, out string sid, out bool admin)
        {
            SafeAccessTokenHandle token; if (process.IsInvalid || !OpenProcessToken(process, 8, out token)) throw new Win32Exception();
            using (token) using (var identity = new WindowsIdentity(token.DangerousGetHandle())) { sid = identity.User.Value; admin = sid == "S-1-5-18" || new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator); }
        }
    }
}
