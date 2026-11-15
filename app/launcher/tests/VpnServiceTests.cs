using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;

namespace RemoteAgents.Launcher
{
    internal static class VpnServiceTests
    {
        const string Sid = "S-1-5-21-1-2-3-1001";
        const string Pinned = "8f30682ee198855440d2a7fe070d5d3653793b2d01bb8c85eea88f93bbe7c8b9";
        static int count; static string fixture;
        static Dictionary<string, object> D(params object[] pairs) { return VpnServicePolicy.Obj(pairs); }
        static Dictionary<string, object> M(object o) { return (Dictionary<string, object>)o; }
        static object[] A(object o) { return ((IEnumerable)o).Cast<object>().ToArray(); }
        static Dictionary<string, object> Config() { return M(Json.Parse(fixture)); }
        static Dictionary<string, object> Out(Dictionary<string, object> c) { return M(A(c["outbounds"])[0]); }
        static Dictionary<string, object> Tun(Dictionary<string, object> c) { return M(A(c["inbounds"])[0]); }
        static Dictionary<string, object> Rule(Dictionary<string, object> c) { return M(A(M(c["route"])["rules"])[0]); }
        static Dictionary<string, object> Selector(Dictionary<string, object> c) { return M(A(c["outbounds"]).Last()); }
        static void Check(bool value, string name) { if (!value) throw new Exception("VpnService: " + name); count++; }
        static void Reject(Action action, string name, string code = null)
        {
            try { action(); } catch (VpnPolicyException e) { Check(code == null || e.Code == code, name + " code " + e.Code); return; }
            throw new Exception("VpnService accepted: " + name);
        }
        static void BadConfig(string name, Action<Dictionary<string, object>> edit, string code = null) { var c = Config(); edit(c); Reject(() => VpnServicePolicy.BuildConfig(c), name, code); }
        static string Find(string relative)
        {
            for (var d = new DirectoryInfo(AppContext.BaseDirectory); d != null; d = d.Parent) { string path = Path.Combine(d.FullName, relative); if (File.Exists(path)) return path; }
            throw new Exception("Missing fixture: " + relative);
        }
        internal static void Run()
        {
            fixture = File.ReadAllText(Find("app/launcher/tests/fixtures/vpn-tun-config.json"));
            Requests(); Configs(); Acls(); Setup(); Orphans(); Diagnostics(); Core(); Console.WriteLine("PASS: " + count + " VPN service checks");
        }
        static void Requests()
        {
            foreach (string command in new[] { "status", "stop", "confirm", "start", "cleanup" }) {
                var r = D("protocol", 1, "command", command); if (command == "confirm") r["session"] = new string('a', 32); if (command == "start") { r["config"] = Config(); r["watchPid"] = 42L; }
                Check(VpnServicePolicy.ParseRequest(r).Command == command, command);
            }
            Reject(() => VpnServicePolicy.ParseRequest(D("protocol", 1, "command", "cleanup", "session", new string('a', 32))), "cleanup extra field");
            foreach (string c in new[] { "exec", "run" }) Reject(() => VpnServicePolicy.ParseRequest(D("protocol", 1, "command", c)), c, "bad-command");
            foreach (string k in new[] { "path", "exe", "args", "script", "config" }) Reject(() => VpnServicePolicy.ParseRequest(D("protocol", 1, "command", "status", k, "secret")), k);
            foreach (object p in new object[] { 2, "1", null, 1.5m, double.NaN }) Reject(() => VpnServicePolicy.ParseRequest(D("protocol", p, "command", "status")), "protocol");
            foreach (object s in new object[] { "", new string('A', 32), "../file", new string('a', 31), new string('a', 32) + "\n", null }) Reject(() => VpnServicePolicy.ParseRequest(D("protocol", 1, "command", "confirm", "session", s)), "session");
            foreach (object pid in new object[] { -1, "1", 1.25m, 1.25d, (long)int.MaxValue + 1 }) Reject(() => VpnServicePolicy.ParseRequest(D("protocol", 1, "command", "start", "watchPid", pid, "config", Config())), "watchPid");
            foreach (object p in new object[] { new object[0], "x", null, 1 }) Reject(() => VpnServicePolicy.ParseRequest(p), "not object");
            foreach (object n in new object[] { 1, 1L, 1m, 1d }) Check(VpnServicePolicy.ParseRequest(D("protocol", n, "command", "start", "watchPid", n, "config", Config())).WatchPid == 1, "numeric variants");
            Reject(() => VpnServicePolicy.ParseRequest(D("protocol", 1, "command", "start", "config", Config())), "missing pid");
            Reject(() => VpnServicePolicy.ParseRequest(D("protocol", 1, "command", "start", "watchPid", 0, "config", new object[0])), "config object");
        }
        static void Configs()
        {
            var input = Config(); Out(input).Remove("bind_interface"); Out(input).Remove("domain_resolver"); var plan = VpnServicePolicy.BuildConfig(input);
            Check(plan.InterfaceName == "RemoteAgents-TUN" && plan.DefaultInterface == "Ethernet" && plan.Selected == "reality-edge", "plan names");
            Check(plan.Config.Keys.OrderBy(x => x).SequenceEqual(new[] { "dns", "inbounds", "log", "outbounds", "route" }), "exact root keys");
            Check((string)Out(plan.Config)["bind_interface"] == "Ethernet" && (string)Out(plan.Config)["domain_resolver"] == "bootstrap", "binding rebuilt");
            Check(Tun(plan.Config).Keys.OrderBy(x => x).SequenceEqual(new[] { "address", "auto_route", "interface_name", "route_exclude_address", "stack", "strict_route", "tag", "type" }), "exact inbound keys");
            Check(M(plan.Config["route"]).Keys.OrderBy(x => x).SequenceEqual(new[] { "auto_detect_interface", "default_domain_resolver", "default_interface", "final", "rules" }), "exact route keys");
            Check(M(plan.Config["dns"]).Keys.OrderBy(x => x).SequenceEqual(new[] { "final", "servers" }), "exact DNS keys");
            Check(Out(plan.Config).Keys.OrderBy(x => x).SequenceEqual(new[] { "bind_interface", "domain_resolver", "flow", "server", "server_port", "tag", "tls", "type", "uuid" }), "exact outbound keys");
            Check(!ReferenceEquals(Out(input)["tls"], Out(plan.Config)["tls"]), "nested objects rebuilt");
            Check(!Json.Encode(plan.Config).Contains("experimental"), "no experimental");
            Check(Json.Encode(plan.Config["log"]) == Json.Encode(D("level", "warn", "timestamp", true)), "service warning log without output");
            var collapsed = Config(); Tun(collapsed)["address"] = "fdfe:7261:0:0::1/126"; Tun(collapsed)["route_exclude_address"] = "10.0.0.0/8"; Rule(collapsed)["ip_cidr"] = "198.18.0.1/32"; Selector(collapsed)["outbounds"] = "reality-edge"; M(Out(collapsed)["tls"])["alpn"] = "h2";
            var rebuilt = VpnServicePolicy.BuildConfig(collapsed).Config; Check(A(Tun(rebuilt)["address"]).Length == 1 && (string)A(Tun(rebuilt)["address"])[0] == "fdfe:7261::1/126", "collapsed/canonical arrays");
            string all = Environment.GetEnvironmentVariable("REMOTEAGENTS_TUN_FIXTURES");
            if (!string.IsNullOrEmpty(all)) { string[] files = Directory.GetFiles(all, "*.json"); Check(files.Length >= 10, "all generated fixtures"); foreach (string f in files) { var c = M(Json.Parse(File.ReadAllText(f))); var p = VpnServicePolicy.BuildConfig(c); Check(p.Config.Count == 5, "generator " + Path.GetFileName(f)); foreach (var o in A(p.Config["outbounds"]).Select(M).Where(o => (string)o["type"] != "selector")) Check(o.ContainsKey("detour") ? !o.ContainsKey("bind_interface") && !o.ContainsKey("domain_resolver") : (string)o["bind_interface"] == p.DefaultInterface, "detour binding"); } }
            BadConfig("experimental", c => c["experimental"] = D());
            BadConfig("log.output", c => M(c["log"])["output"] = "secret");
            BadConfig("route.rule_set", c => M(c["route"])["rule_set"] = new object[0]);
            BadConfig("second inbound", c => c["inbounds"] = new[] { Tun(c), Tun(c) });
            BadConfig("mixed inbound", c => Tun(c)["type"] = "mixed");
            BadConfig("listen", c => Tun(c)["listen"] = "0.0.0.0");
            BadConfig("interface", c => Tun(c)["interface_name"] = "Ethernet");
            foreach (string type in new[] { "ssh", "socks", "direct", "tor", "wireguard", "http", "block", "dns", "urltest" }) BadConfig(type, c => { var o = Out(c); o["type"] = type; if (type == "ssh") o["private_key_path"] = "secret"; if (type == "tor") o["executable_path"] = "secret"; if (type == "socks") o["server"] = "127.0.0.1"; });
            BadConfig("certificate_path", c => M(Out(c)["tls"])["certificate_path"] = "secret", "unknown-field:outbounds[0].tls.certificate_path");
            BadConfig("key_path", c => M(Out(c)["tls"])["key_path"] = "secret");
            BadConfig("utls unknown", c => M(M(Out(c)["tls"])["utls"])["path"] = "secret");
            BadConfig("reality unknown", c => M(M(Out(c)["tls"])["reality"])["path"] = "secret");
            BadConfig("bind mismatch", c => Out(c)["bind_interface"] = "Other");
            BadConfig("resolver mismatch", c => Out(c)["domain_resolver"] = "other");
            BadConfig("interface quote", c => M(c["route"])["default_interface"] = "Ethernet\"bad");
            BadConfig("unknown vless", c => Out(c)["private_key_path"] = "secret");
            foreach (string path in new[] { "/has space", "noslash" }) BadConfig("ws path", c => Out(c)["transport"] = D("type", "ws", "path", path));
            BadConfig("ws headers", c => Out(c)["transport"] = D("type", "ws", "path", "/", "headers", D("Other", "example.com")));
            BadConfig("missing detour", c => Out(c)["detour"] = "missing");
            BadConfig("cycle", c => Out(c)["detour"] = "reality-edge");
            BadConfig("unreachable", c => { var other = M(Json.Parse(Json.Encode(Out(c)))); other["tag"] = "extra"; c["outbounds"] = new[] { Out(c), other, Selector(c) }; });
            BadConfig("two selected", c => Selector(c)["outbounds"] = new[] { "reality-edge", "other" });
            BadConfig("default", c => Selector(c)["default"] = "other");
            foreach (string type in new[] { "local", "dhcp" }) BadConfig("dns " + type, c => M(A(M(c["dns"])["servers"])[0])["type"] = type);
            BadConfig("dns field", c => M(A(M(c["dns"])["servers"])[0])["path"] = "secret");
            foreach (string cidr in new[] { "bad", "10.0.0.0/33", "::/129", "10.0.0.0/-1" }) BadConfig("cidr", c => Tun(c)["address"] = cidr);
            BadConfig("probe mask", c => Rule(c)["ip_cidr"] = "198.18.0.1/24");
            BadConfig("port mismatch", c => Rule(c)["override_port"] = 23);
            BadConfig("uuid", c => Out(c)["uuid"] = "bad");
            BadConfig("ss method", c => c["outbounds"] = new[] { D("type", "shadowsocks", "tag", "reality-edge", "server", "example.com", "server_port", 443, "password", "fake", "method", "none"), Selector(c) });
            BadConfig("password newline", c => c["outbounds"] = new[] { D("type", "trojan", "tag", "reality-edge", "server", "example.com", "server_port", 443, "password", "fake\n"), Selector(c) });
            BadConfig("too many", c => { var outs = new List<object>(); for (int i = 0; i < 9; i++) { var o = M(Json.Parse(Json.Encode(Out(c)))); o["tag"] = "tag" + i; outs.Add(o); } outs.Add(Selector(c)); c["outbounds"] = outs.ToArray(); });
            BadConfig("depth", c => { var outs = new List<object>(); for (int i = 0; i < 5; i++) { var o = M(Json.Parse(Json.Encode(Out(c)))); o["tag"] = i == 0 ? "reality-edge" : "tag" + i; if (i < 4) o["detour"] = "tag" + (i + 1); outs.Add(o); } outs.Add(Selector(c)); c["outbounds"] = outs.ToArray(); });
        }
        static void Acls()
        {
            Check(VpnServiceAcl.PipeSddl(Sid) == "O:SYG:SYD:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;0x12019b;;;" + Sid + ")", "pipe SDDL");
            Check(VpnServiceAcl.ServiceSddl(Sid) == "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;IU)(A;;CCLCSWLOCRRC;;;SU)(A;;LCRP;;;" + Sid + ")S:(AU;FA;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;WD)", "service SDDL");
            Check(VpnServiceAcl.InstallDirectorySddl == "O:BAG:SYD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)", "install ACL");
            Check(VpnServiceAcl.RunDirectorySddl == "O:BAG:SYD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)", "run ACL");
            VpnServiceAcl.ValidateOwnerSid("S-1-12-1-1-2-3-4");
            foreach (string sid in new[] { "S-1-1-0", "S-1-5-32-545", "S-1-5-11", "S-1-5-18", "garbage", Sid + ")(A;;GA;;;WD)", Sid + "\n" }) Reject(() => VpnServiceAcl.ValidateOwnerSid(sid), "sid " + sid);
            string reason; Check(VpnServiceAcl.IsProtectedAcl(new[] { new VpnAce { Sid = "S-1-5-18", Rights = 0x1f01ff, Allow = true }, new VpnAce { Sid = "S-1-5-32-544", Rights = 0x1f01ff, Allow = true }, new VpnAce { Sid = "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464", Rights = 0x1f01ff, Allow = true }, new VpnAce { Sid = "S-1-5-32-545", Rights = 0x1200a9, Allow = true } }, out reason), "protected ACL");
            foreach (var a in new[] { new VpnAce { Sid = "S-1-5-32-545", Rights = 2 }, new VpnAce { Sid = "S-1-1-0", Rights = 0x10000000 }, new VpnAce { Sid = "S-1-5-11", Rights = 0x1301bf }, new VpnAce { Sid = Sid, Rights = 4 } }) { a.Allow = true; Check(!VpnServiceAcl.IsProtectedAcl(new[] { a }, out reason) && reason.Length > 0, "writable ACL"); a.Allow = false; Check(VpnServiceAcl.IsProtectedAcl(new[] { a }, out reason), "deny harmless"); }
        }
        static void Setup()
        {
            Check(VpnServiceNames.InstallDirectory("PF") == Path.Combine("PF", "RemoteAgents", "vpn") && VpnServiceNames.RunDirectory("dir") == Path.Combine("dir", "run") && VpnServiceNames.OwnerFile("dir") == Path.Combine("dir", "owner.json"), "service paths");
            string dir = Path.Combine(Path.GetTempPath(), "Program Files", "RemoteAgents", "vpn"); string command = "\"" + Path.Combine(dir, "RemoteAgentsTun.exe") + "\" --vpn-service";
            Check(VpnServiceSetupPlan.ServiceCommandLine(dir) == command, "quoted SCM command");
            Check(VpnServiceSetupPlan.CreateArguments(dir).SequenceEqual(new[] { "create", "RemoteAgentsTun", "binPath=", command, "start=", "auto", "obj=", "LocalSystem", "DisplayName=", "RemoteAgents VPN (TUN)" }), "create arguments");
            var config = VpnServiceSetupPlan.CreateArguments(dir); config[0] = "config"; Check(VpnServiceSetupPlan.ConfigArguments(dir).SequenceEqual(config), "config arguments");
            Check(VpnServiceSetupPlan.FailureArguments().SequenceEqual(new[] { "failure", "RemoteAgentsTun", "reset=", "86400", "actions=", "restart/5000/restart/5000/restart/60000" }), "failure arguments");
            Check(VpnServiceSetupPlan.SdsetArguments(Sid).SequenceEqual(new[] { "sdset", "RemoteAgentsTun", VpnServiceAcl.ServiceSddl(Sid) }), "sdset");
            Check(VpnServiceSetupPlan.DescriptionArguments().SequenceEqual(new[] { "description", "RemoteAgentsTun", "RemoteAgents VPN (TUN)" }), "description");
            Check(VpnServiceSetupPlan.StopArguments().SequenceEqual(new[] { "stop", "RemoteAgentsTun" }) && VpnServiceSetupPlan.DeleteArguments().SequenceEqual(new[] { "delete", "RemoteAgentsTun" }), "stop/delete");
            Check(VpnServiceSetupPlan.PinnedSingBoxSha256(File.ReadAllText(Find("build/bundle-binaries.json"))) == Pinned, "real binary pin");
            Reject(() => VpnServiceSetupPlan.PinnedSingBoxSha256("{\"binaries\":[]}"), "missing binary");
            var owner = VpnServiceSetupPlan.ParseOwner(Json.Parse(VpnServiceSetupPlan.OwnerJson(Sid, Pinned, Pinned))); Check(owner.OwnerSid == Sid && owner.Protocol == 1 && owner.SingBoxSha256 == Pinned && owner.ExeSha256 == Pinned, "owner roundtrip");
            Reject(() => VpnServiceSetupPlan.ParseOwner(D("protocol", 2, "ownerSid", Sid, "singBoxSha256", Pinned, "exeSha256", Pinned)), "owner protocol");
            Reject(() => VpnServiceSetupPlan.OwnerJson("S-1-1-0", Pinned, Pinned), "owner sid"); Reject(() => VpnServiceSetupPlan.OwnerJson(Sid, "bad", Pinned), "owner hash");
            Reject(() => VpnServiceSetupPlan.ParseOwner(D("protocol", 1, "ownerSid", Sid, "singBoxSha256", Pinned)), "missing owner hash");
            string temp = Path.Combine(Path.GetTempPath(), "vpnsvc-copy-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(temp);
            try {
                byte[] bytes = Encoding.UTF8.GetBytes("test\r\ncontent"); string sha = VpnServiceSetupPlan.Hash(bytes), target = Path.Combine(temp, "test.exe");
                VpnServiceSetupPlan.CopyVerified(bytes, sha, temp, "test.exe"); Check(File.ReadAllBytes(target).SequenceEqual(bytes), "verified content");
                Reject(() => VpnServiceSetupPlan.CopyVerified(bytes, Pinned, temp, "new.exe"), "wrong hash no file"); Check(!File.Exists(Path.Combine(temp, "new.exe")), "no new file");
                Reject(() => VpnServiceSetupPlan.CopyVerified(bytes, Pinned, temp, "test.exe"), "wrong hash old file"); Check(File.ReadAllBytes(target).SequenceEqual(bytes), "old unchanged");
                bytes = Encoding.UTF8.GetBytes("replacement"); VpnServiceSetupPlan.CopyVerified(bytes, VpnServiceSetupPlan.Hash(bytes), temp, "test.exe"); Check(VpnServiceSetupPlan.ReadLimited(target, bytes.Length).SequenceEqual(bytes), "atomic replace/read");
                Reject(() => VpnServiceSetupPlan.ReadLimited(target, 1), "read limit");
                using (var sparse = File.Create(Path.Combine(temp, "large"))) sparse.SetLength(256L * 1024 * 1024 + 1);
                Reject(() => VpnServiceSetupPlan.ReadLimited(Path.Combine(temp, "large"), long.MaxValue), "absolute read cap");
            } finally { Directory.Delete(temp, true); }
        }
        static void Orphans()
        {
            const string dir = @"C:\Program Files\RemoteAgents\vpn", exe = @"C:\Users\owner\RemoteAgents\transport\sing-box.exe", config = @"C:\Users\owner\RemoteAgents\state\vpn-sing-box.json";
            string line = "\"" + exe + "\" run -c \"" + config + "\"";
            Check(VpnServicePolicy.IsLegacyOrphan(exe, line, Sid, Sid, dir), "exact legacy config and owner");
            Check(!VpnServicePolicy.IsLegacyOrphan(exe, line.Replace("vpn-sing-box.json", "config.json"), Sid, Sid, dir), "other config untouched");
            Check(!VpnServicePolicy.IsLegacyOrphan(exe, line, Sid, "S-1-5-21-1-2-3-1002", dir), "other owner untouched");
            foreach (string image in new[] { @"C:\Happ\happ.exe", @"C:\Happ\xray.exe", @"C:\Happ\sing-box.exe" })
                Check(!VpnServicePolicy.IsLegacyOrphan(image, "\"" + image + "\" run -c \"C:\\Happ\\config.json\"", Sid, Sid, dir), "Happ/xray untouched " + image);
            foreach (string bad in new[] { line + " --flag", line + " & calc", line.Replace("vpn-sing-box.json", "vpn-sing-box.json\" \"injected"), line.Replace("state", "..\\state"), line + "\ncalc" })
                Check(!VpnServicePolicy.IsLegacyOrphan(exe, bad, Sid, Sid, dir), "legacy injection rejected");
            Check(VpnServicePolicy.IsInstalledImage(dir + @"\sing-box.exe", dir) && !VpnServicePolicy.IsInstalledImage(@"C:\Happ\sing-box.exe", dir), "installed image exact path");
        }
        static void Diagnostics()
        {
            var config = D("password", "password-fixture", "uuid", "uuid-fixture", "tls", D("public_key", "public-fixture", "short_id", "short-fixture"), "obfs", D("password", "obfs-fixture"), "transport", D("path", "/ws-fixture"));
            var diagnostic = new VpnServiceDiagnostic(config);
            string text = "password-fixture uuid-fixture public-fixture short-fixture obfs-fixture /ws-fixture";
            Check(diagnostic.Redact(text) == "*** *** *** *** *** ***", "all required secret fields");
            Check(diagnostic.Redact("pass\x1b[31mword-fixture") == "***", "ANSI cannot expose a secret");
            var longText = string.Join("\r\n", Enumerable.Range(0, 60).Select(x => x + " " + text));
            string detail = diagnostic.Detail("exit=17; " + longText);
            Check(detail.StartsWith("exit=17; ") && detail.Length <= 2000 && detail.Split('\n').Length <= 40 && !detail.Contains("password-fixture"), "redact before bounded CRLF tail");
            var escaped = new VpnServiceDiagnostic(D("password", "quote\"and\\slash"));
            Check(!escaped.Redact(Json.Encode(D("error", "quote\"and\\slash"))).Contains("quote"), "JSON escaped secret");
            string streamed = new string('x', 65530) + text + new string('y', 1048576) + "\r\n" + text;
            foreach (int size in new[] { 1, 63, 4096, 65536 }) {
                string pending = "", source = size == 1 ? text + text + "\r\n" : streamed; var result = new StringBuilder();
                for (int i = 0; i < source.Length; i += size) { pending += source.Substring(i, Math.Min(size, source.Length - i)); result.Append(diagnostic.TakeOutput(ref pending, false)); if (pending.Length > 64) throw new Exception("Unbounded VPN log overlap"); }
                result.Append(diagnostic.TakeOutput(ref pending, true));
                Check(result.ToString() == diagnostic.Redact(source), "streaming copy preserves/redacts long lines and split secrets " + size);
            }

        }
        sealed class Watch : IVpnProcessWatch { public bool IsAlive = true, Disposed; public bool Alive { get { return IsAlive; } } public void Dispose() { Disposed = true; } }
        sealed class Host : IVpnServiceHost
        {
            public DateTime Now = new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc); public DateTime UtcNow { get { return Now; } }
            public string Hash = Pinned, Checked, Started; public bool Alive, Clean = true, Busy, RejectConfig, Owns = true; public int Stops, Starts, Checks, Cleanups; public Dictionary<int, Watch> Watches = new Dictionary<int, Watch>();
            public string NewSession() { return Guid.NewGuid().ToString("N"); }
            public IVpnProcessWatch Watch(int pid) { if (pid <= 0 || pid == 404) return null; var w = new Watch(); Watches[pid] = w; return w; }
            public bool ProcessOwnedBy(int pid, string sid) { return Owns; } public bool InterfaceExists(string name) { return Busy; } public string InstalledSingBoxSha256() { return Hash; }
            public void CheckConfig(string json) { Checks++; Checked = json; if (RejectConfig) throw new Exception("invalid password=fixture-password uuid=" + Out(M(Json.Parse(json)))["uuid"]); }
            public void StartTun(string json) { Started = json; Starts++; Alive = true; } public bool TunAlive { get { return Alive; } }
            public bool StopTun(string name) { Stops++; Alive = false; return Clean; } public List<string> Logs = new List<string>(); public void Log(string evt) { Logs.Add(evt); }
            public string TunDiagnostic { get { return "exit=23; " + string.Join("\r\n", Enumerable.Range(0, 45).Select(x => "line " + x)) + "\r\npassword fixture-password uuid " + Out(Config())["uuid"]; } }
            public string CleanupDetail { get { return "routes remain on RemoteAgents-TUN"; } }
            public void FlushDiagnostics() { }
            public List<string> Processes = new List<string> { @"C:\Program Files\RemoteAgents\vpn\sing-box.exe", @"C:\Legacy\sing-box.exe", @"C:\Happ\sing-box.exe", @"C:\Happ\xray.exe" };
            public List<string> Interfaces = new List<string> { "RemoteAgents-old", "happ-default-tun", "OpenVPN TAP", "Tailscale", "vEthernet (Default Switch)" };
            public VpnCleanupResult CleanupOrphans(string ownerSid) {
                Cleanups++; var names = Interfaces.Where(VpnServicePolicy.IsOurInterface).ToArray(); Interfaces.RemoveAll(VpnServicePolicy.IsOurInterface);
                int killed = Processes.RemoveAll(image => VpnServicePolicy.IsInstalledImage(image, @"C:\Program Files\RemoteAgents\vpn") || VpnServicePolicy.IsLegacyOrphan(image, "\"" + image + "\" run -c \"C:\\Legacy\\state\\vpn-sing-box.json\"", ownerSid, image.Contains("Legacy") ? Sid : "S-1-5-21-9-8-7-1002", @"C:\Program Files\RemoteAgents\vpn"));
                return new VpnCleanupResult { Processes = killed, Interfaces = names };
            }
        }
        static VpnServiceCore NewCore(Host host) { return new VpnServiceCore(host, new VpnOwnerInfo { OwnerSid = Sid }, Pinned); }
        static Dictionary<string, object> Send(VpnServiceCore c, string command, string session = null, int pid = 42, string sid = Sid, bool admin = false)
        {
            var r = D("protocol", 1, "command", command); if (command == "start") { r["watchPid"] = pid; var config = Config(); Out(config)["type"] = "tuic"; Out(config).Remove("flow"); Out(config)["congestion_control"] = "bbr"; Out(config)["password"] = "fixture-password"; r["config"] = config; } if (session != null) r["session"] = session;
            return M(Json.Parse(c.Handle(Json.Encode(r), 41, sid, admin)));
        }
        static void Core()
        {
            var h = new Host(); var c = NewCore(h); Check((string)Send(c, "status")["state"] == "off", "initial off");
            c.Cleanup("service-start"); Check(h.Cleanups == 1 && h.Interfaces.SequenceEqual(new[] { "happ-default-tun", "OpenVPN TAP", "Tailscale", "vEthernet (Default Switch)" }), "startup cleans only our interfaces/orphans");
            Check(h.Processes.SequenceEqual(new[] { @"C:\Happ\sing-box.exe", @"C:\Happ\xray.exe" }), "cleanup kills only installed and legacy orphans");
            Check(h.Logs.Any(x => x.Contains("processes=2") && x.Contains("RemoteAgents-old")), "cleanup logs counts/names");
            Send(c, "cleanup"); Check(h.Cleanups == 2, "cleanup command dispatched");
            h.Processes.Add(@"C:\Legacy\sing-box.exe");
            var s = Send(c, "start"); string session = (string)s["session"]; Check((string)s["state"] == "starting" && session.Length == 32 && Json.Int(s, "deadlineSec", 0) == 90, "start deadline");
            Check((string)Send(c, "cleanup")["reason"] == "busy" && h.Cleanups == 2 && h.Stops == 0 && h.Processes.Count == 3, "active starting cleanup busy no kills");
            Check(h.Starts == 1 && h.Checks == 1 && h.Started == h.Checked && (string)Out(M(Json.Parse(h.Started)))["bind_interface"] == "Ethernet", "checked rebuilt config");
            h.Now = h.Now.AddSeconds(89); c.Tick(); Check((string)Send(c, "status")["state"] == "starting", "89 alive");
            h.Now = h.Now.AddSeconds(2); c.Tick(); s = Send(c, "status"); Check((string)s["state"] == "rolled-back" && (string)s["reason"] == "not-confirmed" && h.Stops == 1, "91 rollback");
            session = (string)Send(c, "start")["session"]; Check((string)Send(c, "confirm", new string('a', 32))["error"] == "session", "wrong confirm");
            Check((string)Send(c, "confirm", session)["state"] == "on", "confirm on");
            Check((string)Send(c, "cleanup")["reason"] == "busy" && h.Cleanups == 2, "on cleanup busy");
            h.Now = h.Now.AddSeconds(89); c.Tick(); Check((string)Send(c, "status")["state"] == "on", "lease 89 alive");
            Send(c, "confirm", session); h.Now = h.Now.AddSeconds(89); c.Tick(); Check((string)Send(c, "status")["state"] == "on", "confirm extends lease");
            h.Now = h.Now.AddSeconds(2); c.Tick(); s = Send(c, "status"); Check((string)s["reason"] == "lease-expired" && (string)s["state"] == "rolled-back", "lease 91 expires");
            session = (string)Send(c, "start")["session"]; h.Now = h.Now.AddSeconds(91); s = Send(c, "confirm", session); Check((string)s["reason"] == "not-confirmed", "late confirm cannot revive");
            foreach (int pid in new[] { 42, 41 }) { var started = Send(c, "start"); Send(c, "confirm", (string)started["session"]); h.Watches[pid].IsAlive = false; c.Tick(); s = Send(c, "status"); Check((string)s["state"] == "off" && (string)s["reason"] == "owner-exited" && h.Watches.Values.All(w => w.Disposed), "owner death " + pid); }
            Send(c, "start"); h.Alive = false; c.Tick(); s = Send(c, "status"); Check((string)s["state"] == "error" && (string)s["reason"] == "singbox-exited", "binary exits");
            Check(((string)s["detail"]).Contains("exit=23") && ((string)s["detail"]).Contains("***") && !((string)s["detail"]).Contains("fixture-password") && !((string)s["detail"]).Contains((string)Out(Config())["uuid"]), "exit code and redacted tail");
            Check(((string)s["detail"]).Length <= 2000 && ((string)s["detail"]).Split('\n').Length <= 40 && !((string)s["detail"]).Contains("line 0\n"), "bounded diagnostic tail");
            Check(h.Logs.All(x => !x.Contains("fixture-password") && !x.Contains((string)Out(Config())["uuid"])), "service log sanitized");
            Send(c, "start"); h.Clean = false; Check((string)Send(c, "stop")["state"] == "cleanup-error", "cleanup error"); Check(((string)Send(c, "status")["detail"]).Contains("RemoteAgents-TUN") && (string)Send(c, "status")["reason"] == "cleanup-error", "cleanup detail names routes/interface"); h.Clean = true;
            h.Owns = false; Check((string)Send(c, "start")["error"] == "watch-pid", "foreign pid"); h.Owns = true;
            Check((string)Send(c, "start", pid: 404)["error"] == "watch-pid", "missing pid");
            Check((string)Send(c, "status", sid: "S-1-5-21-9-8-7-1002")["error"] == "forbidden", "forbidden"); Check(Json.Bool(Send(c, "status", sid: "S-1-5-18", admin: true), "ok"), "admin allowed");
            h.Hash = new string('0', 64); Check((string)Send(c, "start")["error"] == "binary-mismatch", "binary mismatch"); h.Hash = Pinned;
            h.Busy = true; Check((string)Send(c, "start")["error"] == "interface-busy", "busy interface"); h.Busy = false;
            h.RejectConfig = true; int before = h.Starts; Check((string)Send(c, "start")["error"] == "config-rejected" && h.Starts == before, "check rejected"); s = Send(c, "start"); Check(((string)s["detail"]).Contains("invalid password=***") && !((string)s["detail"]).Contains("fixture-password") && !((string)s["detail"]).Contains((string)Out(Config())["uuid"]), "config-rejected includes redacted check output"); h.RejectConfig = false;
            session = (string)Send(c, "start")["session"]; var oldWatches = h.Watches.Values.ToArray(); before = h.Stops; h.Now = h.Now.AddSeconds(20); s = Send(c, "start");
            Check(h.Stops == before + 1 && (string)s["session"] != session && Json.Int(s, "deadlineSec", 0) == 90 && oldWatches.All(w => w.Disposed), "restart stops/replaces watches/session/deadline");
            Check((string)Send(c, "stop", session)["error"] == "session" && h.Alive, "wrong stop");
            Check((string)Send(c, "stop")["state"] == "off" && (string)Send(c, "status")["session"] == "", "stop clears");
            foreach (string junk in new[] { "", "[]", "{", new string('x', 1048577), "\r\n{\"protocol\":1,\"command\":\"status\"}\r\n", null }) { string answer = c.Handle(junk, 41, Sid, false); Check(!answer.Contains("\n") && M(Json.Parse(answer)).ContainsKey("ok"), "never throws/one line"); }
            Check((string)M(Json.Parse(c.Handle(new string('x', 1048577), 41, Sid, false)))["error"] == "too-large", "oversize code");
            Check((string)M(Json.Parse(c.Handle(new string('中', 400000), 41, Sid, false)))["error"] == "too-large", "UTF8 byte cap");
            Check((string)M(Json.Parse(c.Handle("{", 41, Sid, false)))["error"] == "bad-json", "bad-json code");
            Send(c, "start"); h.Clean = false; h.Now = h.Now.AddSeconds(91); c.Tick(); Check((string)Send(c, "status")["state"] == "cleanup-error", "rollback cleanup fails"); h.Clean = true;
            Send(c, "start"); c.Shutdown(); Check(!h.Alive && h.Watches.Values.All(w => w.Disposed), "shutdown cleans");
            Check((string)Send(c, "start")["error"] == "not-running" && !h.Alive, "shutdown forbids racing restart");
            Check(h.Logs.All(x => !x.Contains("fixture-password") && !x.Contains((string)Out(Config())["uuid"])), "all errors/check logs redact secrets");
        }
    }
}
