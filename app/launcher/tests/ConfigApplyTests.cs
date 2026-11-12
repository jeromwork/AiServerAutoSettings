using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace RemoteAgents.Launcher
{
    // Stream D: plan by difference, parallel order with a fake runner, conflicts, «Скопировать для ИИ», sources.
    internal static class ConfigApplyTests
    {
        static int count;
        static void Check(bool value, string message) { if (!value) throw new Exception("ConfigApply: " + message); count++; }
        static void Throws<T>(Action action, string message) where T : Exception
        { bool thrown = false; try { action(); } catch (T) { thrown = true; } Check(thrown, message); }
        // The same text a person pastes (CRLF, as on Windows).
        const string Sample = "{\r\n  \"kind\": \"remoteagents-config\", \"schema\": 1,\r\n  \"device\": { \"name\": \"Ноутбук сына\" },\r\n" +
            "  \"server\": { \"address\": \"203.0.113.10\", \"port\": 2222, \"login\": \"remoteagents\", \"hostKeys\": [\"ssh-ed25519 AAAA\"],\r\n" +
            "    \"key\": { \"secret\": \"server-key\" }, \"rootPassword\": { \"secret\": \"server-root-password\", \"hint\": \"из письма хостинга\" },\r\n" +
            "    \"routes\": [ { \"kind\": \"direct\" }, { \"kind\": \"proxy\", \"proxy\": { \"type\": \"socks\", \"server\": \"127.0.0.1\", \"port\": 10808 } },\r\n" +
            "      { \"kind\": \"hop\", \"hop\": { \"host\": \"hop.example\", \"port\": 22, \"user\": \"jump\", \"hostKey\": \"ssh-ed25519 BBBB\", \"password\": { \"secret\": \"hop-password\" } } } ] },\r\n" +
            "  \"vpn\": { \"enabled\": false, \"checkUrl\": \"https://check.example/ip\", \"dnsServer\": \"1.1.1.1\", \"bootstrap\": { \"channel\": { \"secret\": \"vpn-channel\" } } },\r\n" +
            "  \"happier\": { \"mode\": \"same\", \"label\": \"Мой аккаунт\", \"serverUrl\": \"https://api.example\", \"webappUrl\": \"https://app.example\", \"key\": { \"secret\": \"happier-key\" } },\r\n" +
            "  \"bridge\": { \"enabled\": true, \"allowShell\": false },\r\n" +
            "  \"disk\": { \"base\": \"C:\\\\Users\\\\user\\\\Disk\", \"folders\": [\"Проекты\", \"Документы\"] },\r\n" +
            "  \"proxyOut\": { \"type\": \"socks\", \"server\": \"proxy.example\", \"port\": 1080, \"login\": \"u\", \"password\": { \"secret\": \"proxy-out-password\" } },\r\n" +
            "  \"lan\": [ { \"name\": \"office\", \"kind\": \"openvpn\", \"ovpn\": { \"secret\": \"lan-office-ovpn\" } } ]\r\n}\r\n";
        static Dictionary<string, object> Profile() { var p = Json.Map(Json.Parse(Sample)); p.Remove("kind"); p.Remove("schema"); return p; }
        static Dictionary<string, string> AllApplied(Dictionary<string, object> p) { return ConfigSections.Order.Where(s => ConfigSections.Present(p, s)).ToDictionary(s => s, s => ConfigSections.Hash(p, s)); }
        static Dictionary<string, bool> AllReady() { return ConfigSections.Order.ToDictionary(s => s, s => true); }
        static Dictionary<string, object> Clone(Dictionary<string, object> p) { return Json.Map(Json.Parse(Json.Encode(p))); }

        internal static void Run()
        {
            Plan(); Engine(); Conflicts(); Ai(); Sources(); Requests(); Profiles();
            Console.WriteLine("OK: " + count + " config engine checks (plan by difference, parallel order, conflicts, AI copy without secrets, sources)");
        }
        static void Plan()
        {
            var p = Profile();
            var first = ConfigPlan.Build(p, new Dictionary<string, string>(), new Dictionary<string, bool>());
            Check(first.SequenceEqual(ConfigSections.Order), "first apply runs every described section in engine order: " + string.Join(",", first));
            Check(ConfigPlan.Build(p, AllApplied(p), AllReady()).Count == 0, "same config again (applied + ready) changes nothing");
            Check(ConfigPlan.Build(Clone(p), AllApplied(p), AllReady()).Count == 0, "re-parsed identical text is still identical (canonical hash)");
            var folders = Clone(p); ((Dictionary<string, object>)folders["disk"])["folders"] = new object[] { "Проекты" };
            Check(ConfigPlan.Build(folders, AllApplied(p), AllReady()).SequenceEqual(new[] { ConfigSections.Disk }), "changed folders -> only Disk");
            var renamed = ConfigProfile.WithDeviceName(p, "Компьютер сына");
            Check(ConfigPlan.Build(renamed, AllApplied(p), AllReady()).SequenceEqual(new[] { ConfigSections.Bridge }), "new device name -> only Bridge (deviceName)");
            var moved = Clone(p); ((Dictionary<string, object>)moved["server"])["address"] = "198.51.100.7";
            var all = ConfigPlan.Build(moved, AllApplied(p), AllReady());
            Check(all.Contains(ConfigSections.Server) && all.Contains(ConfigSections.Disk) && all.Contains(ConfigSections.Lan) && !all.Contains(ConfigSections.Bootstrap), "another server re-applies every dependent section (bootstrap only if the server is unreachable)");
            var notReady = AllReady(); notReady[ConfigSections.Connection] = false;
            Check(ConfigPlan.Build(p, AllApplied(p), notReady).SequenceEqual(new[] { ConfigSections.Connection }), "live observation not ready -> that section only");
            var down = AllReady(); down[ConfigSections.Server] = false;
            var reconnect = ConfigPlan.Build(p, AllApplied(p), down);
            Check(reconnect[0] == ConfigSections.Bootstrap && reconnect[1] == ConfigSections.Server, "unreachable server: VPN first, then server");
            var partial = Clone(p); partial.Remove("lan"); partial.Remove("proxyOut"); partial.Remove("disk");
            var some = ConfigPlan.Build(partial, new Dictionary<string, string>(), new Dictionary<string, bool>());
            Check(!some.Contains(ConfigSections.Lan) && !some.Contains(ConfigSections.Proxy) && !some.Contains(ConfigSections.Disk), "missing section = do not touch");
            Check(ConfigSections.Canonical(Json.Parse("{\"b\":1,\"a\":[true,\"x\"]}")) == ConfigSections.Canonical(new Dictionary<string, object> { { "a", new object[] { true, "x" } }, { "b", 1 } }), "canonical JSON ignores key order and number type");
            var hashOnlyRoot = Clone(p); ((Dictionary<string, object>)((Dictionary<string, object>)hashOnlyRoot["server"])["rootPassword"])["hint"] = "другая подсказка";
            Check(ConfigSections.Hash(hashOnlyRoot, ConfigSections.Connection) == ConfigSections.Hash(p, ConfigSections.Connection), "root password hint does not touch the connection");
            var inspect = Json.Map(Json.Parse("{\"steps\":[{\"id\":\"server\",\"ready\":true},{\"id\":\"connection\",\"ready\":false},{\"id\":\"disk\",\"ready\":true},{\"id\":\"happier\",\"ready\":true},{\"id\":\"bridge\",\"ready\":true},{\"id\":\"vpn\",\"ready\":true}]}"));
            var config = Json.Map(Json.Parse("{\"proxy\":{\"confirmed\":true},\"lan\":{\"connections\":[{\"name\":\"office\"}]}}"));
            var ready = ConfigPlan.Ready(inspect, config, p);
            Check(ready[ConfigSections.Server] && !ready[ConfigSections.Connection] && ready[ConfigSections.Account] && ready[ConfigSections.Proxy] && ready[ConfigSections.Lan] && ready[ConfigSections.Bootstrap], "Inspect ids map to sections");
            Check(!ConfigPlan.Ready(inspect, Json.Map(Json.Parse("{}")), p)[ConfigSections.Lan], "a LAN missing on this computer is not ready");
        }
        static void Engine()
        {
            var plan = ConfigSections.Order.ToList();
            var starts = new ConcurrentDictionary<string, long>(); var ends = new ConcurrentDictionary<string, long>(); var clock = Stopwatch.StartNew();
            var states = new ConcurrentQueue<string>();
            Func<string, CancellationToken, Task<SectionOutcome>> fake = async (s, t) => {
                starts[s] = clock.ElapsedMilliseconds; await Task.Delay(400, t); ends[s] = clock.ElapsedMilliseconds;
                return new SectionOutcome { Ok = true, Summary = "ok" };
            };
            var result = ConfigEngine.Execute(plan, fake, (s, st, text) => states.Enqueue(s + ":" + st), CancellationToken.None).GetAwaiter().GetResult();
            long total = clock.ElapsedMilliseconds;
            Check(result.Count == plan.Count && result.Values.All(o => o.Ok && o.Ms >= 350), "every section ran once with timing");
            Check(ends[ConfigSections.Bootstrap] <= starts[ConfigSections.Server], "VPN first before Server");
            foreach (string s in ConfigSections.Parallel.Concat(ConfigSections.Chain)) Check(starts[s] >= ends[ConfigSections.Server], s + " waits for Server");
            var group = ConfigSections.Parallel.Concat(new[] { ConfigSections.Proxy }).ToArray();
            Check(group.Max(s => starts[s]) < group.Min(s => ends[s]), "Connection/Bridge/Account/Disk/Vpn/Proxy overlap in time");
            Check(starts[ConfigSections.Lan] >= ends[ConfigSections.Proxy], "Lan after Proxy (one server network lock)");
            Check(total < 400 * plan.Count - 1000, "total time is far below the serial sum (" + total + " ms)");
            Check(states.Contains(ConfigSections.Disk + ":" + SectionState.Running) && states.Contains(ConfigSections.Disk + ":" + SectionState.Done), "rows see running and done");

            var called = new ConcurrentBag<string>();
            Func<string, CancellationToken, Task<SectionOutcome>> serverFails = (s, t) => {
                called.Add(s);
                if (s == ConfigSections.Bootstrap) throw new IOException("канал недоступен");
                if (s == ConfigSections.Server) return Task.FromResult(new SectionOutcome { Ok = false, Summary = "Сервер не ответил по SSH" });
                return Task.FromResult(new SectionOutcome { Ok = true });
            };
            var blocked = new ConcurrentDictionary<string, SectionState>();
            var failed = ConfigEngine.Execute(plan, serverFails, (s, st, text) => blocked[s] = st, CancellationToken.None).GetAwaiter().GetResult();
            Check(called.Contains(ConfigSections.Server), "failed VPN-first still tries the server");
            Check(called.Count == 2 && blocked[ConfigSections.Disk] == SectionState.Blocked && !failed[ConfigSections.Disk].Ok, "failed server blocks the rest without running it");
            Check(failed[ConfigSections.Bootstrap].Summary == "канал недоступен", "error text reaches the row");

            var pending = ConfigEngine.Execute(new[] { ConfigSections.Account }, (s, t) => Task.FromResult(SectionOutcome.From(Json.Map(Json.Parse("{\"ok\":false,\"pending\":\"happier\",\"summary\":\"Happier устанавливается\"}")), "x")), (s, st, text) => blocked[s] = st, CancellationToken.None).GetAwaiter().GetResult();
            Check(pending[ConfigSections.Account].Pending && pending[ConfigSections.Account].Operation == "happier" && blocked[ConfigSections.Account] == SectionState.Pending, "detached install is ⏳, not ❌");

            var cancel = new CancellationTokenSource(); cancel.CancelAfter(100); bool cancelled = false;
            try { ConfigEngine.Execute(plan, fake, (s, st, text) => { }, cancel.Token).GetAwaiter().GetResult(); } catch (OperationCanceledException) { cancelled = true; }
            Check(cancelled, "«Закрыть» cancels the run");
        }
        static void Conflicts()
        {
            var keys = new[] { "device", "server", "happier", "disk", "bridge", "kind" };
            var conflicts = new[] { "server: сейчас 198.51.100.7 / в конфиге 203.0.113.10", "disk: сейчас C:\\Disk / в конфиге D:\\Disk" };
            var none = ConfigSections.Accept(keys, conflicts, new HashSet<int>());
            Check(!none.Contains("server") && !none.Contains("disk") && none.Contains("bridge") && none.Contains("happier") && !none.Contains("kind"), "a conflict is not applied without an explicit choice; the rest is");
            Check(!ConfigSections.Accept(keys, conflicts, null).Contains("server"), "no dialog answer = keep");
            var taken = ConfigSections.Accept(keys, conflicts, new HashSet<int> { 0 });
            Check(taken.Contains("server") && !taken.Contains("disk"), "«Взять из конфига» applies only that one");
            var both = new[] { "disk: корень C:\\Disk / D:\\Disk", "disk: убраны папки Архив" };
            Check(!ConfigSections.Accept(keys, both, new HashSet<int> { 0 }).Contains("disk"), "one «Оставить» keeps the whole section");
            Check(ConfigSections.ProfileKeyOfConflict("Аккаунт Happier: сейчас A / в конфиге B") == "happier" && ConfigSections.ProfileKeyOfConflict("Папки диска: убраны X") == "disk", "Russian conflict titles map to sections");
        }
        static void Ai()
        {
            var secrets = new Dictionary<string, string> { { "server-root-password", "S3cr3t-Root-Value" }, { "hop-password", "" }, { "server-key", "-----BEGIN OPENSSH PRIVATE KEY-----abc" }, { "check", "enc1:zzz" } };
            string redacted = ConfigAi.Redact(Profile(), secrets);
            string text = ConfigAi.Request("{\"current\":true}", ConfigText.Pretty(redacted), new[] { "server: сейчас A / в конфиге B" });
            foreach (string value in new[] { "S3cr3t-Root-Value", "BEGIN OPENSSH", "enc1:zzz" }) Check(!redacted.Contains(value) && !text.Contains(value), "AI copy has no secret value: " + value);
            var back = Json.Map(Json.Get(Json.Map(Json.Parse(redacted)), "secrets"));
            Check(Json.Str(back, "server-root-password") == ConfigAi.Hidden && Json.Str(back, "hop-password") == "" && !back.ContainsKey("check"), "secrets shown only as «есть, скрыт» / empty");
            Check(text.Contains(ConfigAi.Guide) && text.Contains("server: сейчас A / в конфиге B") && text.Contains("\"current\""), "AI request: guide link, both configs, conflicts");
            Check(ConfigText.Pretty(redacted).Contains(ConfigAi.Hidden), "pretty text shows <есть, скрыт> literally");
        }
        static void Sources()
        {
            Check(ConfigSource.Classify(Sample) == ConfigSource.Kind.Json, "CRLF JSON text");
            Check(ConfigSource.Classify("  https://example.org/c.json \r\n") == ConfigSource.Kind.Url, "https link");
            Throws<InvalidDataException>(() => ConfigSource.Classify("http://example.org/c.json"), "http link refused");
            Throws<InvalidDataException>(() => ConfigSource.Classify("hello"), "garbage refused");
            Check(ConfigSource.Classify("  ") == ConfigSource.Kind.Empty, "empty");
            var from = new Uri("https://example.org/a");
            Check(ConfigSource.Redirect(from, "/b").ToString() == "https://example.org/b", "relative https redirect");
            Throws<InvalidDataException>(() => ConfigSource.Redirect(from, "http://example.org/b"), "redirect to http refused");
            Throws<InvalidDataException>(() => ConfigSource.ReadLimited(new MemoryStream(new byte[ConfigSource.Limit + 1]), ConfigSource.Limit), "size limit");
            Throws<InvalidDataException>(() => ConfigSource.RequireJson("<html>"), "not JSON refused");
            Check(ConfigSource.ReadLimited(new MemoryStream(Encoding.UTF8.GetBytes(Sample)), ConfigSource.Limit) == Sample, "UTF-8 read");
            string dir = Path.Combine(Path.GetTempPath(), "cfgd-beside-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(dir);
            try {
                File.WriteAllText(Path.Combine(dir, "other.json"), "{\"x\":1}"); Check(ConfigSource.FindBeside(dir) == null, "unrelated json ignored");
                File.WriteAllText(Path.Combine(dir, "my.json"), Sample); Check(Path.GetFileName(ConfigSource.FindBeside(dir)) == "my.json", "config next to the EXE found");
                Check(ConfigSource.ReadFile(Path.Combine(dir, "my.json")).StartsWith("{"), "dragged file read");
                File.WriteAllText(Path.Combine(dir, "second.json"), Sample); Check(ConfigSource.FindBeside(dir) == null, "two configs: ask, do not guess");
            } finally { Directory.Delete(dir, true); }
            var pretty = ConfigText.Pretty("{\"a\":[1,2],\"b\":{},\"c\":\"x\\u003cy\\u003e\",\"d\":\"q\\\"z\"}");
            var parsed = Json.Map(Json.Parse(pretty));
            Check(pretty.Contains("\r\n") && Json.Str(parsed, "c") == "x<y>" && Json.Str(parsed, "d") == "q\"z" && Json.Array(Json.Get(parsed, "a")).Length == 2, "pretty print keeps the same JSON");
        }
        static void Requests()
        {
            var p = Profile(); string home = Path.Combine(Path.GetTempPath(), "cfgd-home");
            var server = ConfigRequests.Server(home, p);
            Check(Json.Str(server, "address") == "203.0.113.10" && Json.Int(server, "port", 0) == 2222 && Json.Str(server, "login") == "remoteagents", "server address/port/login");
            Check(Json.Str(server, "keyFile") == Path.Combine(home, "secrets", "config", "server-key") && !Json.Encode(server).Contains("password\":\""), "key is a file, no password in the request");
            Check(Json.Str(Json.Map(Json.Get(server, "proxy")), "host") == "127.0.0.1" && Json.Str(Json.Map(Json.Get(server, "hop")), "ssh") == "jump@hop.example", "routes -> proxy/hop of the Server action");
            var bridge = ConfigRequests.Bridge(p, new Dictionary<string, object>());
            Check(Json.Str(bridge, "deviceName") == "Ноутбук сына" && Json.Bool(bridge, "enabled") && !Json.Bool(bridge, "shell"), "Bridge carries deviceName");
            var renameOnly = new Dictionary<string, object> { { "device", new Dictionary<string, object> { { "name", "Дом" } } } };
            Check(Json.Bool(ConfigRequests.Bridge(renameOnly, Json.Map(Json.Parse("{\"bridge\":{\"enabled\":true,\"allowShell\":true}}"))), "shell"), "rename keeps current bridge settings");
            var disk = ConfigRequests.Disk(p, "C:\\Default", new[] { "old" });
            Check(Json.Strings(Json.Get(disk, "paths")).SequenceEqual(new[] { "Проекты", "Документы" }) && Json.Str(disk, "base") == "C:\\Users\\user\\Disk", "Disk from profile folders");
            var account = ConfigRequests.Account(p, new Dictionary<string, object>(), new Dictionary<string, object>());
            Check(Json.Str(account, "serverUrl") == "https://api.example" && Json.Str(account, "label") == "Мой аккаунт", "Account request");
            Throws<IOException>(() => ConfigRequests.Account(new Dictionary<string, object> { { "happier", new Dictionary<string, object>() } }, new Dictionary<string, object>(), new Dictionary<string, object>()), "Happier without addresses refused clearly");
            var lan = ConfigRequests.Lan(home, p, Json.Map(Json.Parse("{\"lan\":{\"connections\":[{\"name\":\"old\"}]}}")));
            Check(lan.Item1.Length == 1 && Json.Str(lan.Item1[0], "name") == "office" && lan.Item2.SequenceEqual(new[] { "old" }), "LAN: add new, remove gone");
            Func<string, bool> none = n => false, keyOnly = n => n == "server-key" || n == "hop-password";
            Check(ConfigRequests.SecretsFor(ConfigSections.Server, p, none).SequenceEqual(new[] { "server-root-password", "hop-password" }), "no key -> ask the root password (and the hop password)");
            Check(ConfigRequests.SecretsFor(ConfigSections.Server, p, keyOnly).Count == 0, "key present -> root password not asked");
            Check(ConfigRequests.Why("server-root-password", p, "из письма хостинга").Contains("хостинг") && ConfigRequests.Why("server-root-password", p, "из письма хостинга").Contains("Подсказка: из письма хостинга"), "explanation + hint");
            Check(ConfigRequests.SecretsFor(ConfigSections.Account, new Dictionary<string, object> { { "happier", new Dictionary<string, object> { { "mode", "new" }, { "key", new Dictionary<string, object> { { "secret", "happier-key" } } } } } }, none).Count == 0, "new Happier account needs no key");
            var catalog = ConfigRequests.MergeCatalog(Json.Map(Json.Parse("{\"entries\":[{\"name\":\"a\",\"ssh\":\"x\"}]}")), Json.Map(Json.Parse("{\"wizard\":{\"localCatalog\":{\"entries\":[{\"name\":\"a\",\"alias\":\"y\",\"keyFile\":\"C:\\\\k\"}]}}}")));
            var row = Json.Map(Json.Array(Json.Get(catalog, "entries"))[0]);
            Check(Json.Str(row, "ssh") == "y" && !row.ContainsKey("keyFile"), "local catalog rows win and lose local paths");
        }
        static void Profiles()
        {
            var p = Profile();
            var config = Json.Map(Json.Parse("{\"bridge\":{\"enabled\":false,\"allowShell\":true},\"vpn\":{\"enabled\":true,\"checkUrl\":\"https://c\"},\"lan\":{\"connections\":[{\"name\":\"home\"}]},\"proxy\":{\"type\":\"http\",\"server\":\"p2\",\"port\":3128}}"));
            var synced = ConfigProfile.SyncFromSettings(p, config, "D:\\Disk", new[] { "A" }, "198.51.100.9", "remoteagents");
            var bridge = Json.Map(Json.Get(synced, "bridge")); var vpn = Json.Map(Json.Get(synced, "vpn"));
            Check(!Json.Bool(bridge, "enabled") && Json.Bool(bridge, "allowShell") && Json.Bool(vpn, "enabled") && Json.Map(Json.Get(vpn, "bootstrap")).Count > 0, "«Подробно» changes come back into the profile (VPN-first kept)");
            Check(Json.Array(Json.Get(synced, "lan")).Length == 1 && Json.Str(Json.Map(Json.Array(Json.Get(synced, "lan"))[0]), "name") == "home", "LAN list follows this computer");
            var proxy = Json.Map(Json.Get(synced, "proxyOut"));
            Check(Json.Str(proxy, "server") == "p2" && Json.Str(proxy, "type") == "http" && Json.Str(Json.Map(Json.Get(proxy, "password")), "secret") == "proxy-out-password", "proxy follows, secret reference kept");
            Check(Json.Str(Json.Map(Json.Get(synced, "server")), "address") == "198.51.100.9" && Json.Strings(Json.Get(Json.Map(Json.Get(synced, "disk")), "folders")).SequenceEqual(new[] { "A" }), "server and folders follow");
            var withFolders = ConfigProfile.WithFolders(new Dictionary<string, object>(), new[] { "X" }, "C:\\D");
            Check(Json.Str(Json.Map(Json.Get(withFolders, "disk")), "base") == "C:\\D", "folders chosen without a disk section get the base");
            string home = Path.Combine(Path.GetTempPath(), "cfgd-profile-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(home);
            try {
                ConfigProfile.Update(home, x => { foreach (var pair in p) x[pair.Key] = pair.Value; });
                ConfigProfile.MarkApplied(home, ConfigSections.Disk, ConfigSections.Hash(ConfigProfile.Load(home), ConfigSections.Disk));
                Check(ConfigProfile.Applied(home)[ConfigSections.Disk] == ConfigSections.Hash(p, ConfigSections.Disk), "profile and applied hash survive config.json");
                Check(Json.Int(new Configuration(home).Data, "schema", 0) == 1, "config.json keeps its schema");
                ConfigProfile.MarkApplied(home, ConfigSections.Disk, null); Check(!ConfigProfile.Applied(home).ContainsKey(ConfigSections.Disk), "failed section forgets its hash");
            } finally { Directory.Delete(home, true); }
        }
    }
}
