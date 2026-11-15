using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Management;
using System.Text.RegularExpressions;
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
            } catch (Exception ex) {
                string detail = new VpnServiceDiagnostic(null).Detail(ex.GetType().Name + ": " + ex.Message);
                VpnWindowsHost.WriteLog(Path.Combine(DirectoryName, "run", "install.log"), "setup-failed " + detail);
                VpnWindowsHost.WriteLog(Path.Combine(DirectoryName, "logs", "service.log"), "reason=install-service detail=" + detail);
                try { EventLog.WriteEntry("Application", "remoteagents-vpn.install-service " + detail, EventLogEntryType.Error); } catch { }
                return 1;
            }
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
    internal static class VpnServiceClient
    {
        public static void TryCleanup(string home)
        {
            Task.Run(() => {
                try {
                    var clock = Stopwatch.StartNew();
                    if (NativeVpn.ServicePid() == 0 || clock.ElapsedMilliseconds >= 5000) return;
                    using (var pipe = new NamedPipeClientStream(".", VpnServiceNames.PipeName, PipeAccessRights.ReadData | PipeAccessRights.WriteData, PipeOptions.Asynchronous, TokenImpersonationLevel.Identification, HandleInheritability.None)) {
                        pipe.Connect(Math.Max(1, Math.Min(1500, 5000 - (int)clock.ElapsedMilliseconds))); uint server;
                        if (!NativeVpn.GetNamedPipeServerProcessId(pipe.SafePipeHandle, out server) || server == 0 || server != NativeVpn.ServicePid()) return;
                        byte[] request = Encoding.UTF8.GetBytes("{\"protocol\":1,\"command\":\"cleanup\"}\n");
                        if (!pipe.WriteAsync(request, 0, request.Length).Wait(Math.Max(1, 5000 - (int)clock.ElapsedMilliseconds))) return;
                        using (var output = new MemoryStream()) {
                            var b = new byte[1];
                            while (clock.ElapsedMilliseconds < 5000 && output.Length < 65536) {
                                var read = pipe.ReadAsync(b, 0, 1); if (!read.Wait(Math.Max(1, 5000 - (int)clock.ElapsedMilliseconds)) || read.Result == 0) return;
                                if (b[0] == 10) {
                                    var answer = Json.Map(Json.Parse(Encoding.UTF8.GetString(output.ToArray())));
                                    if (Json.Bool(answer, "ok") && !new[] { "starting", "on" }.Contains(Json.Str(answer, "state"))) RepairStatus(home);
                                    return;
                                }
                                output.WriteByte(b[0]);
                            }
                        }
                    }
                } catch { }
            });
        }
        static void RepairStatus(string home)
        {
            home = Path.GetFullPath(home); if (home.Length > Path.GetPathRoot(home).Length) home = home.TrimEnd('\\', '/');
            string hash = VpnServiceSetupPlan.Hash(Encoding.UTF8.GetBytes("VPN\n" + home.ToLowerInvariant().Trim())).Substring(0, 16);
            using (var mutex = new Mutex(false, "RemoteAgents-TUN-" + hash + "-Service")) {
                bool held; try { held = mutex.WaitOne(0); } catch (AbandonedMutexException) { held = true; }
                if (!held) return;
                try {
                    string path = Path.Combine(home, "status", "vpn.json");
                    if (!File.Exists(path) || DateTime.UtcNow - File.GetLastWriteTimeUtc(path) <= TimeSpan.FromSeconds(15)) return;
                    var data = Json.Map(Json.Parse(File.ReadAllText(path)));
                    if (!new[] { "on", "starting", "awaiting-uac" }.Contains(Json.Str(data, "state"))) return;
                    data["ok"] = false; data["enabled"] = false; data["state"] = "off"; data["summary"] = "VPN не работает: прошлый сеанс завершён"; data["updatedAt"] = DateTime.UtcNow.ToString("o");
                    data["step"] = "service-stopped"; data["reason"] = "owner-exited"; data["detail"] = "VPN не работает: прошлый сеанс завершён"; Files.Atomic(path, Json.Encode(data));
                } finally { mutex.ReleaseMutex(); }
            }
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
                host = new VpnWindowsHost(dir); core = new VpnServiceCore(host, owner, pinned); core.Cleanup("service-start"); pipe = CreatePipe(owner.OwnerSid);
                stopping = false; listener = new Thread(Listen) { IsBackground = true, Name = "vpn-pipe" }; listener.Start();
                timer = new Timer(_ => core.Tick(), null, 1000, 1000); host.Log("service-started");
            } catch (Exception ex) {
                string detail = new VpnServiceDiagnostic(null).Detail(ex.GetType().Name + ": " + ex.Message);
                VpnWindowsHost.WriteLog(Path.Combine(dir, "logs", "service.log"), "reason=service-start-failed detail=" + detail);
                try { EventLog.WriteEntry("Application", "remoteagents-vpn.service-start-failed " + detail, EventLogEntryType.Error); } catch { }
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
                        catch (VpnPolicyException ex) { response = Json.Encode(VpnServicePolicy.Obj("ok", false, "protocol", 1, "error", ex.Code, "reason", ex.Code, "detail", ex.Code)); }
                        catch (DecoderFallbackException) { response = Json.Encode(VpnServicePolicy.Obj("ok", false, "protocol", 1, "error", "bad-json", "reason", "bad-json", "detail", "Invalid UTF-8 request")); }
                        byte[] bytes = new UTF8Encoding(false, true).GetBytes(response + "\n");
                        var write = pipe.WriteAsync(bytes, 0, bytes.Length); if (!write.Wait(10000)) throw new System.TimeoutException();
                        pipe.Flush(); var drain = Task.Run(() => pipe.WaitForPipeDrain()); if (!drain.Wait(2000)) throw new System.TimeoutException();
                    }
                } catch (Exception ex) { if (!stopping) host.Log("reason=pipe-request-failed detail=" + ex.GetType().Name + ": " + ex.Message); }
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
        VpnServiceDiagnostic diagnostic = new VpnServiceDiagnostic(null);
        DateTime lastFlush; long outputPosition; string outputPending = "", cleanupDetail = ""; bool captureActive; Decoder outputDecoder = Encoding.UTF8.GetDecoder();
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
        static string ReadTail(string path)
        {
            if (!File.Exists(path)) return "";
            using (var f = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
                long start = Math.Max(0, f.Length - 1048576); f.Position = start;
                using (var reader = new StreamReader(f, Encoding.UTF8)) {
                    string text = reader.ReadToEnd(); if (start > 0) { int newline = text.IndexOf('\n'); text = newline < 0 ? "[oversized diagnostic line omitted]" : text.Substring(newline + 1); }
                    return text;
                }
            }
        }
        public void CheckConfig(string json)
        {
            diagnostic = new VpnServiceDiagnostic(Json.Parse(json));
            string config = Path.Combine(run, "config-check.json"), output = Path.Combine(run, "check.out"); File.Delete(output); Files.Atomic(config, json);
            try {
                using (var checkJob = new NativeJob()) using (var check = checkJob.StartRedirected(Path.Combine(dir, VpnServiceNames.SingBoxName), new[] { "check", "-c", config }, run, output, true)) {
                    if (!check.WaitForExit(15000)) { checkJob.Dispose(); check.WaitForExit(1000); throw new IOException("timeout 15s; " + diagnostic.Detail(ReadTail(output))); }
                    if (check.ExitCode != 0) throw new IOException("exit=" + check.ExitCode + "; " + diagnostic.Detail(ReadTail(output)));
                }
            } finally {
                try { long position = 0; string pending = ""; var decoder = Encoding.UTF8.GetDecoder(); CopyOutput(output, ref position, ref pending, decoder, true); }
                finally { File.Delete(config); }
            }
        }
        public void StartTun(string json)
        {
            diagnostic = new VpnServiceDiagnostic(Json.Parse(json)); outputPosition = 0; outputPending = ""; captureActive = false; outputDecoder = Encoding.UTF8.GetDecoder(); lastFlush = DateTime.MinValue;
            Files.Atomic(Path.Combine(run, "config.json"), json); job = new NativeJob();
            try { process = job.StartRedirected(Path.Combine(dir, VpnServiceNames.SingBoxName), new[] { "run", "-c", Path.Combine(run, "config.json") }, run, Path.Combine(run, "sing-box.out"), true); captureActive = true; } catch { job.Dispose(); job = null; throw; }
        }
        public bool TunAlive { get { return process != null && !process.HasExited; } }
        public string TunDiagnostic { get { return "exit=" + (process != null && process.HasExited ? process.ExitCode.ToString() : "unknown") + "; " + diagnostic.Detail(ReadTail(Path.Combine(run, "sing-box.out"))); } }
        public string CleanupDetail { get { return cleanupDetail; } }
        void Publish(string text)
        {
            text = diagnostic.Redact(text);
            WriteLog(Path.Combine(dir, "logs", "sing-box.log"), text); WriteLog(Path.Combine(dir, "logs", "service.log"), text);
        }
        void CopyOutput(string path, ref long position, ref string pending, Decoder decoder, bool force)
        {
            if (!File.Exists(path)) return;
            using (var f = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
                f.Position = position; byte[] bytes = new byte[65536]; char[] chars = new char[Encoding.UTF8.GetMaxCharCount(bytes.Length)];
                long budget = force ? f.Length - position : Math.Min(1048576, f.Length - position);
                while (budget > 0) {
                    int count = f.Read(bytes, 0, (int)Math.Min(bytes.Length, budget)); if (count == 0) break; budget -= count; position += count;
                    pending += new string(chars, 0, decoder.GetChars(bytes, 0, count, chars, 0));
                    string safe = diagnostic.TakeOutput(ref pending, false); if (safe.Length > 0) Publish(safe);
                }
                if (force) { string safe = diagnostic.TakeOutput(ref pending, true); if (safe.Length > 0) Publish(safe); }
            }
        }
        void Flush(bool force)
        {
            // Never publish a previous service run with the new run's redaction context.
            if (!captureActive || (!force && (UtcNow - lastFlush).TotalSeconds < 5)) return;
            lastFlush = UtcNow;
            CopyOutput(Path.Combine(run, "sing-box.out"), ref outputPosition, ref outputPending, outputDecoder, force);
        }
        public void FlushDiagnostics() { Flush(false); }
        bool RemoveRoutes(string name)
        {
            if (!VpnServicePolicy.IsOurInterface(name)) throw new VpnPolicyException("interface-name");
            // No caller-supplied script. The validated alias cannot contain quotes or operators.
            string command = "$ErrorActionPreference='Stop'; Get-NetRoute -InterfaceAlias '" + name + "' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction Stop; if(@(Get-NetRoute -InterfaceAlias '" + name + "' -ErrorAction SilentlyContinue).Count){ Get-NetRoute -InterfaceAlias '" + name + "' -ErrorAction SilentlyContinue | ForEach-Object { 'remaining-route '+$_.InterfaceAlias+' '+$_.DestinationPrefix+' next-hop='+$_.NextHop }; exit 2}";
            using (var routeJob = new NativeJob()) using (var p = routeJob.StartRedirected(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe"), new[] { "-NoProfile", "-NonInteractive", "-Command", command }, run, Path.Combine(run, "cleanup.out"), true)) {
                bool done = p.WaitForExit(5000); if (!done) { routeJob.Dispose(); p.WaitForExit(1000); }
                if (!done || p.ExitCode != 0) { cleanupDetail = "routes " + name + ": " + (done ? "exit=" + p.ExitCode : "timeout 5s") + "; " + diagnostic.Detail(ReadTail(Path.Combine(run, "cleanup.out"))); return false; }
                return true;
            }
        }
        public bool StopTun(string interfaceName)
        {
            var clock = Stopwatch.StartNew(); bool exited = true, routes = true; cleanupDetail = "";
            if (job != null) { job.Dispose(); job = null; }
            if (process != null) {
                try {
                    exited = process.WaitForExit(1000);
                    try { Flush(true); } catch (Exception ex) { Log("reason=diagnostic-read-failed detail=" + ex.GetType().Name); }
                } catch (Exception ex) { exited = false; cleanupDetail = "sing-box wait: " + ex.GetType().Name; }
                finally { captureActive = false; process.Dispose(); process = null; }
            }
            if (!string.IsNullOrEmpty(interfaceName) && InterfaceExists(interfaceName)) {
                try { routes = RemoveRoutes(interfaceName); } catch (Exception ex) { routes = false; cleanupDetail = "routes " + interfaceName + ": " + ex.GetType().Name + ": " + ex.Message; }
            }
            while (!string.IsNullOrEmpty(interfaceName) && InterfaceExists(interfaceName)) {
                if (clock.ElapsedMilliseconds >= 10000) { cleanupDetail += "; interface remains: " + interfaceName; return false; } Thread.Sleep(100);
            }
            if (!exited) cleanupDetail += "; sing-box did not exit";
            try { File.Delete(Path.Combine(run, "config.json")); } catch { }
            return exited && routes;
        }
        public VpnCleanupResult CleanupOrphans(string ownerSid)
        {
            var result = new VpnCleanupResult(); var errors = new List<string>();
            foreach (var p in Process.GetProcessesByName("sing-box")) using (p) {
                try {
                    var pinned = p.Handle; string image; using (var handle = new SafeProcessHandle(pinned, false)) image = NativeVpn.ImagePath(handle); bool ours = VpnServicePolicy.IsInstalledImage(image, dir);
                    if (!ours) {
                        using (var handle = new SafeProcessHandle(pinned, false)) {
                            string sid; bool admin; NativeVpn.Identity(handle, out sid, out admin);
                            using (var item = new ManagementObject("Win32_Process.Handle='" + p.Id + "'")) {
                                item.Get(); DateTime created = ManagementDateTimeConverter.ToDateTime((string)item["CreationDate"]).ToUniversalTime();
                                if (Math.Abs((p.StartTime.ToUniversalTime() - created).TotalSeconds) < 1)
                                    ours = VpnServicePolicy.IsLegacyOrphan(image, item["CommandLine"] as string, ownerSid, sid, dir);
                            }
                        }
                    }
                    if (ours) { using (var handle = new SafeProcessHandle(pinned, false)) if (!NativeVpn.TerminateProcess(handle, 1)) throw new Win32Exception(); if (!p.WaitForExit(1000)) errors.Add("orphan-exit-timeout pid=" + p.Id); else result.Processes++; }
                } catch (InvalidOperationException) { } catch (ArgumentException) { }
                catch (Exception ex) { errors.Add("orphan-inspection pid=" + p.Id + " " + ex.GetType().Name); }
            }
            result.Interfaces = NetworkInterface.GetAllNetworkInterfaces().Select(n => n.Name).Where(VpnServicePolicy.IsOurInterface).ToArray();
            foreach (string name in result.Interfaces) try { if (!StopTun(name)) errors.Add(CleanupDetail); } catch (Exception ex) { errors.Add("routes/interface " + name + " " + ex.GetType().Name); }
            result.Clean = errors.Count == 0; result.Detail = string.Join("; ", errors); return result;
        }
        public void Log(string evt) { WriteLog(Path.Combine(dir, "logs", "service.log"), diagnostic.Redact(evt)); }
        internal static void WriteLog(string path, string evt)
        {
            lock (logGate) try {
                string directory = Path.GetDirectoryName(path);
                VpnServiceProgram.CheckDirectory(Path.GetDirectoryName(directory)); Directory.CreateDirectory(directory); VpnServiceProgram.CheckDirectory(directory);
                if (File.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) return;
                for (int offset = 0; offset < evt.Length; offset += 100000) {
                    string entry = DateTime.UtcNow.ToString("o") + " " + evt.Substring(offset, Math.Min(100000, evt.Length - offset)) + "\r\n";
                    if (File.Exists(path) && new FileInfo(path).Length + Encoding.UTF8.GetByteCount(entry) > 1048576) { if (File.Exists(path + ".old")) File.Delete(path + ".old"); File.Move(path, path + ".old"); }
                    File.AppendAllText(path, entry, new UTF8Encoding(false));
                }
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
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint pid);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool TerminateProcess(SafeProcessHandle process, uint code);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern SafeProcessHandle OpenProcess(uint access, bool inherit, int pid);
        [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(SafeProcessHandle process, uint access, out SafeAccessTokenHandle token);
        [DllImport("kernel32.dll")] internal static extern uint WaitForSingleObject(SafeProcessHandle process, uint timeout);
        [DllImport("advapi32.dll", SetLastError = true)] internal static extern bool QueryServiceStatusEx(IntPtr service, int level, out ServiceStatus status, int size, out int needed);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern bool MoveFileEx(string source, string destination, uint flags);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr OpenSCManager(string machine, string database, uint access);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr OpenService(IntPtr manager, string name, uint access);
        [DllImport("advapi32.dll")] static extern bool CloseServiceHandle(IntPtr handle);
        internal static uint ServicePid()
        {
            // ServiceController.ServiceHandle may request more access than the owner has.
            IntPtr manager = OpenSCManager(null, null, 1); if (manager == IntPtr.Zero) return 0;
            try {
                IntPtr service = OpenService(manager, VpnServiceNames.ServiceName, 4); if (service == IntPtr.Zero) return 0;
                try { ServiceStatus status; int needed; return QueryServiceStatusEx(service, 0, out status, Marshal.SizeOf(typeof(ServiceStatus)), out needed) ? status.pid : 0; }
                finally { CloseServiceHandle(service); }
            } finally { CloseServiceHandle(manager); }
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool QueryFullProcessImageName(SafeProcessHandle process, uint flags, StringBuilder path, ref int size);
        internal static string ImagePath(SafeProcessHandle process)
        { var path = new StringBuilder(32768); int size = path.Capacity; if (!QueryFullProcessImageName(process, 0, path, ref size)) throw new Win32Exception(); return path.ToString(); }
        internal static void Identity(SafeProcessHandle process, out string sid, out bool admin)
        {
            SafeAccessTokenHandle token; if (process.IsInvalid || !OpenProcessToken(process, 8, out token)) throw new Win32Exception();
            using (token) using (var identity = new WindowsIdentity(token.DangerousGetHandle())) { sid = identity.User.Value; admin = sid == "S-1-5-18" || new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator); }
        }
    }
}
