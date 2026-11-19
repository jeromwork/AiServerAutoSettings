using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
#if !PORTABLE_TEST
using System.Runtime.InteropServices;
#endif

namespace RemoteAgents.Launcher
{
    // Result of a TCP connect to a LAN DNS server on port 53 (through our TUN). Another VPN client with DNS
    // protection (Happ) answers WSAEACCES (10013) for every process but its own.
    internal enum LanDnsProbe { Open, Denied, Unknown }

    // Everything that touches Windows (hosts file, DNS cache, SOCKS connection, state files) is behind this
    // interface so the block logic can be tested on Linux.
    internal interface ILanHostsPlatform
    {
        byte[] ReadHosts();                                   // null: the file does not exist
        void WriteHosts(byte[] content);                      // atomic replace; keeps hosts.ra-orig (once) and hosts.ra-bak
        void FlushDns();
        string[] ResolveA(string dnsServer, string name, int socksPort); // IPv4 texts; empty = no such name; throws on failure
        string LoadCache();                                   // "" when absent
        void SaveCache(string json);
        long NowSeconds();                                    // UTC, unix seconds
        void Log(string stage, int code);                     // helper.log: fixed category and number only
        void Detail(string line);                             // lan-hosts.log: free text without secrets
    }

    // Minimal SOCKS5 (RFC 1928/1929) + DNS over TCP (RFC 1035) client. Only A records and CNAME chains.
    internal static class LanDns
    {
        internal const int MaxChain = 8;
        static void Fill(Stream stream, byte[] buffer, int count, Stopwatch clock, int budgetMs)
        {
            int offset = 0;
            while (offset < count) {
                int left = budgetMs - (int)clock.ElapsedMilliseconds;
                if (left <= 0) throw new TimeoutException("истекло время ожидания");
                if (stream.CanTimeout) stream.ReadTimeout = left;
                int n = stream.Read(buffer, offset, count - offset);
                if (n <= 0) throw new EndOfStreamException("соединение закрыто");
                offset += n;
            }
        }
        static byte[] Read(Stream stream, int count, Stopwatch clock, int budgetMs) { var b = new byte[count]; Fill(stream, b, count, clock, budgetMs); return b; }
        static void Send(Stream stream, byte[] data, Stopwatch clock, int budgetMs)
        {
            if (stream.CanTimeout) stream.WriteTimeout = Math.Max(1, budgetMs - (int)clock.ElapsedMilliseconds);
            stream.Write(data, 0, data.Length); stream.Flush();
        }
        internal static void Socks5Connect(Stream stream, string user, string password, string host, int port, Stopwatch clock, int budgetMs)
        {
            byte[] u = Encoding.UTF8.GetBytes(user ?? ""), p = Encoding.UTF8.GetBytes(password ?? "");
            if (u.Length > 255 || p.Length > 255) throw new IOException("SOCKS: слишком длинные учётные данные");
            Send(stream, new byte[] { 5, 1, 2 }, clock, budgetMs);
            var method = Read(stream, 2, clock, budgetMs);
            if (method[0] != 5 || method[1] == 0xFF) throw new IOException("SOCKS: метод входа не принят");
            if (method[1] == 2) {
                var auth = new List<byte> { 1, (byte)u.Length }; auth.AddRange(u); auth.Add((byte)p.Length); auth.AddRange(p);
                Send(stream, auth.ToArray(), clock, budgetMs);
                var verdict = Read(stream, 2, clock, budgetMs);
                if (verdict[1] != 0) throw new IOException("SOCKS: неверный логин или пароль");
            } else if (method[1] != 0) throw new IOException("SOCKS: неподдерживаемый метод входа");
            IPAddress ip;
            if (!IPAddress.TryParse(host, out ip) || ip.AddressFamily != AddressFamily.InterNetwork) throw new ArgumentException("SOCKS: нужен IPv4");
            var request = new List<byte> { 5, 1, 0, 1 }; request.AddRange(ip.GetAddressBytes()); request.Add((byte)(port >> 8)); request.Add((byte)port);
            Send(stream, request.ToArray(), clock, budgetMs);
            var head = Read(stream, 4, clock, budgetMs);
            if (head[0] != 5) throw new IOException("SOCKS: неверный ответ");
            if (head[1] != 0) throw new IOException("SOCKS: сервер отказал в соединении (код " + head[1] + ")");
            int tail = head[3] == 1 ? 6 : head[3] == 4 ? 18 : head[3] == 3 ? Read(stream, 1, clock, budgetMs)[0] + 2 : -1;
            if (tail < 0) throw new IOException("SOCKS: неверный тип адреса");
            Read(stream, tail, clock, budgetMs);
        }
        internal static byte[] BuildQuery(string name, int id)
        {
            var q = new List<byte> { (byte)(id >> 8), (byte)id, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0 };
            foreach (string label in name.TrimEnd('.').Split('.')) {
                var bytes = Encoding.ASCII.GetBytes(label);
                if (bytes.Length == 0 || bytes.Length > 63) throw new ArgumentException("DNS: неверное имя");
                q.Add((byte)bytes.Length); q.AddRange(bytes);
            }
            q.AddRange(new byte[] { 0, 0, 1, 0, 1 });
            var framed = new byte[q.Count + 2]; framed[0] = (byte)(q.Count >> 8); framed[1] = (byte)q.Count; q.CopyTo(framed, 2);
            return framed;
        }
        internal sealed class Reply
        {
            internal int Rcode;
            internal readonly List<KeyValuePair<string, string>> A = new List<KeyValuePair<string, string>>();
            internal readonly Dictionary<string, string> Cname = new Dictionary<string, string>();
        }
        static string Name(byte[] m, ref int p)
        {
            var labels = new List<string>(); int jumps = 0, pos = p; bool jumped = false;
            while (true) {
                if (pos >= m.Length) throw new InvalidDataException("DNS: обрыв имени");
                int len = m[pos];
                if (len == 0) { pos++; break; }
                if ((len & 0xC0) == 0xC0) {
                    if (pos + 1 >= m.Length || ++jumps > 16) throw new InvalidDataException("DNS: неверная ссылка");
                    int target = ((len & 0x3F) << 8) | m[pos + 1];
                    if (!jumped) p = pos + 2;
                    jumped = true; pos = target; continue;
                }
                if (len > 63 || pos + 1 + len > m.Length) throw new InvalidDataException("DNS: неверная метка");
                labels.Add(Encoding.ASCII.GetString(m, pos + 1, len).ToLowerInvariant()); pos += 1 + len;
            }
            if (!jumped) p = pos;
            return string.Join(".", labels);
        }
        static int U16(byte[] m, int p) { if (p + 2 > m.Length) throw new InvalidDataException("DNS: обрыв"); return (m[p] << 8) | m[p + 1]; }
        internal static Reply ParseReply(byte[] m, int id)
        {
            if (m.Length < 12 || U16(m, 0) != id || (m[2] & 0x80) == 0) throw new InvalidDataException("DNS: неверный ответ");
            var reply = new Reply { Rcode = m[3] & 0x0F };
            int questions = U16(m, 4), answers = U16(m, 6), p = 12;
            for (int i = 0; i < questions; i++) { Name(m, ref p); p += 4; }
            for (int i = 0; i < answers; i++) {
                string owner = Name(m, ref p);
                int type = U16(m, p), length = U16(m, p + 8), data = p + 10;
                if (data + length > m.Length) throw new InvalidDataException("DNS: обрыв записи");
                if (type == 1 && length == 4) reply.A.Add(new KeyValuePair<string, string>(owner, m[data] + "." + m[data + 1] + "." + m[data + 2] + "." + m[data + 3]));
                else if (type == 5) { int q = data; reply.Cname[owner] = Name(m, ref q); }
                p = data + length;
            }
            return reply;
        }
        // One TCP DNS query through SOCKS5. budgetMs covers connect, handshake and answer.
        static Reply Query(Func<Stream> connect, string user, string password, string dnsServer, string name, int budgetMs)
        {
            var clock = Stopwatch.StartNew();
            int id = new Random().Next(1, 65535);
            using (var stream = connect()) {
                Socks5Connect(stream, user, password, dnsServer, 53, clock, budgetMs);
                Send(stream, BuildQuery(name, id), clock, budgetMs);
                var size = Read(stream, 2, clock, budgetMs);
                int length = (size[0] << 8) | size[1];
                if (length < 12) throw new InvalidDataException("DNS: короткий ответ");
                return ParseReply(Read(stream, length, clock, budgetMs), id);
            }
        }
        // IPv4 texts for the name, CNAME chain followed up to MaxChain steps; empty array when the name has no A record.
        internal static string[] ResolveA(Func<Stream> connect, string user, string password, string dnsServer, string name, int budgetMs)
        {
            string current = name.ToLowerInvariant().TrimEnd('.'); int hops = 0;
            while (true) {
                var reply = Query(connect, user, password, dnsServer, current, budgetMs);
                if (reply.Rcode == 3) return new string[0];
                if (reply.Rcode != 0) throw new IOException("DNS: код ответа " + reply.Rcode);
                string at = current;
                while (true) {
                    var found = reply.A.Where(r => r.Key == at).Select(r => r.Value).ToArray();
                    if (found.Length > 0) return found;
                    string next;
                    if (!reply.Cname.TryGetValue(at, out next)) break;
                    if (++hops > MaxChain) throw new IOException("DNS: слишком длинная цепочка CNAME");
                    at = next;
                }
                if (at == current) return new string[0];
                current = at;
            }
        }
    }

