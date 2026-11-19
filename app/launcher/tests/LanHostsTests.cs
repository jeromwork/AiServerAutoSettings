using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;

namespace RemoteAgents.Launcher
{
    // Fake Windows for LanHosts: an in-memory hosts file, a name table instead of SOCKS+DNS, a manual clock.
    internal sealed class FakeHosts : ILanHostsPlatform
    {
        internal byte[] File; internal int Writes, Flushes, Resolves;
        internal Dictionary<string, string[]> Dns = new Dictionary<string, string[]>(); // missing name = DNS failure
        internal string Cache = "";
        internal long Now = 1800000000;
        internal bool WriteFails;
        internal readonly List<string> Logs = new List<string>(), Details = new List<string>();
        readonly object gate = new object();
        static readonly Encoding Latin1 = Encoding.GetEncoding("iso-8859-1");
        internal string Text { get { return File == null ? null : Latin1.GetString(File); } set { File = Latin1.GetBytes(value); } }
        public byte[] ReadHosts() { return File; }
        public void WriteHosts(byte[] content) { if (WriteFails) throw new IOException("locked"); File = content; Writes++; }
        public void FlushDns() { Flushes++; }
        public string[] ResolveA(string dnsServer, string name, int socksPort)
        {
            lock (gate) { Resolves++; string[] ips; if (!Dns.TryGetValue(name, out ips)) throw new IOException("no answer"); return ips; }
        }
        public string LoadCache() { return Cache; }
        public void SaveCache(string json) { Cache = json; }
        public long NowSeconds() { return Now; }
        public void Log(string stage, int code) { lock (gate) Logs.Add(stage); }
        public void Detail(string line) { lock (gate) Details.Add(line); }
    }

    internal static class LanHostsTests
    {
        static int count;
        static void Check(bool condition, string name) { if (!condition) throw new Exception("LanHosts: " + name); count++; }
        static readonly string[] Subnets = { "192.168.87.0/24", "192.168.88.0/21" };
        const string BlockHead = "# RemoteAgents:lan begin - managed by the program, do not edit", BlockEnd = "# RemoteAgents:lan end";

        internal static LanTunNetwork Net(params string[] names)
        {
            return new LanTunNetwork { Name = "clinic", Subnets = Subnets, Domains = new[] { "eastclinic.ru", "*.eastclinic.ru", "eastclinic.local" }, DnsServers = new[] { "192.168.88.11" },
                Hosts = names, TestHost = "192.168.88.244", TestPort = 22 };
        }
        static Dictionary<string, string[]> Connected(LanTunNetwork n) { return new Dictionary<string, string[]> { { n.Name, n.Subnets } }; }
        // Synchronous scheduler: a refresh pass runs inside Tick.
        static LanHosts Make(FakeHosts f, params string[] names)
        {
            var h = new LanHosts(f, a => a()); var n = Net(names);
            h.Configure(new[] { n }, Connected(n), 17880, 0, true);
            return h;
        }
        static int Occurrences(string text, string part) { int c = 0, i = 0; while ((i = text.IndexOf(part, i, StringComparison.Ordinal)) >= 0) { c++; i += part.Length; } return c; }

