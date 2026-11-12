// End-to-end harness for app/launcher/tests/test_config_e2e.py (loopback stand, Linux, net10).
// The same sources as the EXE: ConfigBundle/SecretVault (stream A), ConfigEngine/ConfigRequests/ConfigPlan (stream D);
// the actions are the real build/Wizard.ps1 CLI (stream C). Secrets never appear in argv or output.
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace RemoteAgents.Launcher
{
    internal static class ConfigE2E
    {
        static string home, repo, pwsh;
        static readonly Stopwatch clock = Stopwatch.StartNew();

        public static int Main(string[] args)
        {
            try {
                if (args.Length == 3 && args[0] == "--apply") return Apply(args[1], args[2]);
                if (args.Length == 4 && args[0] == "--run") { home = args[1]; repo = args[2]; pwsh = args[3]; return Run(); }
                // The stand's RemoteAgents.exe: ssh ProxyCommand of the `proxy` route (channel-first scenario).
                if (args.Length > 0 && args[0] == "--proxy-connect") return ProxyRelay.Run(args);
                Console.Error.WriteLine("usage: --apply <home> <config> | --run <home> <repo> <pwsh> | --proxy-connect <socks|http> <host> <port> <dest> <port>"); return 2;
            } catch (Exception e) { Console.Error.WriteLine("E2E: " + e.GetType().Name + ": " + e.Message); return 1; }
        }

        // Paste path of the window: Parse (CRLF) -> master password once -> Store -> Materialize.
        static int Apply(string target, string file)
        {
            string master = Environment.GetEnvironmentVariable("RA_E2E_MASTER") ?? "";
            string text = File.ReadAllText(file).Replace("\r\n", "\n").Replace("\n", "\r\n");
            var parsed = ConfigBundle.Parse(text);
            if (!parsed.Locked) throw new InvalidDataException("ожидался конфиг, закрытый мастер-паролем");
            bool wrongRefused = false;
            try { ConfigBundle.Unlock(parsed, master + "x"); } catch (InvalidDataException) { wrongRefused = true; }
            parsed = ConfigBundle.Unlock(parsed, master);
            var conflicts = ConfigBundle.Conflicts(target, parsed);
            ConfigBundle.Store(target, parsed, parsed.Profile.Keys);
            SecretVault.Materialize(target);
            var manifest = Json.Read(SecretVault.MaterializedPath(target));
            string key = parsed.Secrets["server-key"];
            string forAi = ConfigBundle.ExportForAi(target), full = ConfigBundle.Export(target, null);
            var back = ConfigBundle.Parse(full);
            Console.WriteLine(Json.Encode(new Dictionary<string, object> {
                { "wrongMasterRefused", wrongRefused }, { "conflicts", conflicts.Length }, { "missing", parsed.Missing },
                { "serverKeyFile", Json.Str(manifest, "serverKeyFile") },
                { "keyMaterialized", File.Exists(Json.Str(manifest, "serverKeyFile")) && File.ReadAllText(Json.Str(manifest, "serverKeyFile")) == Files.LF(key) },
                { "aiHasNoKey", !forAi.Contains(key.Trim().Split('\n')[1]) && Json.Str(Json.Map(Json.Get(Json.Map(Json.Parse(forAi)), "secrets")), "server-key") == ConfigBundle.Hidden },
                { "fullExportRoundtrip", back.Secrets["server-key"] == key },
                { "deviceName", ConfigProfile.DeviceName(ConfigProfile.Load(target)) } }));
            return 0;
        }

        // The window's run: plan by difference -> ConfigEngine (Server, then Connection/Bridge/Account/Disk/Vpn at once).
        // Bootstrap, Server, Connection and Vpn are the real actions; Bridge/Account/Disk need Windows/Happier/Syncthing and are stand-ins.
        static int Run()
        {
            var desired = ConfigProfile.Load(home);
            var plan = ConfigPlan.Build(desired, new Dictionary<string, string>(), new Dictionary<string, bool>());
            var times = new ConcurrentDictionary<string, long[]>();
            Func<string, CancellationToken, Task<SectionOutcome>> run = (s, token) => Task.Run(() => {
                long start = clock.ElapsedMilliseconds; SectionOutcome o;
                try {
                    var p = ConfigProfile.Load(home); var config = new Configuration(home).Data;
                    switch (s) {
                        // Same request as the window's RunSection (channel first: the transport daemon, no TUN).
                        case ConfigSections.Bootstrap: o = SectionOutcome.From(Invoke("Bootstrap", new Dictionary<string, object>()), "Канал до сервера поднят"); break;
                        case ConfigSections.Server: {
                            // Stand: no Happier/Syncthing downloads into the temporary server HOME (their sections are stand-ins).
                            var request = ConfigRequests.Server(home, p); request["installMissing"] = false;
                            // A stand RemoteAgents.exe (channel scenario) carries --proxy-connect, as Program.Exe does in the window.
                            string exe = Path.Combine(home, "RemoteAgents.exe"); if (File.Exists(exe)) request["askpassExecutable"] = exe;
                            o = SectionOutcome.From(Invoke("Server", request), "Сервер подключён"); break; }
                        case ConfigSections.Connection: {
                            var catalog = Invoke("Catalog", new Dictionary<string, object>());
                            o = SectionOutcome.From(Invoke("Connection", new Dictionary<string, object> { { "catalog", ConfigRequests.MergeCatalog(catalog, config) }, { "expected", catalog }, { "shared", false } }), "Связь работает");
                            break; }
                        case ConfigSections.Vpn: o = SectionOutcome.From(Invoke("Vpn", ConfigRequests.Vpn(p)), "VPN настроен", true); break;
                        default:
                            // Request builders of the real sections are still exercised.
                            if (s == ConfigSections.Bridge) ConfigRequests.Bridge(p, config);
                            if (s == ConfigSections.Disk) ConfigRequests.Disk(p, Path.Combine(home, "Disk"), null);
                            Thread.Sleep(1500); o = new SectionOutcome { Ok = true, Summary = "стенд (Windows/Happier/Syncthing недоступны на Linux)" }; break;
                    }
                } catch (Exception e) when (!(e is IOException)) { Console.Error.WriteLine(s + ": " + e); throw; }
                finally { times[s] = new[] { start, clock.ElapsedMilliseconds }; }
                return o;
            }, token);
            var states = new ConcurrentDictionary<string, string>();
            long engineStart = clock.ElapsedMilliseconds;
            var result = ConfigEngine.Execute(plan, run, (s, st, text) => states[s] = st.ToString(), CancellationToken.None).GetAwaiter().GetResult();
            long[] server, connection; times.TryGetValue(ConfigSections.Server, out server); times.TryGetValue(ConfigSections.Connection, out connection);
            var parallel = ConfigSections.Parallel.Where(times.ContainsKey).ToArray();
            long overlap = parallel.Length < 2 ? 0 : parallel.Select(s => times[s][1]).Min() - parallel.Select(s => times[s][0]).Max();
            SectionOutcome boot; result.TryGetValue(ConfigSections.Bootstrap, out boot);
            Console.WriteLine(Json.Encode(new Dictionary<string, object> {
                { "plan", plan.ToArray() },
                { "sections", result.ToDictionary(r => r.Key, r => (object)new Dictionary<string, object> { { "ok", r.Value.Ok }, { "pending", r.Value.Pending }, { "summary", r.Value.Summary },
                    { "state", states.ContainsKey(r.Key) ? states[r.Key] : "" }, { "startMs", times.ContainsKey(r.Key) ? times[r.Key][0] : -1 }, { "endMs", times.ContainsKey(r.Key) ? times[r.Key][1] : -1 } }) },
                { "serverMs", server == null ? -1 : server[1] - server[0] },
                { "serverStartToConnectionOkMs", server == null || connection == null ? -1 : connection[1] - server[0] },
                // «Запустить → Сервер ✅»: from the engine start (Bootstrap included) to a successful Server.
                { "startToServerOkMs", server == null || !result.ContainsKey(ConfigSections.Server) || !result[ConfigSections.Server].Ok ? -1 : server[1] - engineStart },
                { "bootstrap", boot == null ? null : (object)new Dictionary<string, object> { { "ok", Json.Bool(boot.Result, "ok", true) && boot.Ok },
                    { "vpn", Json.Str(boot.Result, "vpn") }, { "channel", Json.Str(boot.Result, "channel") }, { "summary", Json.Str(boot.Result, "summary") } } },
                { "parallelOverlapMs", overlap } }));
            return result.Values.All(o => o.Ok) ? 0 : 1;
        }

        // Same CLI as WizardRunner.Run: powershell -File build/Wizard.ps1 -Home -Action -RequestFile -ProgressFile.
        static Dictionary<string, object> Invoke(string action, object request)
        {
            string id = Guid.NewGuid().ToString("N"), state = Path.Combine(home, "state");
            Directory.CreateDirectory(state);
            string requestFile = Path.Combine(state, "e2e-request-" + id + ".json"), progress = requestFile + ".progress";
            Files.Atomic(requestFile, Json.Encode(request) + "\r\n");
            try {
                var si = new ProcessStartInfo(pwsh) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true };
                foreach (string a in new[] { "-NoProfile", "-NonInteractive", "-File", Path.Combine(repo, "build", "Wizard.ps1"), "-Home", home, "-Action", action, "-RequestFile", requestFile, "-ProgressFile", progress }) si.ArgumentList.Add(a);
                si.Environment["LOCALAPPDATA"] = Path.GetDirectoryName(home);
                using (var p = Process.Start(si)) {
                    p.StandardInput.Close();
                    var output = p.StandardOutput.ReadToEndAsync(); var errors = p.StandardError.ReadToEndAsync();
                    if (!p.WaitForExit(300000)) { p.Kill(true); throw new TimeoutException(action + ": таймаут"); }
                    if (File.Exists(progress)) foreach (string line in File.ReadAllLines(progress)) Console.Error.WriteLine("[" + action + "] " + Json.Str(Json.Map(Json.Parse(line)), "text"));
                    var text = output.Result.Trim(); var last = text.Split('\n').Last().Trim();
                    Dictionary<string, object> response;
                    try { response = Json.Map(Json.Parse(last)); } catch (Exception) { throw new IOException(action + ": нет JSON-ответа: " + text + " " + errors.Result); }
                    if (p.ExitCode != 0 || !Json.Bool(response, "ok")) throw new IOException(action + ": " + Json.Str(response, "reason"));
                    return Json.Map(Json.Get(response, "result"));
                }
            } finally { foreach (string f in new[] { requestFile, progress }) if (File.Exists(f)) File.Delete(f); }
        }
    }
}