    // Keeps one block of "ip name" lines in the Windows hosts file for the explicitly listed LAN names.
    // Names come from the profile (share.hosts), addresses from the LAN DNS over our SOCKS channel; only
    // addresses inside the network's own subnets are ever written.
    internal sealed class LanHosts
    {
        internal const string BeginPrefix = "# RemoteAgents:lan begin", EndPrefix = "# RemoteAgents:lan end";
        internal const string Begin = BeginPrefix + " - managed by the program, do not edit", End = EndPrefix;
        internal const long CacheSeconds = 24 * 3600, RefreshMs = 600000, RetryMs = 60000;
        internal const int MaxParallel = 4, QueryMs = 3000;
        static readonly Encoding Latin1 = Encoding.GetEncoding("iso-8859-1"); // byte-exact round trip of foreign lines

        sealed class Spec { internal string Net; internal string[] Subnets, Dns, Names; }
        sealed class Entry { internal string Net, Name, Ip; }
        sealed class Cached { internal string[] Ips; internal long At; }

        readonly ILanHostsPlatform platform;
        readonly Action<Action> run;
        readonly object gate = new object(), fileGate = new object();
        readonly int jitterMs = new Random().Next(-60000, 60000);
        Spec[] specs = new Spec[0];
        string specKey = "";
        int port, generation;
        bool dirty, busy;
        long next;
        Dictionary<string, Cached> cache;
        readonly Dictionary<string, int> counts = new Dictionary<string, int>();
        long updated;