        static void WritesBlock()
        {
            var f = new FakeHosts { Dns = { { "portal.eastclinic.ru", new[] { "192.168.88.167" } }, { "crm-api.eastclinic.local", new[] { "192.168.88.60", "192.168.88.61" } } } };
            string foreign = "127.0.0.1 localhost\r\n# æ þ comment (cp1251 bytes)\r\n::1 localhost\r\n";
            f.Text = foreign;
            var h = Make(f, "portal.eastclinic.ru", "crm-api.eastclinic.local");
            Check(f.Writes == 0, "nothing written before the first pass");
            h.Tick(0, true);
            string expected = foreign + BlockHead + "\r\n192.168.88.60 crm-api.eastclinic.local # RemoteAgents:clinic\r\n192.168.88.61 crm-api.eastclinic.local # RemoteAgents:clinic\r\n192.168.88.167 portal.eastclinic.ru # RemoteAgents:clinic\r\n" + BlockEnd + "\r\n";
            Check(f.Text == expected, "block between markers at the end, foreign lines byte-exact, CRLF: " + f.Text);
            Check(f.Writes == 1 && f.Flushes == 1, "one write and one DNS cache flush");
            Check(h.Count("clinic") == 2 && h.UpdatedAt == f.Now, "status counts names and update time");
            // LF-only file stays LF; missing file is created; UTF-16 is refused without touching it.
            var lf = new FakeHosts { Dns = { { "portal.eastclinic.ru", new[] { "192.168.88.167" } } } }; lf.Text = "127.0.0.1 localhost\n";
            Make(lf, "portal.eastclinic.ru").Tick(0, true);
            Check(lf.Text.IndexOf('\r') < 0 && lf.Text.StartsWith("127.0.0.1 localhost\n" + BlockHead + "\n", StringComparison.Ordinal), "LF file keeps LF");
            var none = new FakeHosts { Dns = { { "portal.eastclinic.ru", new[] { "192.168.88.167" } } } };
            Make(none, "portal.eastclinic.ru").Tick(0, true);
            Check(none.Text == BlockHead + "\r\n192.168.88.167 portal.eastclinic.ru # RemoteAgents:clinic\r\n" + BlockEnd + "\r\n", "absent hosts file is created with CRLF");
            var wide = new FakeHosts { Dns = { { "portal.eastclinic.ru", new[] { "192.168.88.167" } } }, File = new byte[] { 0xFF, 0xFE, 0x31, 0x00 } };
            Make(wide, "portal.eastclinic.ru").Tick(0, true);
            Check(wide.Writes == 0 && wide.Logs.Contains("hosts-write-failed"), "UTF-16 hosts is not rewritten");
            // A stale block (old address) is replaced, not duplicated.
            f.Dns["portal.eastclinic.ru"] = new[] { "192.168.88.170" };
            h.Tick(700000 + 120000, true);
            Check(Occurrences(f.Text, BlockHead) == 1 && f.Text.Contains("192.168.88.170 portal.eastclinic.ru") && !f.Text.Contains("192.168.88.167") && f.Writes == 2, "changed address rewrites the single block");
        }
        static void NoWriteWhenUnchanged()
        {
            var f = new FakeHosts { Dns = { { "portal.eastclinic.ru", new[] { "192.168.88.167" } } } };
            f.Text = "127.0.0.1 localhost";
            var h = Make(f, "portal.eastclinic.ru");
            h.Tick(0, true); string first = f.Text;
            Check(f.Writes == 1 && f.Resolves == 1, "first pass writes");
            h.Tick(10000, true); Check(f.Resolves == 1, "no new pass before the interval");
            h.Tick(10 * 60000 + 61000, true);
            Check(f.Resolves == 2 && f.Writes == 1 && f.Flushes == 1 && f.Text == first, "refresh with the same answer writes nothing");
            // Nothing of ours and nothing to write: the file is not touched at all.
            var empty = new FakeHosts { Dns = { { "portal.eastclinic.ru", new string[0] } } }; empty.Text = "127.0.0.1 localhost"; // no trailing newline
            Make(empty, "portal.eastclinic.ru").Tick(0, true);
            Check(empty.Writes == 0 && empty.Text == "127.0.0.1 localhost", "no block and nothing adopted means no write");
        }
        static void SkipsPublic()
        {
            var f = new FakeHosts { Dns = { { "eastclinic.ru", new[] { "212.41.27.201" } }, { "www.eastclinic.ru", new[] { "212.41.27.201", "192.168.88.5" } } } };
            f.Text = "127.0.0.1 localhost\r\n";
            Make(f, "eastclinic.ru", "www.eastclinic.ru").Tick(0, true);
            Check(!f.Text.Contains("212.41.27.201") && f.Text.Contains("192.168.88.5 www.eastclinic.ru # RemoteAgents:clinic") && !f.Text.Contains(" eastclinic.ru "), "public address is never written, private one of the same name is");
            Check(f.Details.Any(d => d.StartsWith("hosts-skip public eastclinic.ru 212.41.27.201", StringComparison.Ordinal)) && f.Logs.Contains("hosts-skip-public"), "skip is logged");
            var only = new FakeHosts { Dns = { { "eastclinic.ru", new[] { "212.41.27.201" } } } }; only.Text = "127.0.0.1 localhost\r\n";
            Make(only, "eastclinic.ru").Tick(0, true);
            Check(only.Writes == 0, "only public answer leaves hosts untouched");
            // Subnet check uses the network's own subnets: 10.x of another network is not accepted.
            var other = new FakeHosts { Dns = { { "portal.eastclinic.ru", new[] { "10.1.2.3", "192.168.200.1" } } } }; other.Text = "";
            Make(other, "portal.eastclinic.ru").Tick(0, true);
            Check(other.Writes == 0, "foreign private addresses are not accepted");
        }
        static void AdoptsManual()
        {
            var f = new FakeHosts { Dns = { { "portal.eastclinic.ru", new[] { "192.168.88.167" } } } };
            f.Text = "127.0.0.1 localhost\r\n192.168.88.167 portal.eastclinic.ru\r\n10.0.0.1 other.example.com\r\n";
            Make(f, "portal.eastclinic.ru").Tick(0, true);
            Check(Occurrences(f.Text, "portal.eastclinic.ru") == 1 && f.Text.StartsWith("127.0.0.1 localhost\r\n10.0.0.1 other.example.com\r\n" + BlockHead, StringComparison.Ordinal), "manual line removed, name only in the block, other lines intact: " + f.Text);
            Check(f.Details.Any(d => d == "hosts-adopt 192.168.88.167 portal.eastclinic.ru") && f.Logs.Contains("hosts-adopt"), "adoption is logged");
            // A manual line with a stale address in our subnets is adopted too (the block carries the live one).
            var stale = new FakeHosts { Dns = { { "portal.eastclinic.ru", new[] { "192.168.88.167" } } } }; stale.Text = "192.168.88.99\tportal.eastclinic.ru # old\r\n";
            Make(stale, "portal.eastclinic.ru").Tick(0, true);
            Check(!stale.Text.Contains("88.99") && stale.Text.Contains("192.168.88.167 portal.eastclinic.ru"), "stale manual line adopted");
            // Name that cannot be resolved now keeps the user's bypass.
            var down = new FakeHosts(); down.Text = "192.168.88.167 portal.eastclinic.ru\r\n";
            Make(down, "portal.eastclinic.ru").Tick(0, true);
            Check(down.Writes == 0 && down.Text == "192.168.88.167 portal.eastclinic.ru\r\n", "bypass kept while the name is unresolved");
        }
        static void ConflictUntouched()
        {
            string line = "10.9.9.9 portal.eastclinic.ru\r\n";
            var f = new FakeHosts { Dns = { { "portal.eastclinic.ru", new[] { "192.168.88.167" } }, { "crm.eastclinic.ru", new[] { "192.168.88.70" } } } };
            f.Text = "127.0.0.1 localhost\r\n" + line + "192.168.88.167 portal.eastclinic.ru other.example.com\r\n";
            Make(f, "portal.eastclinic.ru", "crm.eastclinic.ru").Tick(0, true);
            Check(f.Text.Contains(line) && f.Text.Contains("192.168.88.167 portal.eastclinic.ru other.example.com\r\n"), "conflicting lines are untouched");
            string block = f.Text.Substring(f.Text.IndexOf(BlockHead, StringComparison.Ordinal));
            Check(!block.Contains("portal.eastclinic.ru") && block.Contains("192.168.88.70 crm.eastclinic.ru"), "conflicting name is not written, others are");
            Check(f.Details.Count(d => d.StartsWith("hosts-conflict ", StringComparison.Ordinal)) == 2 && f.Logs.Contains("hosts-conflict"), "conflicts are logged");
        }
        static void KeepsLastGood()
        {
            var f = new FakeHosts { Dns = { { "portal.eastclinic.ru", new[] { "192.168.88.167" } } } }; f.Text = "127.0.0.1 localhost\r\n";
            var h = Make(f, "portal.eastclinic.ru"); h.Tick(0, true);
            string good = f.Text; Check(f.Cache.Contains("192.168.88.167"), "last good answer is stored");
            f.Dns.Clear();
            long ms = 11 * 60000; f.Now += ms / 1000; h.Tick(ms, true);
            Check(f.Text == good && f.Writes == 1, "DNS failure keeps the last good value");
            ms = 23L * 3600000; f.Now += ms / 1000; h.Tick(ms, true);
            Check(f.Text == good && f.Writes == 1, "still kept after 23 hours");
            // Service restart: the stored value survives in the cache file.
            var again = new FakeHosts { Cache = f.Cache, Now = f.Now }; again.Text = "127.0.0.1 localhost\r\n";
            Make(again, "portal.eastclinic.ru").Tick(0, true);
            Check(again.Text == good, "cache restored after restart");
            ms = 25L * 3600000; f.Now += 2 * 3600; h.Tick(ms, true);
            Check(f.Text == "127.0.0.1 localhost\r\n" && f.Writes == 2 && f.Logs.Contains("hosts-expired"), "older than 24 hours is dropped from the block");
            Check(!f.Cache.Contains("192.168.88.167"), "expired entry leaves the cache");
            // NXDOMAIN is an answer, not a failure: it removes the name at once.
            var g = new FakeHosts { Dns = { { "portal.eastclinic.ru", new[] { "192.168.88.167" } } } }; g.Text = "";
            var hg = Make(g, "portal.eastclinic.ru"); hg.Tick(0, true);
            g.Dns["portal.eastclinic.ru"] = new string[0]; hg.Tick(11 * 60000, true);
            Check(!g.Text.Contains("portal.eastclinic.ru") && !g.Text.Contains(BlockHead), "no such name removes it immediately");
            // Failed write: retry after 60 s, never an exception to the caller.
            var w = new FakeHosts { Dns = { { "portal.eastclinic.ru", new[] { "192.168.88.167" } } }, WriteFails = true }; w.Text = "";
            var hw = Make(w, "portal.eastclinic.ru"); hw.Tick(0, true);
            Check(w.Writes == 0 && w.Logs.Contains("hosts-write-failed"), "failed write is logged");
            w.WriteFails = false; hw.Tick(30000, true); Check(w.Writes == 0, "no retry before 60 s");
            hw.Tick(61000, true); Check(w.Writes == 1, "retry after 60 s");
        }
        static void RemovalRules()
        {
            var f = new FakeHosts { Dns = { { "portal.eastclinic.ru", new[] { "192.168.88.167" } } } };
            string foreign = "127.0.0.1 localhost\r\n10.0.0.1 other.example.com\r\n"; f.Text = foreign;
            var h = Make(f, "portal.eastclinic.ru"); h.Tick(0, true);
            Check(f.Text.Contains(BlockHead), "block present");
            int writes = f.Writes, resolves = f.Resolves;
            h.Tick(11 * 60000, false); h.Tick(22 * 60000, false);
            Check(f.Writes == writes && f.Resolves == resolves && f.Text.Contains(BlockHead), "channel blip neither refreshes nor removes");
            // An empty name list removes the block (network edited, list emptied).
            var n = Net(); h.Configure(new[] { n }, Connected(n), 17880, 30 * 60000, false);
            Check(f.Text == foreign, "empty list removes the block and keeps foreign lines");
            Check(f.Details.All(d => !d.StartsWith("hosts-adopt", StringComparison.Ordinal)), "removal never adopts");
            // Direct removal (stop, service removal) on a file with an unterminated block.
            var broken = new FakeHosts { Text = "127.0.0.1 localhost\r\n" + BlockHead + "\r\n192.168.88.167 portal.eastclinic.ru # RemoteAgents:clinic\r\n" };
            Check(new LanHosts(broken, a => a()).Remove() && broken.Text == "127.0.0.1 localhost\r\n", "unterminated block is removed up to the last tagged line");
            var clean = new FakeHosts { Text = "127.0.0.1 localhost" }; new LanHosts(clean, a => a()).Remove();
            Check(clean.Writes == 0, "removal without a block does not write");
            var absent = new FakeHosts(); new LanHosts(absent, a => a()).Remove(); Check(absent.Writes == 0 && absent.File == null, "removal without a file does nothing");
        }
        static void NamesValidation()
        {
            var domains = new[] { "eastclinic.ru", "*.eastclinic.local" };
            Check(LanAccess.HostName("Portal.EastClinic.ru", domains) == "portal.eastclinic.ru" && LanAccess.HostName("a.eastclinic.local", domains) == "a.eastclinic.local" && LanAccess.HostName("eastclinic.ru", domains) == "eastclinic.ru", "names under domains (wildcard domain root counts)");
            foreach (string bad in new[] { "*.eastclinic.ru", "portal.example.org", "noteastclinic.ru", "eastclinic.ru.evil.com", "10.0.0.1", "portal", "a b.eastclinic.ru", "" }) {
                bool rejected = false; try { LanAccess.HostName(bad, domains); } catch (InvalidDataException) { rejected = true; }
                Check(rejected, "rejected name: " + bad);
            }
            Func<string[], Dictionary<string, object>> profile = hosts => ConfigBundle.D("lan", new[] { ConfigBundle.D("name", "clinic", "testHost", "192.168.88.244", "testPort", 22,
                "share", ConfigBundle.D("subnets", Subnets, "domains", new[] { "eastclinic.ru", "*.eastclinic.ru" }, "dnsServers", new[] { "192.168.88.11" }, "hosts", hosts)) });
            Check(LanAccess.Read(profile(new[] { "portal.eastclinic.ru" })).Networks.Count == 1, "valid list accepted");
            Func<string[], bool> rejects = hosts => { try { LanAccess.Read(profile(hosts)); return false; } catch (InvalidDataException) { return true; } };
            Check(rejects(new[] { "*.eastclinic.ru" }) && rejects(new[] { "x.example.org" }) && rejects(new[] { "a.eastclinic.ru", "A.eastclinic.ru" }), "wildcards, foreign names, duplicates rejected");
            Check(!rejects(Enumerable.Range(0, 100).Select(i => "h" + i + ".eastclinic.ru").ToArray()) && rejects(Enumerable.Range(0, 101).Select(i => "h" + i + ".eastclinic.ru").ToArray()), "at most 100 names");
            var noDns = profile(new[] { "portal.eastclinic.ru" }); Json.Map(Json.Map(Json.Array(noDns["lan"])[0])["share"])["dnsServers"] = new string[0];
            bool needsDns = false; try { LanAccess.Read(noDns); } catch (InvalidDataException) { needsDns = true; }
            Check(needsDns, "hosts need DNS servers");
        }
        static void RoundTrip()
        {
            string text = "{\"kind\":\"remoteagents-config\",\"schema\":1,\"lan\":[{\"name\":\"clinic\",\"testHost\":\"192.168.88.244\",\"testPort\":22,\"share\":{\"subnets\":[\"192.168.87.0/24\",\"192.168.88.0/21\"],\"domains\":[\"eastclinic.ru\",\"*.eastclinic.ru\"],\"dnsServers\":[\"192.168.88.11\"],\"hosts\":[\"portal.eastclinic.ru\",\"crm-api.eastclinic.ru\"],\"enabled\":true}}]}";
            var bundle = ConfigBundle.Parse(text);
            var access = LanAccess.Read(bundle.Profile);
            Check(Json.Strings(Json.Get(access.Networks[0], "hosts")).SequenceEqual(new[] { "portal.eastclinic.ru", "crm-api.eastclinic.ru" }), "schema accepts share.hosts and LanAccess reads it");
            var request = LanTunNetwork.Request(bundle.Profile, 17880);
            var parsed = LanTunNetwork.Parse(Json.Map(Json.Parse(Json.Encode(request))));
            Check(parsed.Length == 1 && parsed[0].Hosts.SequenceEqual(new[] { "portal.eastclinic.ru", "crm-api.eastclinic.ru" }), "request to the service carries the names and the service parses them");
            // Without names the request keeps the six-key row older services accept.
            string plain = text.Replace(",\"hosts\":[\"portal.eastclinic.ru\",\"crm-api.eastclinic.ru\"]", "");
            var old = Json.Map(Json.Array(Json.Get(LanTunNetwork.Request(ConfigBundle.Parse(plain).Profile, 17880), "networks"))[0]);
            Check(old.Count == 6 && !old.ContainsKey("hosts"), "no names: six keys on the wire");
            bool refused = false; try { ConfigBundle.Parse(text.Replace("portal.eastclinic.ru\",", "*.eastclinic.ru\",")); } catch (InvalidDataException) { refused = true; }
            Check(refused, "wildcard name refused by the config schema");
            refused = false; try { ConfigBundle.Parse(text.Replace("\"enabled\":true", "\"hosts2\":[],\"enabled\":true")); } catch (InvalidDataException) { refused = true; }
            Check(refused, "unknown share keys are still refused");
        }
        static void DnsWire()
        {
            // Hand-built answer: portal.eastclinic.ru CNAME web.eastclinic.ru (compressed), web A 192.168.88.167.
            var q = LanDns.BuildQuery("portal.eastclinic.ru", 0x1234);
            Check(q[0] * 256 + q[1] == q.Length - 2 && q[2] == 0x12 && q[3] == 0x34 && q[4] == 1 && q[5] == 0 && q[q.Length - 4] == 0 && q[q.Length - 3] == 1 && q[q.Length - 1] == 1, "TCP DNS A query framing");
            var good = new List<byte> { 0x12, 0x34, 0x81, 0x80, 0, 1, 0, 2, 0, 0, 0, 0 };
            good.AddRange(q.Skip(14));                   // question: name + type + class, name starts at offset 12
            good.AddRange(new byte[] { 0xC0, 12, 0, 5, 0, 1, 0, 0, 0, 60, 0, 6 });
            int target = good.Count;                     // CNAME rdata: "web" + pointer to "eastclinic.ru" (offset 19)
            good.AddRange(new byte[] { 3, (byte)'w', (byte)'e', (byte)'b', 0xC0, 19 });
            good.AddRange(new byte[] { 0xC0, (byte)target, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 192, 168, 88, 167 });
            var reply = LanDns.ParseReply(good.ToArray(), 0x1234);
            Check(reply.Rcode == 0 && reply.Cname["portal.eastclinic.ru"] == "web.eastclinic.ru" && reply.A.Count == 1 && reply.A[0].Key == "web.eastclinic.ru" && reply.A[0].Value == "192.168.88.167", "CNAME chain and A record parsed with name compression");
            bool bad = false; try { LanDns.ParseReply(good.ToArray(), 0x1111); } catch (InvalidDataException) { bad = true; }
            Check(bad, "answer with another id refused");
            bad = false; try { LanDns.ParseReply(good.Take(good.Count - 3).ToArray(), 0x1234); } catch (InvalidDataException) { bad = true; }
            Check(bad, "truncated answer refused");
        }

        internal static void Run()
        {
            WritesBlock(); NoWriteWhenUnchanged(); SkipsPublic(); AdoptsManual(); ConflictUntouched(); KeepsLastGood(); RemovalRules(); NamesValidation(); RoundTrip(); DnsWire();
            Console.WriteLine("PASS: LanHosts " + count + " checks");
        }

        // Real SOCKS5 + TCP DNS client against servers of the shell test: "--lan-hosts-resolve port user password dnsServer name".
        internal static int Resolve(string[] args)
        {
            try {
                int port = int.Parse(args[1]);
                Func<Stream> connect = () => { var c = new TcpClient(); c.Connect(IPAddress.Loopback, port); return new NetworkStream(c.Client, true); };
                var ips = LanDns.ResolveA(connect, args[2], args[3], args[4], args[5], 3000);
                Console.WriteLine("OK " + string.Join(",", ips));
                return 0;
            } catch (Exception e) { Console.WriteLine("ERR " + e.Message); return 1; }
        }
    }
}
