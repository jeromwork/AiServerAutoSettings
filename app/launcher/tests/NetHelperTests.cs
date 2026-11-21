using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.ExceptionServices;
using System.Text;

namespace RemoteAgents.Launcher
{
    internal static class NetHelperTests
    {
        static int count;
        static void Check(bool condition, string name) { if (!condition) throw new Exception("NetHelper: " + name); count++; }
        sealed class Job : IDisposable
        {
            readonly Action close;
            internal Job(Action close) { this.close = close; }
            public void Dispose() { close(); }
        }
        static bool BadFrame(byte[] data)
        {
            try { using (var stream = new MemoryStream(data)) new NetHelperProtocol.Reader(stream).ReadLine().GetAwaiter().GetResult(); return false; }
            catch (InvalidDataException) { return true; }
        }
        internal static void Run()
        {
            NetHelperVersionTests.Run();
            HelperBusTests.Run();
            PinnedBinary();
            NetHelperSetupTests.Run();
            string parsed;
            foreach (string command in new[] { "status", "ping", "lan.stop", "vpn.off" }) {
                Check(NetHelperProtocol.TryCommand(Json.Encode(new { cmd = command }), out parsed) && parsed == command, "valid " + command);
                if (command.Contains(".")) Check(NetHelperProtocol.Reply(Json.Encode(new { cmd = command }), () => new string[0]).Contains("not-implemented"), "command without executor is inert");
            }
            Check(NetHelperProtocol.TryCommand(" { \"cmd\" : \"ping\" }\r\n", out parsed) && parsed == "ping", "CRLF and JSON whitespace");
            Check(NetHelperProtocol.TryCommand("{\"c\\u006dd\":\"p\\u0069ng\"}", out parsed) && parsed == "ping", "escaped JSON strings");
            foreach (string invalid in new[] { "{\"cmd\":\"lan.apply\"}", "{\"cmd\":\"vpn.on\"}", null, "", "{}", "[]", "null", "true", "\"ping\"", "{\"cmd\":null}", "{\"cmd\":1}", "{\"cmd\":true}", "{\"cmd\":[]}", "{\"cmd\":{}}", "{\"cmd\":\"PING\"}", "{\"cmd\":\"unknown\"}", "{\"cmd\":\"ping\",\"extra\":0}", "{\"path\":\"C:\\\\bad\"}", "{\"cmd\":\"ping\",\"cmd\":\"status\"}", "{\"cmd\":\"ping\",\"c\\u006dd\":\"status\"}", "{\"cmd\":\"ping\",}", "{cmd:'ping'}", "{\"cmd\":\"ping\"}{}", "/*x*/{\"cmd\":\"ping\"}", "{\"cmd\":\"pi\nng\"}", "{\"cmd\":\"\\q\"}", "{\"cmd\":\"ping\"", "{\"cmd\":\"ping\"}\u0000" }) {
                Check(!NetHelperProtocol.TryCommand(invalid, out parsed), "reject invalid command");
                Check(NetHelperProtocol.Reply(invalid, () => { throw new Exception("must not execute"); }) == NetHelperProtocol.BadRequest, "invalid request executes nothing");
            }
            string exact = "{\"cmd\":\"ping\"}".PadRight(NetHelperProtocol.MaxMessageBytes, ' ');
            Check(NetHelperProtocol.TryCommand(exact, out parsed), "64 KiB accepted");
            Check(!NetHelperProtocol.TryCommand(exact + " ", out parsed), "over 64 KiB rejected");
            Check(!NetHelperProtocol.TryCommand("{\"cmd\":\"" + new string('я', 33000) + "\"}", out parsed), "size measured in UTF8 bytes");
            using (var stream = new MemoryStream(Encoding.UTF8.GetBytes(exact + "\r\n{\"cmd\":\"status\"}\n"))) {
                var reader = new NetHelperProtocol.Reader(stream);
                Check(reader.ReadLine().GetAwaiter().GetResult() == exact, "bounded reader accepts CRLF at limit");
                Check(reader.ReadLine().GetAwaiter().GetResult() == "{\"cmd\":\"status\"}", "preserves buffered next message");
                Check(reader.ReadLine().GetAwaiter().GetResult() == null, "clean EOF disconnect");
            }
            Check(BadFrame(Encoding.UTF8.GetBytes(exact + " \n")), "oversized frame");
            Check(BadFrame(Encoding.UTF8.GetBytes(exact + "\rX\n")), "extra CR cannot evade limit");
            Check(BadFrame(Encoding.UTF8.GetBytes("{\"cmd\":\"ping\"}")), "partial EOF is not a message");
            Check(BadFrame(new byte[] { 0xc3, 0x28, 10 }), "invalid UTF8");
            int logReads = 0;
            var status = Json.Map(Json.Parse(NetHelperProtocol.Reply("{\"cmd\":\"status\"}", () => { logReads++; return new[] { "stage=connected code=0" }; })));
            Check(Json.Bool(status, "ok") && Json.Str(status, "helperVersion") == NetHelperInstall.HelperVersion && Json.Strings(Json.Get(status, "log")).Length == 1 && logReads == 1, "status carries version and diagnostics");
            // Both features share the status frame but keep independent enabled states.
            foreach (bool vpnEnabled in new[] { false, true }) {
                var combined = Json.Map(Json.Parse(NetHelperProtocol.Status(() => new string[0],
                    new { enabled = !vpnEnabled, networks = new[] { new { name = "office", state = "ok" } } },
                    new { enabled = vpnEnabled, state = vpnEnabled ? "on" : "off" })));
                var lan = Json.Map(Json.Get(combined, "lan"));
                var vpn = Json.Map(Json.Get(combined, "vpn"));
                Check(Json.Bool(lan, "enabled") == !vpnEnabled && Json.Array(Json.Get(lan, "networks")).Length == 1 &&
                    Json.Bool(vpn, "enabled") == vpnEnabled && Json.Str(vpn, "state") == (vpnEnabled ? "on" : "off") &&
                    Json.Str(combined, "helperVersion") == NetHelperInstall.HelperVersion, "combined status preserves independent LAN/VPN states and version");
            }
            Check(NetHelperProtocol.Reply("{\"cmd\":\"ping\"}", () => { throw new Exception(); }).Contains("pong"), "ping does not read logs");

            long now = 7000; var calls = new List<string>();
            var life = new NetHelperLifetime(() => now, () => calls.Add("cleanup"), () => calls.Add("stop"));
            life.AddJob(new Job(() => calls.Add("job-lan"))); life.AddJob(new Job(() => calls.Add("job-vpn")));
            life.Connected(); now += 90000;
            Check(!life.ConnectionExpired, "connected owner has no idle timeout");
            life.Shutdown(); life.Shutdown();
            Check(string.Join(",", calls) == "job-lan,job-vpn,cleanup,stop", "client disconnect closes ALL jobs before cleanup/stop, once");
            calls.Clear();
            life = new NetHelperLifetime(() => now, () => calls.Add("cleanup"), () => calls.Add("stop"));
            life.AddJob(new Job(() => { calls.Add("job-failed"); throw new IOException(); }));
            life.AddJob(new Job(() => calls.Add("job-next"))); life.Shutdown();
            Check(string.Join(",", calls) == "job-failed,job-next,cleanup,stop", "failed Job does not prevent other closes");
            calls.Clear(); now = 100;
            life = new NetHelperLifetime(() => now, () => calls.Add("cleanup"), () => calls.Add("stop"));
            now += 29999; Check(!life.ConnectionExpired, "before connection deadline"); now++;
            Check(life.ConnectionExpired, "30 seconds without owner");
            if (life.ConnectionExpired) life.Shutdown();
            Check(string.Join(",", calls) == "cleanup,stop", "fake clock deadline stops service");
            bool rejected = false;
            try { life.AddJob(new Job(() => calls.Add("late-job"))); } catch (ObjectDisposedException) { rejected = true; }
            Check(rejected && calls.Last() == "late-job", "late launch is disposed after shutdown");
            calls.Clear();
            life = new NetHelperLifetime(() => 0, () => { calls.Add("cleanup"); throw new IOException(); }, () => calls.Add("stop"));
            life.AddJob(new Job(() => calls.Add("job")));
            try { life.Shutdown(); } catch (IOException) { }
            Check(string.Join(",", calls) == "job,cleanup,stop", "cleanup failure still stops SCM");

            const string sid = "S-1-5-21-123-456-789-1001";
            string sddl = NetHelperInstall.ServiceSddl(sid);
            Check(sddl.EndsWith("(A;;RPWPLCLORC;;;" + sid + ")", StringComparison.Ordinal) && sddl.Contains(";;;SY)") && sddl.Contains(";;;BA)"), "standard service SDDL plus owner start/stop/query rights");
            foreach (string badSid in new[] { "", "S-1-5-21-1)(A;;GA;;;WD)", "S-1-5-21-1\n", "S-1-5-4294967296", "S-1-281474976710656-1" }) {
                bool failed = false; try { NetHelperInstall.ServiceSddl(badSid); } catch (ArgumentException) { failed = true; } Check(failed, "reject SDDL injection/overflow");
            }
            string exe = @"C:\Program Files\RemoteAgents\Helper\RemoteAgents.exe", home = @"C:\Users\Имя Фамилия\RemoteAgents\";
            string[] create = NetHelperInstall.CreateArguments(exe, home, sid);
            Check(create[0] == "create" && create[1] == "RemoteAgentsNet" && create[2] == "binPath=", "SCM creation arguments");
            Check(create[3] == Files.Quote(exe) + " " + Files.Arguments(new[] { "--net-helper-service", "--home", home, "--owner-sid", sid }), "quoted service command including spaced home and trailing slash");
            Check(string.Join("|", create.Skip(4)) == "start=|demand|obj=|LocalSystem|DisplayName=|RemoteAgents: локальные сети и VPN", "demand LocalSystem service");
            Check(NetHelperInstall.CreateArguments(exe, home, sid, true)[0] == "config", "upgrade configures existing service");
            Check(string.Join("|", NetHelperInstall.FailureArguments()) == "failure|RemoteAgentsNet|reset=|60|actions=|", "no SCM restarts");
            Check(!NetHelperInstall.NeedsInstall(NetHelperInstall.HelperVersion + "\r\n"), "matching version has no UAC");
            Check(NetHelperInstall.NeedsInstall("2"), "stage 4/5 helper requires combined protocol upgrade");
            Check(NetHelperInstall.NeedsInstall(null) && NetHelperInstall.NeedsInstall("") && NetHelperInstall.NeedsInstall("old"), "missing or invalid version requires install");
            Console.WriteLine("PASS: NetHelper " + count + " checks (no service/UAC)");
        }
        static void PinnedBinary()
        {
            string root = Path.Combine(Path.GetTempPath(), "ra-helper-pin-" + Guid.NewGuid().ToString("N"));
            try {
                string old = Path.Combine(root, "bundle", "20261118.1"), current = Path.Combine(root, "bundle", "20261119.1");
                Directory.CreateDirectory(Path.Combine(old, "transport")); Directory.CreateDirectory(current);
                byte[] image = Encoding.UTF8.GetBytes("pinned fixture"); string hash = PinnedTransport.Hash(image);
                string source = Path.Combine(old, "transport", "sing-box.exe"), stable = Path.Combine(root, "transport-bin", "sing-box.exe");
                File.WriteAllBytes(source, image);
                var verified = PinnedTransport.ReadVerified(root, current, hash);
                Check(verified.SequenceEqual(image), "OTA without binary falls back to a verified historical bundle");
                File.WriteAllText(source, "swapped after verification");
                Check(verified.SequenceEqual(image), "elevated installation retains the bytes hashed, never reopens the source");
                bool rejected = false; try { PinnedTransport.ReadVerified(root, current, hash); } catch (InvalidDataException) { rejected = true; }
                Check(rejected && !File.Exists(stable), "hash mismatch never installs a file");
                File.WriteAllBytes(source, image);
                Check(PinnedTransport.Restore(root, current, hash, null) == "restored" && File.ReadAllBytes(stable).SequenceEqual(image), "OTA restores absent transport-bin from a verified older bundle");
                File.WriteAllText(stable, "tampered stable");
                Check(PinnedTransport.ReadVerified(root, current, hash).SequenceEqual(image), "tampered stable is not trusted; verified fallback still works");
                File.Delete(source);
                using (var memory = new MemoryStream()) {
                    using (var zip = new System.IO.Compression.ZipArchive(memory, System.IO.Compression.ZipArchiveMode.Create, true))
                    using (var entry = zip.CreateEntry(PinnedTransport.Target).Open()) entry.Write(image, 0, image.Length);
                    memory.Position = 0;
                    Check(PinnedTransport.Restore(root, current, hash, memory) == "restored" && File.ReadAllBytes(stable).SequenceEqual(image), "embedded initial bundle repairs transport-bin after OTA");
                }
                Directory.CreateDirectory(Path.Combine(current, "build"));
                File.WriteAllText(Path.Combine(current, "build", "bundle-binaries.json"), Json.Encode(new { binaries = new[] { new { target = PinnedTransport.Target, memberSha256 = hash } } }));
                Check(PinnedTransport.ExpectedHash != hash, "user-writable bundle pins cannot replace the EXE trust anchor");
                File.Delete(stable); rejected = false;
                try { PinnedTransport.ReadVerified(root, current, hash); } catch (FileNotFoundException) { rejected = true; }
                Check(rejected, "missing binary reports an actionable error");
                Check(PinnedTransport.ExpectedHash.Length == 64, "pin comes from the EXE resource");
                string safe = TickFailureLog.HelperFailure("connect", new IOException("password=NEVER-LOG /private/path", new System.ComponentModel.Win32Exception(5, "secret")));
                Check(safe == "helper.failed stage=connect type=Win32Exception code=5", "diagnostics unwrap native error, preserve stage/type/code, omit all messages");
            } finally { Directory.Delete(root, true); }
        }
        // Keep the existing private portable entry point and all its command modes unchanged.
        static int Main(string[] args)
        {
            if (args.Length >= 1 && args[0] == "--net-helper-stage1") {
                Run();
                if (args.Length == 3) NetHelperSetupTests.FullExe(args[1], args[2]);
                return 0;
            }
            if (args.Length == 1 && args[0] == "--net-helper") { Run(); return 0; }
            if (args.Length == 0 || !args[0].StartsWith("--", StringComparison.Ordinal)) { Run(); VpnTunTests.Run(args.Length == 0 ? Path.GetTempPath() : args[0]); }
            try { return (int)typeof(TestEntry).GetMethod("Main", BindingFlags.Static | BindingFlags.NonPublic).Invoke(null, new object[] { args }); }
            catch (TargetInvocationException ex) { ExceptionDispatchInfo.Capture(ex.InnerException).Throw(); throw; }
        }
    }
}