        internal LanHosts(ILanHostsPlatform platform, Action<Action> run) { this.platform = platform; this.run = run; }

        // Called by LanTun when networks or their connected subnets change (force on every lan.apply).
        internal void Configure(LanTunNetwork[] networks, Dictionary<string, string[]> connected, int socksPort, long now, bool force)
        {
            var wanted = networks.Where(n => n.Hosts.Length > 0 && n.DnsServers.Length > 0 && connected.ContainsKey(n.Name) && connected[n.Name].Length > 0)
                .Select(n => new Spec { Net = n.Name, Subnets = connected[n.Name], Names = n.Hosts, Dns = n.DnsServers.Where(d => connected[n.Name].Any(s => LanTun.Contains(s, LanAccess.IPv4(d)))).ToArray() })
                .Where(s => s.Dns.Length > 0).ToArray();
            string key = Json.Encode(new object[] { socksPort, wanted.Select(s => new object[] { s.Net, s.Subnets, s.Dns, s.Names }).ToArray() });
            lock (gate) {
                if (!force && key == specKey) return;
                specKey = key; specs = wanted; port = socksPort; generation++; dirty = true; next = now;
            }
            if (wanted.Length == 0) { lock (gate) { counts.Clear(); dirty = false; } Remove(); }
        }

        // Cheap, called from the LanTun health pass. A short channel loss never touches the hosts file.
        internal void Tick(long now, bool channel)
        {
            Spec[] work; int p, gen;
            lock (gate) {
                if (specs.Length == 0 || !channel || busy || (!dirty && now < next)) return;
                busy = true; dirty = false; next = now + RefreshMs + jitterMs; work = specs; p = port; gen = generation;
            }
            run(() => {
                bool ok = false;
                try { ok = Refresh(work, p, gen); }
                catch (Exception e) { platform.Log("hosts-failed", 1); platform.Detail("hosts-failed " + e.GetType().Name + ": " + Clean(e.Message)); }
                finally { lock (gate) { busy = false; if (!ok) next = now + RetryMs; } }
            });
        }

