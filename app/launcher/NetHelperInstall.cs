using System;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
#if !PORTABLE_TEST
using System.Diagnostics;
using System.Security.AccessControl;
using System.Security.Principal;
using System.ServiceProcess;
using System.Threading;
#endif

namespace RemoteAgents.Launcher
{
    // свой код только как обвязка над SCM и sing-box
    internal static class NetHelperInstall
    {
        // NetHelperVersionTests (LanTests in app/launcher/tests/run.sh --full) checks the version/source SHA-256 pin.
        // It detects source changes without a pin update, but cannot decide whether HelperVersion must increase.
        // Reviewers must bump HelperVersion for every change to installed service behavior, then update the pin.
        internal const string HelperVersion = "13";
        internal const string ServiceName = "RemoteAgentsNet";
        internal const string DisplayName = "RemoteAgents: локальные сети и VPN";
        internal static bool NeedsInstall(string installed)
        { int version; return !int.TryParse((installed ?? "").Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out version) || version < int.Parse(HelperVersion, CultureInfo.InvariantCulture); }
        // The service EXE is compatible by HelperVersion, not by the launcher's changing OTA hash.
        // Still require its presence and verify the privileged transport against the EXE's trusted pin.
        internal static bool ImagesMatch(string directory, string expectedTransportHash)
        {
            try {
                return File.Exists(Path.Combine(directory, "RemoteAgents.exe")) &&
                    Files.Hash(Path.Combine(directory, "sing-box.exe")) == expectedTransportHash;
            } catch (IOException) { return false; }
            catch (UnauthorizedAccessException) { return false; }
        }
        internal static string ValidateSid(string sid)
        {
            if (!Regex.IsMatch(sid ?? "", @"\AS-1-[0-9]+(?:-[0-9]+){1,15}\z", RegexOptions.CultureInvariant)) throw new ArgumentException("Недопустимый SID");
            string[] parts = sid.Split('-'); ulong authority;
            if (!ulong.TryParse(parts[2], NumberStyles.None, CultureInfo.InvariantCulture, out authority) || authority > 0xffffffffffff) throw new ArgumentException("Недопустимый SID");
            foreach (string part in parts.Skip(3)) { uint number; if (!uint.TryParse(part, NumberStyles.None, CultureInfo.InvariantCulture, out number)) throw new ArgumentException("Недопустимый SID"); }
            return sid;
        }
        internal static string ServiceSddl(string sid)
        {
            return "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;IU)(A;;CCLCSWLOCRRC;;;SU)(A;;RPWPLCLORC;;;" + ValidateSid(sid) + ")";
        }
        internal static string[] ServiceArguments(string home, string sid)
        { return new[] { "--net-helper-service", "--home", home, "--owner-sid", ValidateSid(sid) }; }
        internal static string[] CreateArguments(string exe, string home, string sid, bool existing = false)
        {
            if (string.IsNullOrWhiteSpace(exe) || string.IsNullOrWhiteSpace(home) || exe.Any(char.IsControl) || home.Any(char.IsControl)) throw new ArgumentException("Недопустимый путь");
            return new[] { existing ? "config" : "create", ServiceName, "binPath=", Files.Quote(exe) + " " + Files.Arguments(ServiceArguments(home, sid)), "start=", "demand", "obj=", "LocalSystem", "DisplayName=", DisplayName };
        }
        internal static string[] FailureArguments() { return new[] { "failure", ServiceName, "reset=", "60", "actions=", "" }; }
#if !PORTABLE_TEST
        internal static string InstallDirectory { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "RemoteAgents", "Helper"); } }
        internal static string DataDirectory { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "RemoteAgents", "Helper"); } }
        internal static string InstalledVersion { get { try { return File.ReadAllText(Path.Combine(InstallDirectory, "version.txt")).Trim(); } catch { return ""; } } }
        internal static bool IsCurrent { get { return !NeedsInstall(InstalledVersion) && Exists() && ImagesMatch(InstallDirectory, PinnedTransport.ExpectedHash); } }
        internal static bool IsAdministrator { get { using (var identity = WindowsIdentity.GetCurrent()) return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator); } }
        internal static bool Exists()
        {
            using (var controller = new ServiceController(ServiceName)) {
                try { var status = controller.Status; return true; }
                catch (InvalidOperationException ex) { var error = ex.InnerException as System.ComponentModel.Win32Exception; if (error != null && error.NativeErrorCode == 1060) return false; throw; }
            }
        }
        internal static void StopService()
        {
            if (!Exists()) return;
            using (var controller = new ServiceController(ServiceName)) {
                if (controller.Status == ServiceControllerStatus.Stopped) return;
                if (controller.Status != ServiceControllerStatus.StopPending) controller.Stop();
                controller.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(20));
            }
        }
        internal static int Install(string[] args)
        {
            if (!IsAdministrator) return 5;
            string home = Path.GetFullPath(Program.Option(args, "--home") ?? throw new ArgumentException("Нет home"));
            string sid = new SecurityIdentifier(ValidateSid(Program.Option(args, "--owner-sid"))).Value;
            // The unprivileged client names its installed bundle, never a path in a pipe command.
            string bundle = Path.GetFullPath(Program.Option(args, "--helper-bundle") ?? throw new ArgumentException("Нет бандла"));
            byte[] image = PinnedTransport.ReadVerified(home, bundle, PinnedTransport.ExpectedHash);
            bool existing = Exists(); StopService();
            SecureDirectory(InstallDirectory); SecureDirectory(DataDirectory);
            string version = Path.Combine(InstallDirectory, "version.txt");
            if (File.Exists(version)) File.Delete(version); // A failed installation must never claim this version.
            CopyImage(Program.Exe, Path.Combine(InstallDirectory, "RemoteAgents.exe"));
            CopyImage(() => File.WriteAllBytes(Path.Combine(InstallDirectory, "sing-box.exe"), image));
            Sc(CreateArguments(Path.Combine(InstallDirectory, "RemoteAgents.exe"), home, sid, existing));
            Sc(new[] { "sdset", ServiceName, ServiceSddl(sid) });
            Sc(FailureArguments());
            // SYSTEM/Administrators can write; Users can only read the executable and marker.
            using (var service = new ServiceController(ServiceName)) {
                service.Start();
                service.WaitForStatus(ServiceControllerStatus.Running, TimeSpan.FromSeconds(20));
            }
            File.WriteAllText(version, HelperVersion + "\n", NetHelperProtocol.Utf8);
            return 0;
        }
        internal static int Uninstall()
        {
            if (!IsAdministrator) return 5;
            if (Path.GetFullPath(Program.Exe).StartsWith(InstallDirectory + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new IOException("Удалите помощник из основной программы");
            StopService();
            if (Exists()) Sc(new[] { "delete", ServiceName });
            RemoveNrpt();
            try { WindowsLanHosts.RemoveBlock(); } catch { /* A busy hosts file must not block removal; the block only maps private LAN names. */ }
            // Run this command from the program's EXE, never the service image being removed.
            DeleteDirectory(InstallDirectory); DeleteDirectory(DataDirectory);
            return 0;
        }
        static void CopyImage(string source, string destination)
        { CopyImage(() => File.Copy(source, destination, true)); }
        static void CopyImage(Action copy)
        {
            // SCM may report STOPPED just before the service process releases its image.
            var clock = Stopwatch.StartNew();
            while (true) {
                try { copy(); return; }
                catch (IOException ex) {
                    int code = ex.HResult & 0xffff;
                    if ((code != 32 && code != 33 && code != 1224) || clock.ElapsedMilliseconds >= 5000) throw;
                    Thread.Sleep(100);
                }
            }
        }
        static void DeleteDirectory(string path)
        {
            if (!Directory.Exists(path)) return;
            RejectReparse(path);
            foreach (string entry in Directory.GetFileSystemEntries(path)) {
                if ((File.GetAttributes(entry) & FileAttributes.ReparsePoint) != 0) throw new IOException("Небезопасный файл помощника");
                if (Directory.Exists(entry)) DeleteDirectory(entry);
                else File.Delete(entry);
            }
            Directory.Delete(path);
        }
        internal static void RejectReparse(string path)
        {
            for (var current = new DirectoryInfo(path); current != null; current = current.Parent)
                if (current.Exists && (current.Attributes & FileAttributes.ReparsePoint) != 0) throw new IOException("Небезопасный каталог помощника");
        }
        internal static void SecureDirectory(string path)
        {
            RejectReparse(path);
            // Protect the product parent too: ProgramData normally permits users to create directories.
            string parent = Path.GetDirectoryName(path);
            if (!Directory.Exists(parent)) Directory.CreateDirectory(parent);
            var parentAcl = Directory.GetAccessControl(parent);
            var owner = (SecurityIdentifier)parentAcl.GetOwner(typeof(SecurityIdentifier));
            if (owner.Value != "S-1-5-18" && owner.Value != "S-1-5-32-544") throw new IOException("Каталог помощника принадлежит другому пользователю");
            SetDirectoryAcl(parent, path == InstallDirectory);
            if (Directory.Exists(path)) {
                var existingOwner = (SecurityIdentifier)Directory.GetAccessControl(path).GetOwner(typeof(SecurityIdentifier));
                if (existingOwner.Value != "S-1-5-18" && existingOwner.Value != "S-1-5-32-544") throw new IOException("Каталог помощника принадлежит другому пользователю");
            }
            Directory.CreateDirectory(path); RejectReparse(path);
            SetDirectoryAcl(path, path == InstallDirectory);
            // Do not trust files planted in a previous unprotected directory.
            foreach (string file in Directory.GetFileSystemEntries(path))
                if ((File.GetAttributes(file) & FileAttributes.ReparsePoint) != 0) throw new IOException("Небезопасный файл помощника");
        }
        static void SetDirectoryAcl(string path, bool readable)
        {
            var acl = new DirectorySecurity(); acl.SetAccessRuleProtection(true, false);
            var system = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
            var admins = new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);
            acl.SetOwner(admins);
            foreach (var sid in new[] { system, admins }) acl.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            if (readable) acl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null), FileSystemRights.ReadAndExecute, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            Directory.SetAccessControl(path, acl);
        }
        static void Sc(string[] args) { RunSystem("sc.exe", args, 20000); }
        internal static void RemoveNrpt()
        {
            RunSystem(@"WindowsPowerShell\v1.0\powershell.exe", new[] { "-NoProfile", "-NonInteractive", "-Command", "$ErrorActionPreference='Stop'; Get-DnsClientNrptRule | Where-Object { $_.Comment -like 'RemoteAgents:*' } | Remove-DnsClientNrptRule -Force" }, 5000);
        }
        static void RunSystem(string name, string[] args, int timeout)
        {
            using (var job = new NativeJob())
            using (var process = job.Start(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), name), args, Environment.GetFolderPath(Environment.SpecialFolder.System))) {
                if (!process.WaitForExit(timeout)) throw new IOException("Время операции помощника истекло");
                if (process.ExitCode != 0) throw new IOException("Операция помощника: код " + process.ExitCode.ToString(CultureInfo.InvariantCulture));
            }
        }
#endif
    }
}
