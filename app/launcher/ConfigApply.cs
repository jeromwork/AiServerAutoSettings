using System;
using System.Collections;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace RemoteAgents.Launcher
{
    // Paste-a-config engine (docs/TASK-CONFIG.md, docs/CONFIG-CONTRACT.md §4): desired profile vs. what is
    // really configured (Inspect) -> plan -> the existing build/Wizard.ps1 actions, independent sections in parallel.
    // Everything above ConfigSession is pure and covered by the portable tests (no WinForms, no ConfigBundle).
    internal static class ConfigSections
    {
        internal const string Bootstrap = "bootstrap", Server = "server", Connection = "connection", Bridge = "bridge", Account = "account",
            Disk = "disk", Vpn = "vpn", Proxy = "proxy", Lan = "lan";
        // Rows of the window, in the order a person reads them.
        internal static readonly string[] Rows = { Server, Connection, Bridge, Account, Disk, Vpn, Proxy, Lan };
        // After «Сервер» these run at the same time; Proxy and Lan share the server network lock: one after another.
        internal static readonly string[] Parallel = { Connection, Bridge, Account, Disk, Vpn };
        internal static readonly string[] Chain = { Proxy, Lan };
        internal static readonly string[] Order = { Bootstrap, Server, Connection, Bridge, Account, Disk, Vpn, Proxy, Lan };
        // Top-level profile keys (config.paste.schema.json). Unknown keys are refused by ConfigBundle.Parse (stream A).
        internal static readonly string[] ProfileKeys = { "device", "server", "vpn", "happier", "bridge", "disk", "proxyOut", "lan", "components" };
        internal static bool Known(string key) { return ProfileKeys.Contains(key); }
        internal static string Title(string s)
        {
            switch (s) {
                case Bootstrap: return "VPN первым"; case Server: return "Сервер"; case Connection: return "Связь"; case Bridge: return "Мост";
                case Account: return "Happier"; case Disk: return "Диск"; case Vpn: return "VPN"; case Proxy: return "Прокси сервера"; case Lan: return "Локальные сети";
                default: return s;
            }
        }
        internal static string Action(string s)
        {
            switch (s) {
                case Bootstrap: return "Bootstrap"; case Server: return "Server"; case Connection: return "Connection"; case Bridge: return "Bridge";
                case Account: return "Account"; case Disk: return "Disk"; case Vpn: return "Vpn"; case Proxy: return "Proxy"; case Lan: return "Lan";
                default: throw new ArgumentException("Неизвестный раздел");
            }
        }
        // Conflicts are reported by ConfigBundle.Conflicts as «<profile key>: сейчас X / в конфиге Y».
        internal static string ProfileKeyOfConflict(string line)
        {
            string head = (line ?? "").Split(':')[0].Trim().ToLowerInvariant();
            if (head == "server" || head.StartsWith("сервер")) return "server";
            if (head == "happier" || head.StartsWith("аккаунт") || head.Contains("happier")) return "happier";
            if (head == "disk" || head.StartsWith("диск") || head.StartsWith("папк") || head.StartsWith("корень")) return "disk";
            return head;
        }
        // Profile keys to store: everything described, except conflicting keys the person did not explicitly take
        // («Взять из конфига»). No choice at all = nothing conflicting is applied.
        internal static HashSet<string> Accept(IEnumerable<string> profileKeys, IList<string> conflicts, ICollection<int> take)
        {
            var accept = new HashSet<string>(profileKeys.Where(Known));
            for (int i = 0; i < conflicts.Count; i++) if (take == null || !take.Contains(i)) accept.Remove(ProfileKeyOfConflict(conflicts[i]));
            return accept;
        }
        // Is the section described in the desired profile? A missing section means «не трогать».
        internal static bool Present(Dictionary<string, object> p, string s)
        {
            var vpn = Json.Map(Json.Get(p, "vpn"));
            switch (s) {
                case Bootstrap: return Json.Map(Json.Get(vpn, "bootstrap")).ContainsKey("channel"); // a public catalog alone needs no VPN-first
                case Server: case Connection: return p.ContainsKey("server");
                case Bridge: return p.ContainsKey("bridge") || Json.Str(Json.Map(Json.Get(p, "device")), "name").Length > 0;
                case Account: return p.ContainsKey("happier");
                case Disk: return p.ContainsKey("disk");
                case Vpn: return vpn.Keys.Any(k => k != "bootstrap");
                case Proxy: return p.ContainsKey("proxyOut");
                case Lan: return p.ContainsKey("lan");
                default: return false;
            }
        }
        // The part of the profile a section depends on; its hash decides «changed since last successful apply».
        internal static object Slice(Dictionary<string, object> p, string s)
        {
            var vpn = new Dictionary<string, object>(Json.Map(Json.Get(p, "vpn")));
            switch (s) {
                case Bootstrap: return Json.Get(vpn, "bootstrap");
                case Server: return Json.Get(p, "server");
                case Connection: { var server = new Dictionary<string, object>(Json.Map(Json.Get(p, "server"))); server.Remove("rootPassword"); return server; }
                case Bridge: return new Dictionary<string, object> { { "bridge", Json.Get(p, "bridge") }, { "name", Json.Str(Json.Map(Json.Get(p, "device")), "name") } };
                case Account: return Json.Get(p, "happier");
                case Disk: return Json.Get(p, "disk");
                case Vpn: vpn.Remove("bootstrap"); return vpn;
                case Proxy: return Json.Get(p, "proxyOut");
                case Lan: return Json.Get(p, "lan");
                default: return null;
            }
        }
        internal static string Hash(Dictionary<string, object> p, string s)
        {
            using (var sha = SHA256.Create())
                return BitConverter.ToString(sha.ComputeHash(Files.Utf8.GetBytes(Canonical(Slice(p, s))))).Replace("-", "").Substring(0, 32).ToLowerInvariant();
        }
        // Deterministic JSON: object keys sorted, numbers invariant (int 22 == decimal 22).
        internal static string Canonical(object value)
        {
            if (value == null) return "null";
            if (value is string) return Json.Encode(value);
            if (value is bool) return (bool)value ? "true" : "false";
            var map = value as IDictionary;
            if (map != null) {
                var keys = map.Keys.Cast<object>().Select(k => Convert.ToString(k, CultureInfo.InvariantCulture)).OrderBy(k => k, StringComparer.Ordinal);
                return "{" + string.Join(",", keys.Select(k => Json.Encode(k) + ":" + Canonical(map[k]))) + "}";
            }
            if (value is IEnumerable) return "[" + string.Join(",", ((IEnumerable)value).Cast<object>().Select(Canonical)) + "]";
            return Convert.ToString(value, CultureInfo.InvariantCulture);
        }
    }

    internal static class ConfigPlan
    {
        // ready: live observation (Inspect) per section; applied: hash of the slice at the last successful apply.
        // A section runs when it is described and (changed or not observed ready). A server that has to be
        // (re)applied drags every described section with it: they all depend on the server and its key.
        internal static List<string> Build(Dictionary<string, object> desired, IDictionary<string, string> applied, IDictionary<string, bool> ready)
        {
            var plan = new List<string>();
            Func<string, bool> changed = s => { string h; return !applied.TryGetValue(s, out h) || h != ConfigSections.Hash(desired, s); };
            Func<string, bool> isReady = s => { bool r; return ready.TryGetValue(s, out r) && r; };
            bool server = ConfigSections.Present(desired, ConfigSections.Server) && (changed(ConfigSections.Server) || !isReady(ConfigSections.Server));
            foreach (string s in ConfigSections.Order) {
                if (!ConfigSections.Present(desired, s)) continue;
                bool needed = s == ConfigSections.Bootstrap ? changed(s) || (server && !isReady(ConfigSections.Server))
                    : s == ConfigSections.Server ? server
                    : server || changed(s) || !isReady(s);
                if (needed) plan.Add(s);
            }
            return plan;
        }
        // Inspect result (Wizard.Common.ps1 'Inspect') + config.json -> live readiness per section.
        internal static Dictionary<string, bool> Ready(Dictionary<string, object> inspect, Dictionary<string, object> config, Dictionary<string, object> desired)
        {
            var ready = new Dictionary<string, bool>();
            var map = new Dictionary<string, string> { { "server", ConfigSections.Server }, { "connection", ConfigSections.Connection }, { "disk", ConfigSections.Disk },
                { "happier", ConfigSections.Account }, { "bridge", ConfigSections.Bridge }, { "vpn", ConfigSections.Vpn } };
            foreach (var step in Json.Array(Json.Get(inspect, "steps")).Select(Json.Map)) {
                string s; if (map.TryGetValue(Json.Str(step, "id"), out s)) ready[s] = Json.Bool(step, "ready");
            }
            bool server; ready.TryGetValue(ConfigSections.Server, out server);
            ready[ConfigSections.Bootstrap] = server;
            ready[ConfigSections.Proxy] = Json.Bool(Json.Map(Json.Get(config, "proxy")), "confirmed");
            var have = new HashSet<string>(Json.Array(Json.Get(Json.Map(Json.Get(config, "lan")), "connections")).Select(r => Json.Str(Json.Map(r), "name")));
            ready[ConfigSections.Lan] = Json.Array(Json.Get(desired, "lan")).All(r => have.Contains(Json.Str(Json.Map(r), "name")));
            return ready;
        }
    }

    internal enum SectionState { Waiting, Running, Done, Pending, Failed, Blocked, Unchanged }
    internal sealed class SectionOutcome
    {
        internal bool Ok, Pending; internal string Summary = "", Operation = ""; internal Dictionary<string, object> Result = new Dictionary<string, object>(); internal long Ms;
        // docs/CONFIG-ENGINE.md: readiness is result.ok; «pending» names what it waits for (a detached server install
        // «disk»/«happier», or «connection»). ok:false without pending is a failure, except an unconfirmed request
        // (VPN TUN) the caller marks as such: that is ⏳, never ✅.
        internal static SectionOutcome From(Dictionary<string, object> result, string success, bool unconfirmedIsPending = false)
        {
            string pending = Json.Str(result, "pending"); bool ok = Json.Bool(result, "ok", true);
            return new SectionOutcome { Ok = ok, Pending = !ok && (pending.Length > 0 || unconfirmedIsPending), Operation = pending, Result = result,
                Summary = Json.Text(result, "summary", success) + (ok || pending.Length > 0 ? "" : unconfirmedIsPending ? " (ещё не подтверждено)" : "") };
        }
        // Detached installs on the server that ServerOperations/«Operation» can follow.
        internal static bool ServerOperation(string operation) { return operation == "disk" || operation == "happier"; }
    }

    internal static class ConfigEngine
    {
        // Bootstrap -> Server -> {Connection, Bridge, Account, Disk, Vpn} at the same time, with Proxy -> Lan as one more
        // parallel chain. A failed Bootstrap does not stop Server (the direct route may work); a failed Server blocks the rest.
        internal static async Task<Dictionary<string, SectionOutcome>> Execute(IList<string> plan, Func<string, CancellationToken, Task<SectionOutcome>> run,
            Action<string, SectionState, string> report, CancellationToken token)
        {
            var outcomes = new ConcurrentDictionary<string, SectionOutcome>();
            foreach (string s in plan) report(s, SectionState.Waiting, "в очереди");
            Func<string, Task<bool>> one = async s => {
                if (!plan.Contains(s)) return true;
                token.ThrowIfCancellationRequested();
                report(s, SectionState.Running, "выполняется…"); var watch = Stopwatch.StartNew();
                SectionOutcome o;
                try { o = await run(s, token); }
                catch (OperationCanceledException) { outcomes[s] = new SectionOutcome { Summary = "отменено", Ms = watch.ElapsedMilliseconds }; report(s, SectionState.Failed, "отменено; готовность не подтверждена"); throw; }
                catch (Exception e) { o = new SectionOutcome { Summary = e.Message }; }
                o.Ms = watch.ElapsedMilliseconds; outcomes[s] = o;
                report(s, o.Ok ? SectionState.Done : o.Pending ? SectionState.Pending : SectionState.Failed, o.Summary);
                return o.Ok || o.Pending;
            };
            await one(ConfigSections.Bootstrap);
            bool server = await one(ConfigSections.Server);
            var rest = plan.Where(s => ConfigSections.Parallel.Contains(s) || ConfigSections.Chain.Contains(s)).ToArray();
            if (!server) {
                foreach (string s in rest) { outcomes[s] = new SectionOutcome { Summary = "ждёт сервер" }; report(s, SectionState.Blocked, "ждёт доступа к серверу: сначала исправьте «Сервер»"); }
                return new Dictionary<string, SectionOutcome>(outcomes);
            }
            // Vpn may answer pending:"connection" while Connection is still proving the channel: it is run once
            // more right after a successful Connection instead of staying ⏳ forever.
            Task<bool> connection = plan.Contains(ConfigSections.Connection) ? one(ConfigSections.Connection) : Task.FromResult(true);
            Func<string, Task<bool>> after = async s => {
                bool r = await one(s); SectionOutcome o;
                if (!r || !outcomes.TryGetValue(s, out o) || !o.Pending || o.Operation != "connection" || !plan.Contains(ConfigSections.Connection)) return r;
                if (!await connection) return r;
                return await one(s);
            };
            var tasks = ConfigSections.Parallel.Where(s => s != ConfigSections.Connection && plan.Contains(s)).Select(s => after(s)).ToList();
            tasks.Add(connection);
            Func<Task<bool>> chain = async () => { foreach (string s in ConfigSections.Chain) await one(s); return true; };
            tasks.Add(chain());
            await Task.WhenAll(tasks);
            return new Dictionary<string, SectionOutcome>(outcomes);
        }
    }

    // One runner for every build/Wizard.ps1 action: the step-by-step wizard, the tray and the config engine.
    // Progress lines (ProgressFile, JSON {"text":…} per line) are delivered as they appear; budgets: WizardStep.Timeout.
    internal static class WizardRunner
    {
        internal static Dictionary<string, object> Run(string home, string bundle, string action, object request, CancellationToken token, Action<string> progress = null)
        {
            string requestFile = Path.Combine(home, "state", "wizard-request-" + Guid.NewGuid().ToString("N") + ".json"), output = requestFile + ".out", live = requestFile + ".progress";
            var gate = new object(); int readLines = 0;
            Action read = () => {
                if (progress == null) return;
                lock (gate) {
                    try {
                        if (!File.Exists(live)) return; string text;
                        using (var stream = new FileStream(live, FileMode.Open, FileAccess.Read, FileShare.ReadWrite)) using (var reader = new StreamReader(stream, Files.Utf8)) text = reader.ReadToEnd();
                        var lines = Files.LF(text).Split('\n');
                        while (readLines < lines.Length - 1) { string line = lines[readLines++]; string shown; try { shown = Json.Str(Json.Map(Json.Parse(line)), "text"); } catch (Exception) { shown = line; } if (shown.Length > 0) progress(shown); }
                    } catch (IOException) { }
                }
            };
            try {
                Json.Write(requestFile, request);
                var args = new List<string> { "-NoLogo", "-NoProfile", "-NonInteractive", "-STA", "-ExecutionPolicy", "Bypass", "-File", Path.Combine(bundle, "build", "Wizard.ps1"), "-Home", home, "-Action", action, "-RequestFile", requestFile };
                if (progress != null) { args.Add("-ProgressFile"); args.Add(live); }
                int code;
                using (var poll = new Timer(_ => read(), null, 150, 150)) {
                    try { code = External.Run(Files.Executable("powershell.exe"), args.ToArray(), bundle, output, WizardStep.Timeout(action), 4 * 1024 * 1024, token); }
                    catch (OperationCanceledException) { new Journal(home).Write("wizard." + action + ".cancelled"); throw; }
                    catch (TimeoutException) { new Journal(home).Write("wizard." + action + ".timeout"); throw; }
                }
                read();
                Dictionary<string, object> response;
                try { response = Json.Map(Json.Parse(Files.LF(External.ReadPowerShellOutput(output)))); }
                catch (Exception) { throw new IOException("Шаг не вернул результат (код " + code + "). Проверьте журнал соответствующего модуля и повторите"); }
                if (code != 0 || !Json.Bool(response, "ok")) throw new IOException((Json.Text(response, "reason", "Шаг не подтверждён: проверьте журнал и повторите") + ". " + Json.Str(response, "remedy")).Trim());
                return Json.Map(Json.Get(response, "result"));
            } finally { foreach (string f in new[] { requestFile, output, live }) try { if (File.Exists(f)) File.Delete(f); } catch (IOException) { } }
        }
    }

    // Desired profile in config.json («profile») and hashes of what was applied successfully (state/config-applied.json).
    internal static class ConfigProfile
    {
        internal static Dictionary<string, object> Load(string home) { return new Dictionary<string, object>(Json.Map(Json.Get(new Configuration(home).Data, "profile"))); }
        internal static void Update(string home, Action<Dictionary<string, object>> change)
        { new Configuration(home).Edit(c => { var p = new Dictionary<string, object>(Json.Map(Json.Get(c, "profile"))); change(p); c["profile"] = p; }); }
        static string AppliedFile(string home) { return Path.Combine(home, "state", "config-applied.json"); }
        internal static Dictionary<string, string> Applied(string home)
        {
            try { var m = Json.Map(Json.Get(Json.Read(AppliedFile(home)), "sections")); return m.ToDictionary(p => p.Key, p => Convert.ToString(p.Value, CultureInfo.InvariantCulture)); }
            catch (Exception) { return new Dictionary<string, string>(); }
        }
        static readonly object appliedGate = new object();
        internal static void MarkApplied(string home, string section, string hash)
        {
            lock (appliedGate) {
                var all = Applied(home); if (hash == null) all.Remove(section); else all[section] = hash;
                Json.Write(AppliedFile(home), new Dictionary<string, object> { { "schema", 1 }, { "sections", all.ToDictionary(p => p.Key, p => (object)p.Value) } });
            }
        }
        internal static string DeviceName(Dictionary<string, object> profile) { return Json.Str(Json.Map(Json.Get(profile, "device")), "name").Trim(); }
        internal static Dictionary<string, object> WithDeviceName(Dictionary<string, object> profile, string name)
        {
            var p = new Dictionary<string, object>(profile); var device = new Dictionary<string, object>(Json.Map(Json.Get(p, "device")));
            device["name"] = name.Trim(); p["device"] = device; return p;
        }
        internal static Dictionary<string, object> WithFolders(Dictionary<string, object> profile, IEnumerable<string> folders, string diskBase)
        {
            var p = new Dictionary<string, object>(profile); var disk = new Dictionary<string, object>(Json.Map(Json.Get(p, "disk")));
            if (!disk.ContainsKey("base") && !string.IsNullOrEmpty(diskBase)) disk["base"] = diskBase;
            disk["folders"] = folders.ToArray(); p["disk"] = disk; return p;
        }
        // «Подробно» (the step-by-step sections) edit config.json; bring the same facts back into the profile so the
        // config stays the one description of the program. Sections never described are added only when really set.
        internal static Dictionary<string, object> SyncFromSettings(Dictionary<string, object> profile, Dictionary<string, object> config, string diskBase, string[] diskFolders, string serverAddress, string serverLogin)
        {
            var p = new Dictionary<string, object>(profile);
            var bridge = Json.Map(Json.Get(config, "bridge"));
            if (bridge.Count > 0) { var b = new Dictionary<string, object>(Json.Map(Json.Get(p, "bridge"))); b["enabled"] = Json.Bool(bridge, "enabled"); b["allowShell"] = Json.Bool(bridge, "allowShell"); p["bridge"] = b; }
            var vpn = Json.Map(Json.Get(config, "vpn"));
            if (vpn.Count > 0) {
                var v = new Dictionary<string, object>(Json.Map(Json.Get(p, "vpn"))); v["enabled"] = Json.Bool(vpn, "enabled");
                foreach (string k in new[] { "checkUrl", "dnsServer" }) if (Json.Str(vpn, k).Length > 0) v[k] = Json.Str(vpn, k);
                p["vpn"] = v;
            }
            var happier = Json.Map(Json.Get(config, "happier"));
            if (Json.Str(happier, "serverUrl").Length > 0) {
                var h = new Dictionary<string, object>(Json.Map(Json.Get(p, "happier")));
                h["serverUrl"] = Json.Str(happier, "serverUrl"); h["webappUrl"] = Json.Str(happier, "webappUrl");
                if (Json.Str(happier, "label").Length > 0) h["label"] = Json.Str(happier, "label");
                if (!h.ContainsKey("mode")) h["mode"] = "same"; p["happier"] = h;
            }
            var proxy = Json.Map(Json.Get(config, "proxy"));
            if (Json.Str(proxy, "server").Length > 0) {
                var x = new Dictionary<string, object>(Json.Map(Json.Get(p, "proxyOut")));
                x["type"] = Json.Text(proxy, "type", "socks"); x["server"] = Json.Str(proxy, "server"); x["port"] = Json.Int(proxy, "port", 0); p["proxyOut"] = x;
            }
            var lans = Json.Array(Json.Get(Json.Map(Json.Get(config, "lan")), "connections")).Select(Json.Map).ToArray();
            if (lans.Length > 0 || p.ContainsKey("lan")) {
                var old = Json.Array(Json.Get(p, "lan")).Select(Json.Map).ToArray();
                p["lan"] = lans.Select(l => (object)(old.FirstOrDefault(o => Json.Str(o, "name") == Json.Str(l, "name")) ?? new Dictionary<string, object> { { "name", Json.Str(l, "name") }, { "kind", "openvpn" } })).ToArray();
            }
            if (!string.IsNullOrEmpty(diskBase) && (diskFolders != null || p.ContainsKey("disk"))) {
                var d = new Dictionary<string, object>(Json.Map(Json.Get(p, "disk"))); d["base"] = diskBase; if (diskFolders != null) d["folders"] = diskFolders; p["disk"] = d;
            }
            if (!string.IsNullOrEmpty(serverAddress)) {
                var s = new Dictionary<string, object>(Json.Map(Json.Get(p, "server"))); s["address"] = serverAddress; if (!string.IsNullOrEmpty(serverLogin)) s["login"] = serverLogin; p["server"] = s;
            }
            return p;
        }
    }

    // Requests for the existing actions, built from the profile. Passwords never go here: ConfigSession adds
    // one-use pipes (PasswordRelay). Key-like secrets are files laid out by SecretVault.Materialize (stream A).
    internal static class ConfigRequests
    {
        internal static string SecretName(object field) { return Json.Str(Json.Map(field), "secret"); }
        internal static string SecretHint(object field) { return Json.Str(Json.Map(field), "hint"); }
        // File-like secrets (SSH keys, .ovpn) are laid out by SecretVault.Materialize; secrets/materialized.json is the
        // only map of where they are (docs/CONFIG.md «Хранилище и материализация»). No guessed paths, no stale files.
        internal static Dictionary<string, object> Materialized(string home)
        {
            try { string file = Path.Combine(home, "secrets", "materialized.json"); return File.Exists(file) ? Json.Map(Json.Read(file)) : new Dictionary<string, object>(); }
            catch (Exception) { return new Dictionary<string, object>(); }
        }
        internal static string RouteFile(Dictionary<string, object> manifest, Dictionary<string, object> server, string kind, string field)
        {
            var routes = Json.Array(Json.Get(server, "routes")).Select(Json.Map).ToList(); int index = routes.FindIndex(r => Json.Str(r, "kind") == kind);
            var rows = Json.Array(Json.Get(manifest, "routes")).Select(Json.Map).ToArray();
            return index < 0 || index >= rows.Length ? "" : Json.Str(Json.Map(Json.Get(rows[index], kind)), field);
        }
        internal static string LanFile(Dictionary<string, object> manifest, string name)
        { return Json.Str(Json.Array(Json.Get(manifest, "lan")).Select(Json.Map).FirstOrDefault(r => Json.Str(r, "name") == name) ?? new Dictionary<string, object>(), "file"); }
        internal static Dictionary<string, object> Route(Dictionary<string, object> server, string kind)
        { return Json.Array(Json.Get(server, "routes")).Select(Json.Map).FirstOrDefault(r => Json.Str(r, "kind") == kind) ?? new Dictionary<string, object>(); }
        internal static Dictionary<string, object> Server(string home, Dictionary<string, object> p)
        {
            var server = Json.Map(Json.Get(p, "server")); var manifest = Materialized(home);
            var request = new Dictionary<string, object> { { "address", Json.Str(server, "address") }, { "login", Json.Text(server, "login", "root") }, { "installMissing", true },
                { "keyFile", Json.Str(manifest, "serverKeyFile") }, { "hostKeys", Json.Strings(Json.Get(server, "hostKeys")) } };
            int port = Json.Int(server, "port", 22); if (port != 22) request["port"] = port;
            var proxy = Json.Map(Json.Get(Route(server, "proxy"), "proxy"));
            if (Json.Str(proxy, "server").Length > 0) request["proxy"] = new Dictionary<string, object> { { "type", Json.Str(proxy, "type") == "http" ? "http" : "socks" }, { "host", Json.Str(proxy, "server") }, { "port", Json.Int(proxy, "port", 0) } };
            var hop = Json.Map(Json.Get(Route(server, "hop"), "hop"));
            if (Json.Str(hop, "host").Length > 0) {
                int hopPort = Json.Int(hop, "port", 22); string user = Json.Str(hop, "user");
                request["hop"] = new Dictionary<string, object> { { "name", "hop" }, { "ssh", (user.Length > 0 ? user + "@" : "") + Json.Str(hop, "host") + (hopPort != 22 ? ":" + hopPort : "") },
                    { "keyFile", RouteFile(manifest, server, "hop", "keyFile") }, { "hostKey", Json.Str(hop, "hostKey") } };
            }
            return request;
        }
        internal static Dictionary<string, object> Bridge(Dictionary<string, object> p, Dictionary<string, object> config)
        {
            var bridge = p.ContainsKey("bridge") ? Json.Map(Json.Get(p, "bridge")) : Json.Map(Json.Get(config, "bridge"));
            var request = new Dictionary<string, object> { { "enabled", Json.Bool(bridge, "enabled", true) }, { "shell", Json.Bool(bridge, "allowShell") } };
            string name = ConfigProfile.DeviceName(p); if (name.Length > 0) request["deviceName"] = name;
            return request;
        }
        internal static Dictionary<string, object> Disk(Dictionary<string, object> p, string defaultBase, string[] currentSelection)
        {
            var disk = Json.Map(Json.Get(p, "disk"));
            return new Dictionary<string, object> { { "base", Json.Text(disk, "base", defaultBase) }, { "paths", disk.ContainsKey("folders") ? Json.Strings(Json.Get(disk, "folders")) : currentSelection ?? new string[0] }, { "reconnect", false } };
        }
        internal static Dictionary<string, object> Vpn(Dictionary<string, object> p)
        {
            var vpn = Json.Map(Json.Get(p, "vpn"));
            return new Dictionary<string, object> { { "enabled", Json.Bool(vpn, "enabled") }, { "checkUrl", Json.Str(vpn, "checkUrl") }, { "dnsServer", Json.Str(vpn, "dnsServer") } };
        }
        internal static Dictionary<string, object> Account(Dictionary<string, object> p, Dictionary<string, object> services, Dictionary<string, object> config)
        {
            var h = Json.Map(Json.Get(p, "happier")); var saved = Json.Map(Json.Get(config, "happier"));
            string api = Json.Text(h, "serverUrl", Json.Text(saved, "serverUrl", Json.Str(services, "serverUrl"))), web = Json.Text(h, "webappUrl", Json.Text(saved, "webappUrl", Json.Str(services, "webappUrl")));
            if (api.Length == 0 || web.Length == 0) throw new IOException("Нет адресов Happier: укажите happier.serverUrl и happier.webappUrl или дождитесь установки Happier на сервере");
            string label = Json.Text(h, "label", ConfigProfile.DeviceName(p)); if (label.Length == 0) label = "Мой аккаунт";
            var request = new Dictionary<string, object> { { "label", label }, { "serverUrl", Origin(api) }, { "webappUrl", Origin(web) }, { "expectedAccount", "" } };
            // «Тот же аккаунт» without a key (what `remoteagents config export` issues): the engine selects and live-checks
            // the server's existing account (docs/CONFIG-ENGINE.md, Account mode:"same"); no recovery key travels.
            if (Json.Str(h, "mode") != "new" && SecretName(Json.Get(h, "key")).Length == 0) request["mode"] = "same";
            return request;
        }
        internal static string IpCheckUrl(Dictionary<string, object> p, Dictionary<string, object> config)
        { return Json.Text(Json.Map(Json.Get(p, "proxyOut")), "checkUrl", Json.Text(Json.Map(Json.Get(config, "proxy")), "ipCheckUrl", Json.Str(Json.Map(Json.Get(p, "vpn")), "checkUrl"))); }
        internal static Dictionary<string, object> Proxy(Dictionary<string, object> p, Dictionary<string, object> config)
        {
            var x = Json.Map(Json.Get(p, "proxyOut")); int port = Json.Int(x, "port", 0);
            if (Json.Str(x, "server").Length == 0 || port < 1 || port > 65535) throw new IOException("В разделе proxyOut нужны server и port 1–65535");
            return new Dictionary<string, object> { { "type", Json.Str(x, "type") == "http" ? "http" : "socks" }, { "server", Json.Str(x, "server") }, { "port", port.ToString(CultureInfo.InvariantCulture) }, { "ipCheckUrl", IpCheckUrl(p, config) } };
        }
        // Networks to add (not yet on this computer's list) and to remove (listed here, gone from the config).
        internal static Tuple<Dictionary<string, object>[], string[]> Lan(string home, Dictionary<string, object> p, Dictionary<string, object> config)
        {
            var have = Json.Array(Json.Get(Json.Map(Json.Get(config, "lan")), "connections")).Select(r => Json.Str(Json.Map(r), "name")).ToArray();
            var wanted = Json.Array(Json.Get(p, "lan")).Select(Json.Map).ToArray();
            var manifest = Materialized(home);
            var add = wanted.Where(l => !have.Contains(Json.Str(l, "name"))).Select(l => new Dictionary<string, object> {
                { "kind", Json.Text(l, "kind", "openvpn") }, { "name", Json.Str(l, "name") }, { "file", LanFile(manifest, Json.Str(l, "name")) },
                { "host", Json.Str(l, "host") }, { "port", Json.Int(l, "port", 0) > 0 ? Json.Int(l, "port", 0).ToString(CultureInfo.InvariantCulture) : "" },
                { "ipCheckUrl", Json.Text(l, "checkUrl", IpCheckUrl(p, config)) } }).ToArray();
            return Tuple.Create(add, have.Where(n => !wanted.Any(l => Json.Str(l, "name") == n)).ToArray());
        }
        internal static string Origin(string text)
        {
            Uri uri;
            if (!Uri.TryCreate((text ?? "").Trim(), UriKind.Absolute, out uri) || uri.Scheme != "https" || uri.UserInfo.Length > 0 || uri.AbsolutePath != "/" || uri.Query.Length > 0 || uri.Fragment.Length > 0)
                throw new IOException("Укажите HTTPS-адрес Happier без пути, пароля и параметров");
            return uri.GetLeftPart(UriPartial.Authority);
        }
        // Secrets a section needs right now: (name, optional). The server needs its key OR the root password.
        internal static List<string> SecretsFor(string section, Dictionary<string, object> p, Func<string, bool> available)
        {
            var list = new List<string>(); var server = Json.Map(Json.Get(p, "server"));
            Action<object> need = f => { string n = SecretName(f); if (n.Length > 0 && !available(n) && !list.Contains(n)) list.Add(n); };
            switch (section) {
                case ConfigSections.Server: {
                    string key = SecretName(Json.Get(server, "key"));
                    if (key.Length == 0 || !available(key)) { if (SecretName(Json.Get(server, "rootPassword")).Length > 0) need(Json.Get(server, "rootPassword")); else need(Json.Get(server, "key")); }
                    var hop = Json.Map(Json.Get(Route(server, "hop"), "hop"));
                    string hopKey = SecretName(Json.Get(hop, "key"));
                    if (hopKey.Length == 0 || !available(hopKey)) { if (SecretName(Json.Get(hop, "password")).Length > 0) need(Json.Get(hop, "password")); else need(Json.Get(hop, "key")); }
                    break; }
                case ConfigSections.Account: if (Json.Str(Json.Map(Json.Get(p, "happier")), "mode") != "new") need(Json.Get(Json.Map(Json.Get(p, "happier")), "key")); break;
                case ConfigSections.Proxy: need(Json.Get(Json.Map(Json.Get(p, "proxyOut")), "password")); break;
                case ConfigSections.Lan: foreach (var l in Json.Array(Json.Get(p, "lan")).Select(Json.Map)) { need(Json.Get(l, "ovpn")); need(Json.Get(l, "password")); } break;
                case ConfigSections.Bootstrap: {
                    var b = Json.Map(Json.Get(Json.Map(Json.Get(p, "vpn")), "bootstrap")); need(Json.Get(b, "channel"));
                    foreach (var e in Json.Map(Json.Get(b, "entries")).Values) need(e);
                    break; }
            }
            return list;
        }
        // Built-in explanation for standard names (docs/CONFIG.md); a «hint» from the config is added after it.
        internal static string Why(string name, Dictionary<string, object> p, string hint)
        {
            string address = Json.Text(Json.Map(Json.Get(p, "server")), "address", "из конфига");
            string text;
            if (name == "server-root-password") text = "Пароль root сервера " + address + " — его присылает хостинг при покупке сервера. Нужен один раз: программа поставит на сервер свой ключ и дальше входит им.";
            else if (name == "server-key") text = "Закрытый SSH-ключ для входа на сервер " + address + " (текст ключа целиком).";
            else if (name.StartsWith("hop-")) text = (name.Contains("password") ? "Пароль" : "Закрытый ключ") + " промежуточного SSH-сервера (способ «через SSH-сервер»).";
            else if (name == "happier-key") text = "Секретный ключ аккаунта Happier (Happier → Settings → Secret Key). Он же нужен для телефона и других компьютеров.";
            else if (name == "proxy-out-password") text = "Пароль прокси, через который сервер выходит в интернет.";
            else if (name == "vpn-channel" || name.StartsWith("vpn-entry-")) text = "Данные VPN для подключения в обход блокировок (их выдаёт администратор сервера).";
            else if (name.StartsWith("lan-")) text = (name.EndsWith("-ovpn") ? "Файл OpenVPN (.ovpn, текстом)" : "Пароль") + " локальной сети «" + name.Substring(4).Split('-')[0] + "».";
            else text = "Значение секрета «" + name + "» из конфига.";
            return string.IsNullOrEmpty(hint) ? text : text + "\r\nПодсказка: " + hint;
        }
        // Server catalog + this computer's own rows (wizard.localCatalog), cleaned of local paths; shared with SetupWizard.
        internal static Dictionary<string, object> MergeCatalog(Dictionary<string, object> catalog, Dictionary<string, object> config)
        {
            var wizard = Json.Map(Json.Get(config, "wizard")); var local = Json.Map(Json.Get(wizard, "localCatalog"));
            if (!wizard.ContainsKey("localCatalog")) local = Json.Map(Json.Get(config, "transport"));
            var map = new Dictionary<string, object> { { "schema", 1 } };
            foreach (string group in new[] { "entries", "hops", "relays", "cdn" }) {
                var rows = Json.Array(Json.Get(catalog, group)).Select(Json.Map).ToList();
                foreach (var row in Json.Array(Json.Get(local, group)).Select(Json.Map)) {
                    var clean = new Dictionary<string, object>(row); clean.Remove("configPath"); clean.Remove("keyFile"); clean.Remove("knownHostsPath");
                    if (!clean.ContainsKey("ssh") && clean.ContainsKey("alias")) { clean["ssh"] = clean["alias"]; clean.Remove("alias"); }
                    if (!clean.ContainsKey("host") && clean.ContainsKey("server")) { clean["host"] = clean["server"]; clean.Remove("server"); }
                    rows.RemoveAll(r => Json.Str(r, "name") == Json.Str(row, "name")); rows.Add(clean);
                }
                map[group] = rows.Cast<object>().ToArray();
            }
            return map;
        }
    }

    // «Скопировать для ИИ»: never a secret value, only «есть / нет».
    internal static class ConfigAi
    {
        internal const string Hidden = "<есть, скрыт>";
        internal const string Guide = "docs/CONFIG.md";
        internal static string Redact(Dictionary<string, object> profile, IDictionary<string, string> secrets)
        {
            var data = new Dictionary<string, object>(profile);
            data["secrets"] = (secrets ?? new Dictionary<string, string>()).Where(p => p.Key != "kdf" && p.Key != "check" && p.Key != "protected")
                .ToDictionary(p => p.Key, p => (object)(string.IsNullOrEmpty(p.Value) ? "" : Hidden));
            return Json.Encode(data);
        }
        internal static string Request(string current, string pasted, IEnumerable<string> conflicts)
        {
            var text = new StringBuilder();
            text.Append("Помоги поправить конфиг RemoteAgents. Описание полей: ").Append(Guide).Append(" (в репозитории RemoteAgents).\r\n");
            text.Append("Вставленный конфиг расходится с тем, что уже настроено на этом компьютере. Секреты скрыты (\"").Append(Hidden).Append("\"), не проси их присылать.\r\n\r\n");
            text.Append("Расхождения (сейчас / в конфиге):\r\n"); foreach (string c in conflicts) text.Append("- ").Append(c).Append("\r\n");
            text.Append("\r\nТекущий конфиг этого компьютера:\r\n").Append(current).Append("\r\n\r\nВставленный конфиг:\r\n").Append(pasted);
            text.Append("\r\n\r\nВерни один исправленный конфиг целиком (JSON), где для каждого расхождения выбран нужный вариант; секретные поля оставь ссылками {\"secret\": …}.\r\n");
            return text.ToString();
        }
    }

    // Readable config text for the settings tab and the AI request (the framework serializer writes one line
    // and escapes <, >, &, ' as <…; inside JSON strings they are safe as plain characters).
    internal static class ConfigText
    {
        internal static string Pretty(string json)
        {
            var text = new StringBuilder(); int depth = 0; bool inString = false;
            Action newline = () => { text.Append("\r\n").Append(' ', depth * 2); };
            for (int i = 0; i < json.Length; i++) {
                char c = json[i];
                if (inString) {
                    if (c == '\\' && i + 5 < json.Length && json[i + 1] == 'u') {
                        int code;
                        if (int.TryParse(json.Substring(i + 2, 4), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out code) && code >= 0x20 && code != '"' && code != '\\')
                        { text.Append((char)code); i += 5; continue; }
                    }
                    text.Append(c);
                    if (c == '\\' && i + 1 < json.Length) { text.Append(json[++i]); continue; }
                    if (c == '"') inString = false;
                    continue;
                }
                switch (c) {
                    case '"': inString = true; text.Append(c); break;
                    case '{': case '[':
                        int close = i + 1; while (close < json.Length && char.IsWhiteSpace(json[close])) close++;
                        if (close < json.Length && (json[close] == '}' || json[close] == ']')) { text.Append(c).Append(json[close]); i = close; break; }
                        text.Append(c); depth++; newline(); break;
                    case '}': case ']': depth = Math.Max(0, depth - 1); newline(); text.Append(c); break;
                    case ',': text.Append(c); newline(); break;
                    case ':': text.Append(": "); break;
                    default: if (!char.IsWhiteSpace(c)) text.Append(c); break;
                }
            }
            return text.ToString();
        }
    }

    // Where the pasted text comes from: JSON text, an https link, or a file (dragged or next to the EXE).
    internal static class ConfigSource
    {
        internal const int Limit = 1024 * 1024;
        internal enum Kind { Empty, Json, Url, File }
        internal static Kind Classify(string text)
        {
            string t = (text ?? "").Trim().TrimStart('﻿');
            if (t.Length == 0) return Kind.Empty;
            if (t.StartsWith("{")) return Kind.Json;
            if (t.StartsWith("http://", StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Ссылка должна начинаться с https:// — по http конфиг можно подменить в пути");
            if (t.StartsWith("https://", StringComparison.OrdinalIgnoreCase)) { if (t.Any(char.IsWhiteSpace)) throw new InvalidDataException("В поле должна быть одна ссылка без пробелов"); return Kind.Url; }
            string path = t.Trim('"');
            if (path.IndexOfAny(Path.GetInvalidPathChars()) < 0 && Path.IsPathRooted(path) && System.IO.File.Exists(path)) return Kind.File;
            throw new InvalidDataException("Вставьте текст конфига (начинается с «{»), ссылку https:// или перетащите файл конфига");
        }
        internal static string ReadFile(string path)
        {
            path = path.Trim().Trim('"');
            if (new FileInfo(path).Length > Limit) throw new InvalidDataException("Файл больше 1 МБ — это не конфиг RemoteAgents");
            return RequireJson(System.IO.File.ReadAllText(path));
        }
        internal static string RequireJson(string text)
        {
            string t = (text ?? "").TrimStart('﻿', ' ', '\r', '\n', '\t');
            if (!t.StartsWith("{")) throw new InvalidDataException("По ссылке или в файле не JSON-конфиг");
            return t;
        }
        // Only https, also after every redirect.
        internal static Uri Redirect(Uri from, string location)
        {
            Uri next;
            if (string.IsNullOrEmpty(location) || !Uri.TryCreate(from, location, out next)) throw new InvalidDataException("Сервер ссылки вернул неверное перенаправление");
            if (next.Scheme != "https") throw new InvalidDataException("Ссылка перенаправляет на небезопасный адрес (не https) — конфиг не загружен");
            return next;
        }
        internal static string ReadLimited(Stream stream, int limit)
        {
            var buffer = new MemoryStream(); var chunk = new byte[16384]; int n;
            while ((n = stream.Read(chunk, 0, chunk.Length)) > 0) { buffer.Write(chunk, 0, n); if (buffer.Length > limit) throw new InvalidDataException("По ссылке больше 1 МБ — это не конфиг RemoteAgents"); }
            try { return new UTF8Encoding(false, true).GetString(buffer.ToArray()); } catch (DecoderFallbackException) { throw new InvalidDataException("По ссылке не текст в UTF-8"); }
        }
        internal static string Download(string url, CancellationToken token)
        {
            var uri = new Uri(url.Trim());
            if (uri.Scheme != "https") throw new InvalidDataException("Ссылка должна начинаться с https://");
            for (int hop = 0; hop < 5; hop++) {
                token.ThrowIfCancellationRequested();
#pragma warning disable SYSLIB0014
                var request = (HttpWebRequest)WebRequest.Create(uri);
#pragma warning restore SYSLIB0014
                request.AllowAutoRedirect = false; request.Timeout = 20000; request.ReadWriteTimeout = 20000; request.UserAgent = Product.Name;
                try {
                    using (var response = (HttpWebResponse)request.GetResponse()) {
                        int code = (int)response.StatusCode;
                        if (code >= 300 && code < 400) { uri = Redirect(uri, response.Headers["Location"]); continue; }
                        if (response.ContentLength > Limit) throw new InvalidDataException("По ссылке больше 1 МБ — это не конфиг RemoteAgents");
                        using (var body = response.GetResponseStream()) return RequireJson(ReadLimited(body, Limit));
                    }
                } catch (WebException e) {
                    var r = e.Response as HttpWebResponse;
                    if (r != null) { int code = (int)r.StatusCode; using (r) if (code >= 300 && code < 400) { uri = Redirect(uri, r.Headers["Location"]); continue; } throw new IOException("Ссылка не открылась: HTTP " + code); }
                    throw new IOException("Ссылка не открылась: " + e.Status);
                }
            }
            throw new InvalidDataException("Слишком много перенаправлений по ссылке");
        }
        // A config file next to the EXE: exactly one *.json up to 1 MB that declares itself a RemoteAgents config.
        internal static string FindBeside(string directory)
        {
            try {
                var found = Directory.GetFiles(directory, "*.json").Take(50)
                    .Where(f => new FileInfo(f).Length <= Limit && System.IO.File.ReadAllText(f).Contains("\"remoteagents-config\"")).ToArray();
                return found.Length == 1 ? found[0] : null;
            } catch (Exception) { return null; }
        }
    }

#if !PORTABLE_TEST
    // One application of the stored profile: Inspect -> plan -> missing secrets (asked once, before anything runs)
    // -> ConfigEngine with the real actions. Callbacks may arrive on worker threads; the window marshals them.
    internal sealed class ConfigSession
    {
        readonly string home; readonly Func<Task<string>> bundleSource; string bundle;
        readonly Dictionary<string, string> secrets, hints;
        internal Action<string, SectionState, string> Report = delegate { };
        internal Action<string> Log = delegate { };
        internal Func<string, string, string> AskSecret = (name, why) => null;
        Dictionary<string, object> services = new Dictionary<string, object>();
        internal readonly ConcurrentDictionary<string, SectionOutcome> Outcomes = new ConcurrentDictionary<string, SectionOutcome>();
        static readonly object operationsGate = new object();
        internal ConfigSession(string home, Func<Task<string>> bundle, IDictionary<string, string> secrets = null, IDictionary<string, string> hints = null)
        {
            this.home = home; bundleSource = bundle;
            this.secrets = new Dictionary<string, string>(secrets ?? new Dictionary<string, string>()); this.hints = new Dictionary<string, string>(hints ?? new Dictionary<string, string>());
        }
        internal async Task<string> Bundle() { if (bundle == null) bundle = await bundleSource(); return bundle; }
        internal async Task<List<string>> Plan(CancellationToken token)
        {
            await Bundle();
            var desired = ConfigProfile.Load(home); var inspect = new Dictionary<string, object>();
            if (FirstInstall.HasProfile(home)) {
                Log("Проверяю, что уже настроено…");
                try { inspect = await Task.Run(() => WizardRunner.Run(home, bundle, "Inspect", new { }, token)); }
                catch (OperationCanceledException) { throw; }
                catch (Exception e) { Log("Текущее состояние не получено (" + e.Message + "). Применяю все разделы конфига."); }
            }
            services = Json.Map(Json.Get(Json.Map(Json.Get(inspect, "server")), "services"));
            return ConfigPlan.Build(desired, ConfigProfile.Applied(home), ConfigPlan.Ready(inspect, new Configuration(home).Data, desired));
        }
        bool Available(string name) { string v; return (secrets.TryGetValue(name, out v) && v.Length > 0 && v != ConfigAi.Hidden) || SecretVault.Has(home, name); }
        // Pasted value first, then the vault (settings reopened later: root/hop/proxy/LAN passwords live only there).
        string Value(object field)
        {
            string n = ConfigRequests.SecretName(field), v; if (n.Length == 0) return "";
            if (secrets.TryGetValue(n, out v) && v.Length > 0 && v != ConfigAi.Hidden) return v;
            try { return SecretVault.Get(home, n) ?? ""; } catch (InvalidDataException) { return ""; }
        }
        string Hint(string name, Dictionary<string, object> p)
        {
            string h; if (hints.TryGetValue(name, out h) && h.Length > 0) return h;
            // A hint may sit next to the reference anywhere in the profile.
            return FindHint(p, name);
        }
        static string FindHint(object node, string name)
        {
            var map = node as Dictionary<string, object>;
            if (map != null) { if (Json.Str(map, "secret") == name) return Json.Str(map, "hint"); foreach (var v in map.Values) { string h = FindHint(v, name); if (h.Length > 0) return h; } return ""; }
            foreach (var item in Json.Array(node)) { string h = FindHint(item, name); if (h.Length > 0) return h; }
            return "";
        }
        // UI thread: one window per empty secret, with the built-in explanation and the config's hint.
        internal void AskMissing(IEnumerable<string> plan)
        {
            var p = ConfigProfile.Load(home);
            foreach (string s in plan)
                foreach (string name in ConfigRequests.SecretsFor(s, p, Available)) {
                    string value = AskSecret(name, ConfigRequests.Why(name, p, Hint(name, p)));
                    if (string.IsNullOrEmpty(value)) { Log(ConfigSections.Title(s) + ": секрет «" + name + "» не задан — раздел может не пройти"); continue; }
                    SecretVault.Set(home, name, value); secrets[name] = value;
                }
            SecretVault.Materialize(home);
        }
        internal async Task<Dictionary<string, SectionOutcome>> Execute(IList<string> plan, CancellationToken token)
        {
            await Bundle();
            var result = await ConfigEngine.Execute(plan, (s, t) => Task.Run(() => RunSection(s, t), t), (s, state, text) => Report(s, state, text), token);
            foreach (var pair in result) {
                Outcomes[pair.Key] = pair.Value;
                // Timing per section (docs/CONFIG-CONTRACT.md §4): journal codes only, never texts.
                new Journal(home).Write("config." + pair.Key + (pair.Value.Ok ? ".ok " : pair.Value.Pending ? ".pending " : ".failed ") + pair.Value.Ms + "ms");
                Log(ConfigSections.Title(pair.Key) + ": " + pair.Value.Summary + " (" + (pair.Value.Ms / 1000.0).ToString("0.0", CultureInfo.InvariantCulture) + " с)");
            }
            return result;
        }
        SectionOutcome RunSection(string s, CancellationToken token)
        {
            var p = ConfigProfile.Load(home); var config = new Configuration(home).Data; string hash = ConfigSections.Hash(p, s);
            Action<string> progress = line => { Report(s, SectionState.Running, line); Log(ConfigSections.Title(s) + ": " + line); };
            Func<string, object, Dictionary<string, object>> run = (action, request) => WizardRunner.Run(home, bundle, action, request, token, progress);
            SectionOutcome o;
            switch (s) {
                case ConfigSections.Bootstrap: o = SectionOutcome.From(run("Bootstrap", new { }), "VPN для первого подключения включён"); break;
                case ConfigSections.Server: o = Server(p, run); break;
                case ConfigSections.Connection: {
                    var catalog = run("Catalog", new { });
                    o = SectionOutcome.From(run("Connection", new { catalog = ConfigRequests.MergeCatalog(catalog, config), expected = catalog, shared = false }), "Связь работает ✓"); break; }
                case ConfigSections.Bridge: o = SectionOutcome.From(run("Bridge", ConfigRequests.Bridge(p, config)), "Мост проверен ✓"); break;
                case ConfigSections.Account: o = Account(p, config, run, ref hash); break;
                case ConfigSections.Disk: o = SectionOutcome.From(run("Disk", ConfigRequests.Disk(p, DiskBase(), DiskSelection())), "Папки подключены; передача файлов продолжается"); break;
                case ConfigSections.Vpn: o = SectionOutcome.From(run("Vpn", ConfigRequests.Vpn(p)), "VPN настроен", true); break;
                case ConfigSections.Proxy: o = Proxy(p, config, run); break;
                case ConfigSections.Lan: o = Lan(p, config, run); break;
                default: throw new ArgumentException("Неизвестный раздел");
            }
            // Server may have replaced root's password by its own key in the profile (PromoteServerKey).
            if (o.Ok && s == ConfigSections.Server) hash = ConfigSections.Hash(ConfigProfile.Load(home), s);
            if (o.Ok) ConfigProfile.MarkApplied(home, s, hash); else if (!o.Pending) ConfigProfile.MarkApplied(home, s, null);
            if (o.Pending && SectionOutcome.ServerOperation(o.Operation)) Track(o.Operation, s == ConfigSections.Account && o.Operation == "happier");
            return o;
        }
        SectionOutcome Server(Dictionary<string, object> p, Func<string, object, Dictionary<string, object>> run)
        {
            var server = Json.Map(Json.Get(p, "server")); var request = ConfigRequests.Server(home, p);
            var hop = Json.Map(Json.Get(ConfigRequests.Route(server, "hop"), "hop"));
            // Root and hop passwords: one-use in-memory pipes only (never the request file or the journal).
            using (var relay = new PasswordRelay(Value(Json.Get(server, "rootPassword"))))
            using (var hopRelay = new PasswordRelay(Value(Json.Get(hop, "password")), 16)) {
                request["passwordPipe"] = relay.Name; request["askpassExecutable"] = Program.Exe;
                var hopRequest = Json.Get(request, "hop") as Dictionary<string, object>; if (hopRequest != null) hopRequest["passwordPipe"] = hopRelay.Name;
                var result = run("Server", request);
                services = Json.Map(Json.Get(result, "services"));
                foreach (string op in new[] { "disk", "happier" }) if (Json.Str(Json.Map(Json.Get(Json.Map(Json.Get(result, "operations")), op)), "state") == "running") Track(op, false);
                PromoteServerKey(server);
                return SectionOutcome.From(result, "Сервер подключён ✓");
            }
        }
        // Clean VPS (docs/CONFIG.md, server.rootPassword): after a proved Server the program logs in with the key it
        // installed for the worker user. That key goes into the vault and the profile, the root password is cleared,
        // so «Сохранить конфиг в файл» restores access without the hosting password.
        void PromoteServerKey(Dictionary<string, object> server)
        {
            string root = ConfigRequests.SecretName(Json.Get(server, "rootPassword"));
            if (root.Length == 0 || ConfigRequests.SecretName(Json.Get(server, "key")).Length > 0) return;
            try {
                var ssh = Json.Read(Json.Str(Json.Map(Json.Get(new Configuration(home).Data, "transport")), "profilePath"));
                string keyPath = Json.Str(ssh, "keyPath"), login = Json.Str(ssh, "login");
                if (keyPath.Length == 0 || login.Length == 0 || login == "root" || !File.Exists(keyPath) || Json.Str(ssh, "serverAddress") != Json.Str(server, "address")) return;
                SecretVault.Set(home, "server-key", Files.LF(File.ReadAllText(keyPath)));
                ConfigProfile.Update(home, pr => {
                    var sv = new Dictionary<string, object>(Json.Map(Json.Get(pr, "server")));
                    sv.Remove("rootPassword"); sv["login"] = login; sv["key"] = new Dictionary<string, object> { { "secret", "server-key" } }; pr["server"] = sv;
                });
                SecretVault.Set(home, root, "");
                SecretVault.Materialize(home);
                Log("Сервер: пароль root больше не нужен — программа входит своим ключом; он сохранится в «Сохранить конфиг в файл».");
            } catch (Exception e) when (e is IOException || e is InvalidDataException || e is UnauthorizedAccessException) { Log("Сервер: ключ для восстановления не сохранён (" + e.Message + "). Пароль root пока остаётся в секретах."); }
        }
        SectionOutcome Account(Dictionary<string, object> p, Dictionary<string, object> config, Func<string, object, Dictionary<string, object>> run, ref string hash)
        {
            var h = Json.Map(Json.Get(p, "happier")); bool create = Json.Str(h, "mode") == "new";
            string name = ConfigRequests.SecretName(Json.Get(h, "key")); if (name.Length == 0) name = "happier-key";
            var request = ConfigRequests.Account(p, services, config);
            string key = create ? HappierKey.Create() : Value(Json.Get(h, "key"));
            // The key waits in secrets/happier-pending.key; Wizard.ps1 applies it now or after the Happier install.
            if (key.Length > 0) AccountDiskSetup.SaveKey(home, key, "happier-pending.key");
            Dictionary<string, object> result;
            try { result = run("Account", request); }
            catch {
                if (create) foreach (var f in new[] { Path.Combine(home, "secrets", "happier-pending.key"), Path.Combine(home, "state", "happier-pending.json") }) if (File.Exists(f)) File.Delete(f);
                throw;
            }
            if (create) {
                // A new account becomes «same» with its key in the vault: «Сохранить конфиг» carries it, a re-apply never creates another one.
                SecretVault.Set(home, name, key); secrets[name] = key;
                ConfigProfile.Update(home, pr => { var hh = new Dictionary<string, object>(Json.Map(Json.Get(pr, "happier"))); hh["mode"] = "same"; hh["key"] = new Dictionary<string, object> { { "secret", name } }; pr["happier"] = hh; });
                hash = ConfigSections.Hash(ConfigProfile.Load(home), ConfigSections.Account);
                Log("Happier: создан новый аккаунт. Ключ сохранён в секретах программы и попадёт в «Сохранить конфиг в файл»; для телефона — Happier → Restore with Secret Key.");
            }
            return SectionOutcome.From(result, "Аккаунт Happier подключён ✓");
        }
        // Root on the server for Proxy/Lan: the key as root, otherwise the root password from the config,
        // otherwise «command» — an exact command for the administrator (no secrets in it) goes to the journal.
        Tuple<string, string, PasswordRelay> RootAccess(Dictionary<string, object> p, Func<string, object, Dictionary<string, object>> run)
        {
            string mode = Json.Str(run("AdminProbe", new { }), "mode");
            string root = Value(Json.Get(Json.Map(Json.Get(p, "server")), "rootPassword"));
            if (mode == "command" && root.Length > 0) return Tuple.Create("password", "root", new PasswordRelay(root, 8));
            return Tuple.Create(mode, "", (PasswordRelay)null);
        }
        void AddRoot(Dictionary<string, object> request, Tuple<string, string, PasswordRelay> access)
        { request["mode"] = access.Item1; request["adminLogin"] = access.Item2; request["passwordPipe"] = access.Item3 == null ? "" : access.Item3.Name; request["askpassExecutable"] = Program.Exe; }
        SectionOutcome Proxy(Dictionary<string, object> p, Dictionary<string, object> config, Func<string, object, Dictionary<string, object>> run)
        {
            var request = ConfigRequests.Proxy(p, config); var x = Json.Map(Json.Get(p, "proxyOut"));
            string login = Json.Str(x, "login"), password = Value(Json.Get(x, "password")), file = Path.Combine(home, "secrets", "proxy-out.json");
            if (login.Length == 0) { if (File.Exists(file)) File.Delete(file); }
            else if (password.Length > 0) { AccountDiskSetup.ProtectSecrets(home); Files.Atomic(file, Json.Encode(new Dictionary<string, object> { { "username", login }, { "password", password } }) + "\n"); }
            var access = RootAccess(p, run);
            using (access.Item3) {
                AddRoot(request, access); var result = run("Proxy", request);
                if (Json.Str(result, "command").Length > 0) Log("Прокси сервера: нужна команда администратора сервера (секретов в ней нет): " + Json.Str(result, "command"));
                return SectionOutcome.From(result, "Прокси сервера подтверждён ✓");
            }
        }
        SectionOutcome Lan(Dictionary<string, object> p, Dictionary<string, object> config, Func<string, object, Dictionary<string, object>> run)
        {
            var change = ConfigRequests.Lan(home, p, config);
            if (change.Item1.Length == 0 && change.Item2.Length == 0) return new SectionOutcome { Ok = true, Summary = "Без изменений" };
            var access = RootAccess(p, run); var lines = new List<string>(); bool ok = true;
            using (access.Item3) {
                foreach (var request in change.Item1) {
                    var item = Json.Array(Json.Get(p, "lan")).Select(Json.Map).First(l => Json.Str(l, "name") == Json.Str(request, "name"));
                    string user = Json.Str(item, "login"), password = Value(Json.Get(item, "password"));
                    using (var secret = new PasswordRelay(user.Length > 0 ? Json.Encode(new Dictionary<string, object> { { "username", user }, { "password", password } }) : "")) {
                        request["secretPipe"] = secret.Name; AddRoot(request, access);
                        try { var r = run("Lan", request); ok &= Json.Bool(r, "ok"); lines.Add(Json.Str(request, "name") + ": " + Json.Text(r, "summary", Json.Bool(r, "ok") ? "подключена" : "ждёт администратора"));
                            if (Json.Str(r, "command").Length > 0) Log("Локальная сеть «" + Json.Str(request, "name") + "»: команда администратора сервера: " + Json.Str(r, "command")); }
                        catch (OperationCanceledException) { throw; }
                        catch (Exception e) { ok = false; lines.Add(Json.Str(request, "name") + ": " + e.Message); }
                    }
                }
                foreach (string name in change.Item2) {
                    var request = new Dictionary<string, object> { { "name", name } }; AddRoot(request, access);
                    try { var r = run("LanRemove", request); ok &= Json.Bool(r, "ok"); lines.Add(name + ": " + Json.Text(r, "summary", "удалена")); }
                    catch (OperationCanceledException) { throw; }
                    catch (Exception e) { ok = false; lines.Add(name + ": " + e.Message); }
                }
            }
            return new SectionOutcome { Ok = ok, Summary = string.Join("; ", lines) };
        }
        void Track(string operation, bool pendingAccount)
        {
            lock (operationsGate) {
                var state = ServerOperations.Load(home); var tracked = Json.Strings(Json.Get(state, "tracked")).ToList();
                if (operation != ServerOperations.Account && !tracked.Contains(operation)) tracked.Add(operation);
                ServerOperations.Save(home, tracked, Json.Map(Json.Get(state, "operations")), pendingAccount || Json.Bool(state, "pendingAccount"));
            }
        }
        // Detached server installs (Happier, Syncthing) finish on their own; follow them with short status calls and
        // complete what waited for them. The tray does the same after the window is closed (TrayContext.CheckOperations).
        internal async Task FollowPending(CancellationToken token)
        {
            while (!token.IsCancellationRequested) {
                var waiting = Outcomes.Where(o => o.Value.Pending && SectionOutcome.ServerOperation(o.Value.Operation)).ToArray();
                if (waiting.Length == 0) return;
                await Task.Delay(12000, token);
                Dictionary<string, object> status;
                try { status = await Task.Run(() => WizardRunner.Run(home, bundle, "Operation", new { operations = waiting.Select(w => w.Value.Operation).Distinct().ToArray() }, token)); }
                catch (OperationCanceledException) { throw; } catch (Exception e) { Log("Состояние установки на сервере не получено: " + e.Message + ". Повторю позже"); continue; }
                var operations = Json.Map(Json.Get(status, "operations"));
                foreach (var w in waiting) {
                    var op = Json.Map(Json.Get(operations, w.Value.Operation)); string state = Json.Str(op, "state");
                    if (state == "running") { Report(w.Key, SectionState.Pending, Json.Text(op, "text", "идёт установка на сервере")); continue; }
                    if (state == "failed") { Outcomes[w.Key] = new SectionOutcome { Summary = Json.Text(op, "text", "установка на сервере не удалась") }; Report(w.Key, SectionState.Failed, Outcomes[w.Key].Summary); continue; }
                    if (state != "finished") continue;
                    if (w.Key == ConfigSections.Account && Json.Bool(status, "pendingAccount")) {
                        try { var r = await Task.Run(() => WizardRunner.Run(home, bundle, "ResumeAccount", new { }, token)); var o = SectionOutcome.From(r, "Аккаунт Happier подключён ✓"); Outcomes[w.Key] = o;
                            if (o.Ok) ConfigProfile.MarkApplied(home, w.Key, ConfigSections.Hash(ConfigProfile.Load(home), w.Key)); Report(w.Key, o.Ok ? SectionState.Done : SectionState.Pending, o.Summary); }
                        catch (OperationCanceledException) { throw; } catch (Exception e) { Outcomes[w.Key] = new SectionOutcome { Summary = e.Message }; Report(w.Key, SectionState.Failed, e.Message); }
                    } else await Execute(new[] { w.Key }, token);
                }
            }
        }
        internal async Task<SectionOutcome> Activate(CancellationToken token)
        {
            await Bundle();
            var r = await Task.Run(() => WizardRunner.Run(home, bundle, "Activate", new { }, token, line => Log("Итог: " + line)));
            return SectionOutcome.From(r, "Настройки сохранены");
        }
        internal static string DiskBase()
        {
            string value = Files.ReadLine(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RemoteDisk", "base.txt"));
            return value.Length > 0 ? value : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Disk");
        }
        // Folders actually chosen on this computer (RemoteDisk selection.json; the install placeholder is not a choice).
        internal static string[] DiskSelection()
        {
            try {
                var s = Json.Read(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RemoteDisk", "selection.json"));
                return Json.Bool(s, "placeholder") ? null : Json.Strings(Json.Get(s, "paths"));
            } catch (Exception) { return null; }
        }
        // After «Подробно» (step-by-step sections) the profile follows what they configured; those sections count as applied.
        internal static void SyncFromSettings(string home)
        {
            var config = new Configuration(home).Data; string address = "", login = "";
            try { var t = Json.Read(Json.Str(Json.Map(Json.Get(config, "transport")), "profilePath")); address = Json.Str(t, "serverAddress"); login = Json.Str(t, "login"); } catch (Exception) { }
            Dictionary<string, object> updated = null;
            ConfigProfile.Update(home, p => { updated = ConfigProfile.SyncFromSettings(p, config, DiskBase(), DiskSelection(), address, login); p.Clear(); foreach (var pair in updated) p[pair.Key] = pair.Value; });
            foreach (string s in ConfigSections.Order) if (ConfigSections.Present(updated, s)) ConfigProfile.MarkApplied(home, s, ConfigSections.Hash(updated, s));
        }
    }
#endif
}