        internal int Count(string network) { lock (gate) { int n; return counts.TryGetValue(network, out n) ? n : 0; } }
        internal long UpdatedAt { get { lock (gate) return updated; } }

        // Stop of the LAN feature, empty list, service removal: take our block out.
        internal bool Remove()
        {
            lock (gate) { generation++; dirty = false; }
            lock (fileGate) {
                try {
                    var raw = platform.ReadHosts();
                    if (raw == null) return true;
                    string text = Decode(raw); var lines = Lines(text); int removed = StripBlocks(lines);
                    if (removed == 0) return true;
                    platform.WriteHosts(Latin1.GetBytes(Join(lines, NewLine(text)))); platform.FlushDns();
                    platform.Log("hosts-removed", 0);
                    return true;
                } catch (Exception e) { platform.Log("hosts-write-failed", 1); platform.Detail("hosts-write-failed " + Clean(e.Message)); return false; }
            }
        }

        static string Clean(string text) { return Regex.Replace(text ?? "", @"[\r\n\t]+", " "); }
        static string Decode(byte[] raw)
        {
            if (raw.Length >= 2 && ((raw[0] == 0xFF && raw[1] == 0xFE) || (raw[0] == 0xFE && raw[1] == 0xFF))) throw new IOException("hosts в кодировке UTF-16 не поддерживается");
            return Latin1.GetString(raw);
        }
        static string NewLine(string text) { return text.Contains("\r\n") || text.IndexOf('\n') < 0 ? "\r\n" : "\n"; }
        static List<string> Lines(string text)
        {
            var lines = text.Split('\n').Select(l => l.TrimEnd('\r')).ToList();
            if (lines.Count > 0 && lines[lines.Count - 1].Length == 0) lines.RemoveAt(lines.Count - 1);
            return lines;
        }
        static string Join(List<string> lines, string nl) { return lines.Count == 0 ? "" : string.Join(nl, lines) + nl; }
        static bool IsBegin(string line) { return line.Trim().StartsWith(BeginPrefix, StringComparison.Ordinal); }
        static bool IsEnd(string line) { return line.Trim().StartsWith(EndPrefix, StringComparison.Ordinal); }
        static bool Tagged(string line) { return line.Contains("# RemoteAgents:"); }
        // Removes every marked block; an unterminated block loses only its tagged/blank lines. Returns how many lines went.
        static int StripBlocks(List<string> lines)
        {
            int removed = 0;
            while (true) {
                int b = lines.FindIndex(IsBegin);
                if (b < 0) return removed;
                int e = lines.FindIndex(b + 1, IsEnd);
                if (e >= 0) { lines.RemoveRange(b, e - b + 1); removed += e - b + 1; continue; }
                int stop = b + 1;
                while (stop < lines.Count && (lines[stop].Trim().Length == 0 || Tagged(lines[stop]))) stop++;
                lines.RemoveRange(b, stop - b); removed += stop - b;
            }
        }

        Dictionary<string, Cached> Cache()
        {
            if (cache != null) return cache;
            cache = new Dictionary<string, Cached>();
            try {
                string text = platform.LoadCache();
                if (text.Length == 0) return cache;
                foreach (var pair in Json.Map(Json.Parse(text))) {
                    var row = Json.Map(pair.Value);
                    var ips = Json.Strings(Json.Get(row, "ips"));
                    if (ips.Length > 0 && ips.Length <= 4) cache[pair.Key] = new Cached { Ips = ips, At = long.Parse(Json.Str(row, "at"), CultureInfo.InvariantCulture) };
                }
            } catch { cache.Clear(); }
            return cache;
        }
        string CacheText()
        { return Json.Encode(Cache().OrderBy(p => p.Key, StringComparer.Ordinal).ToDictionary(p => p.Key, p => (object)new Dictionary<string, object> { { "ips", p.Value.Ips }, { "at", p.Value.At.ToString(CultureInfo.InvariantCulture) } })); }

        static string[] Allowed(string[] ips, string[] subnets)
        {
            var good = new List<string>();
            foreach (string ip in ips) {
                uint value;
                try { value = LanAccess.IPv4(ip); } catch (InvalidDataException) { continue; }
                if (subnets.Any(s => LanTun.Contains(s, value)) && !good.Contains(ip)) good.Add(ip);
            }
            return good.Take(4).ToArray();
        }

        bool Refresh(Spec[] work, int socksPort, int gen)
        {
            long nowS = platform.NowSeconds();
            var jobs = work.SelectMany(s => s.Names.Select(n => new { spec = s, name = n.ToLowerInvariant() })).ToArray();
            var found = new string[jobs.Length][]; var fresh = new bool[jobs.Length];
            System.Threading.Tasks.Parallel.For(0, jobs.Length, new ParallelOptions { MaxDegreeOfParallelism = MaxParallel }, i => {
                var job = jobs[i]; string[] ips = null;
                foreach (string dns in job.spec.Dns) {
                    try { ips = platform.ResolveA(dns, job.name, socksPort); break; }
                    catch (Exception e) { platform.Detail("hosts-resolve-failed " + job.name + " via " + dns + ": " + Clean(e.Message)); }
                }
                found[i] = ips; fresh[i] = ips != null;
            });
            var entries = new List<Entry>(); var cached = Cache();
            for (int i = 0; i < jobs.Length; i++) {
                var job = jobs[i]; string key = job.spec.Net + "|" + job.name; string[] use;
                if (fresh[i]) {
                    use = Allowed(found[i], job.spec.Subnets);
                    if (use.Length == 0) {
                        cached.Remove(key);
                        if (found[i].Length > 0) { platform.Log("hosts-skip-public", 0); platform.Detail("hosts-skip public " + job.name + " " + string.Join(",", found[i])); }
                        else platform.Detail("hosts-skip no-address " + job.name);
                        continue;
                    }
                    cached[key] = new Cached { Ips = use, At = nowS };
                } else {
                    Cached old;
                    if (!cached.TryGetValue(key, out old)) continue;
                    if (nowS < old.At || nowS - old.At > CacheSeconds) { cached.Remove(key); platform.Log("hosts-expired", 0); platform.Detail("hosts-expired " + job.name); continue; }
                    use = Allowed(old.Ips, job.spec.Subnets);
                    if (use.Length == 0) { cached.Remove(key); continue; }
                }
                foreach (string ip in use) entries.Add(new Entry { Net = job.spec.Net, Name = job.name, Ip = ip });
            }
            string json = CacheText();
            if (json != null) { try { platform.SaveCache(json); } catch (Exception e) { platform.Detail("hosts-cache-failed " + Clean(e.Message)); } }
            List<Entry> final;
            lock (fileGate) {
                lock (gate) if (gen != generation) return true; // configuration changed meanwhile: a newer pass is already queued
                if (!Apply(entries, work, out final)) return false;
            }
            lock (gate) {
                counts.Clear();
                foreach (var net in work) counts[net.Net] = final.Where(e => e.Net == net.Net).Select(e => e.Name).Distinct().Count();
                updated = nowS;
            }
            return true;
        }

        // Rewrites the block; adopts manual lines of ours, leaves conflicting ones alone.
        bool Apply(List<Entry> entries, Spec[] work, out List<Entry> final)
        {
            final = new List<Entry>();
            try {
                var raw = platform.ReadHosts();
                string text = raw == null ? "" : Decode(raw), nl = NewLine(text);
                var lines = Lines(text);
                int hadBlock = StripBlocks(lines);
                var owner = new Dictionary<string, Spec>(StringComparer.Ordinal);
                foreach (var s in work) foreach (string n in s.Names) { string low = n.ToLowerInvariant(); if (!owner.ContainsKey(low)) owner[low] = s; }
                var wanted = new HashSet<string>(entries.Select(e => e.Name));
                var blocked = new HashSet<string>(); var drop = new List<int>();
                for (int i = 0; i < lines.Count; i++) {
                    string body = lines[i]; int hash = body.IndexOf('#'); if (hash >= 0) body = body.Substring(0, hash);
                    var tokens = body.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
                    if (tokens.Length < 2) continue;
                    var names = tokens.Skip(1).Select(t => t.ToLowerInvariant()).ToArray();
                    var ours = names.Where(owner.ContainsKey).ToArray();
                    if (ours.Length == 0) continue;
                    uint ip; bool valid = true;
                    try { ip = LanAccess.IPv4(tokens[0]); } catch (InvalidDataException) { ip = 0; valid = false; }
                    bool onlyOurs = ours.Length == names.Length;
                    bool inside = valid && names.All(n => owner.ContainsKey(n) && owner[n].Subnets.Any(s => LanTun.Contains(s, ip)));
                    if (onlyOurs && inside) {
                        if (names.All(n => wanted.Contains(n))) { drop.Add(i); platform.Log("hosts-adopt", 0); platform.Detail("hosts-adopt " + lines[i].Trim()); }
                        continue; // our own manual line, name not resolvable right now: keep the user's bypass
                    }
                    foreach (string n in ours) blocked.Add(n);
                    platform.Log("hosts-conflict", 0); platform.Detail("hosts-conflict " + lines[i].Trim());
                }
                for (int i = drop.Count - 1; i >= 0; i--) lines.RemoveAt(drop[i]);
                final = entries.Where(e => !blocked.Contains(e.Name)).OrderBy(e => e.Net, StringComparer.Ordinal).ThenBy(e => e.Name, StringComparer.Ordinal).ThenBy(e => e.Ip, StringComparer.Ordinal).ToList();
                if (final.Count > 0) {
                    lines.Add(Begin);
                    foreach (var e in final) lines.Add(e.Ip + " " + e.Name + " # RemoteAgents:" + e.Net);
                    lines.Add(End);
                }
                if (raw == null && lines.Count == 0) return true;
                if (hadBlock == 0 && drop.Count == 0 && final.Count == 0) return true; // nothing of ours before or after
                string result = Join(lines, nl);
                if (raw != null && result == text) return true;
                platform.WriteHosts(Latin1.GetBytes(result));
                platform.FlushDns();
                platform.Log("hosts-updated", final.Count);
                return true;
            } catch (Exception e) {
                platform.Log("hosts-write-failed", 1); platform.Detail("hosts-write-failed " + Clean(e.Message));
                return false;
            }
        }
    }

#if !PORTABLE_TEST
    internal sealed class WindowsLanHosts : ILanHostsPlatform
    {
        readonly Func<Dictionary<string, object>> credentials;
        readonly Action<string, int> log;
        internal WindowsLanHosts(Func<Dictionary<string, object>> credentials, Action<string, int> log) { this.credentials = credentials; this.log = log; }
        static string HostsPath { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "drivers", "etc", "hosts"); } }
        static string CachePath { get { return Path.Combine(NetHelperInstall.DataDirectory, "lan-hosts.json"); } }
        static string DetailPath { get { return Path.Combine(NetHelperInstall.DataDirectory, "lan-hosts.log"); } }
        // Used by service removal, which only has to take the block out of hosts.
        internal static void RemoveBlock() { new LanHosts(new WindowsLanHosts(null, null), a => a()).Remove(); }
        public byte[] ReadHosts()
        {
            string path = HostsPath;
            if (!File.Exists(path)) return null;
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
                if (stream.Length > 4 * 1024 * 1024) throw new IOException("hosts слишком большой");
                var data = new byte[stream.Length]; int offset = 0;
                while (offset < data.Length) { int n = stream.Read(data, offset, data.Length - offset); if (n <= 0) break; offset += n; }
                return data;
            }
        }
        public void WriteHosts(byte[] content)
        {
            string path = HostsPath, temp = path + ".ra-tmp", original = path + ".ra-orig", backup = path + ".ra-bak";
            File.WriteAllBytes(temp, content);
            try {
                if (File.Exists(path)) {
                    if (!File.Exists(original)) File.Copy(path, original);
                    File.Replace(temp, path, backup, true); // keeps the ACL of the original file
                } else File.Move(temp, path);
            } finally { try { if (File.Exists(temp)) File.Delete(temp); } catch { } }
        }
        [DllImport("dnsapi.dll", EntryPoint = "DnsFlushResolverCache")] static extern bool DnsFlushResolverCache();
        public void FlushDns()
        {
            bool flushed = false;
            try { flushed = DnsFlushResolverCache(); } catch { }
            if (flushed) return;
            try {
                string system = Environment.GetFolderPath(Environment.SpecialFolder.System);
                using (var p = Process.Start(new ProcessStartInfo(Path.Combine(system, "ipconfig.exe"), "/flushdns") { UseShellExecute = false, CreateNoWindow = true })) p.WaitForExit(5000);
            } catch { }
        }
        public string[] ResolveA(string dnsServer, string name, int socksPort)
        {
            var secret = credentials();
            Func<Stream> connect = () => {
                var client = new TcpClient(AddressFamily.InterNetwork);
                try {
                    var task = client.ConnectAsync(IPAddress.Loopback, socksPort);
                    if (!task.Wait(LanHosts.QueryMs)) throw new TimeoutException("SOCKS: нет соединения");
                    return new NetworkStream(client.Client, true);
                } catch { client.Close(); throw; }
            };
            return LanDns.ResolveA(connect, Json.Str(secret, "user"), Json.Str(secret, "password"), dnsServer, name, LanHosts.QueryMs);
        }
        public string LoadCache()
        {
            try { return File.Exists(CachePath) && new FileInfo(CachePath).Length <= 256 * 1024 ? File.ReadAllText(CachePath, Encoding.UTF8) : ""; } catch { return ""; }
        }
        public void SaveCache(string json)
        {
            string temp = CachePath + ".tmp";
            File.WriteAllText(temp, json, new UTF8Encoding(false));
            if (File.Exists(CachePath)) File.Replace(temp, CachePath, null); else File.Move(temp, CachePath);
        }
        public long NowSeconds() { return DateTimeOffset.UtcNow.ToUnixTimeSeconds(); }
        public void Log(string stage, int code) { if (log != null) log(stage, code); }
        public void Detail(string line)
        {
            try {
                string path = DetailPath;
                if (File.Exists(path) && new FileInfo(path).Length > 256 * 1024) { if (File.Exists(path + ".old")) File.Delete(path + ".old"); File.Move(path, path + ".old"); }
                File.AppendAllText(path, DateTime.UtcNow.ToString("o") + " " + line + "\n", Encoding.UTF8);
            } catch { }
        }
    }
#endif
}
