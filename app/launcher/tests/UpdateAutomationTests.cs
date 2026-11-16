using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Diagnostics;
using System.IO.Compression;

namespace RemoteAgents.Launcher
{
    internal static class UpdateAutomationTests
    {
        static int checks;
        static void Check(bool value, string label) { if (!value) throw new Exception("UPDATE: " + label); checks++; }
        static void Refuse(Action action, string label) { try { action(); } catch (ConfigCompatibilityException) { checks++; return; } throw new Exception("UPDATE accepted " + label); }
        static string FixtureRoot()
        {
            for (var dir = new DirectoryInfo(Environment.CurrentDirectory); dir != null; dir = dir.Parent) {
                string root = Path.Combine(dir.FullName, "app", "launcher", "tests", "fixtures", "update"); if (Directory.Exists(root)) return root;
            }
            throw new Exception("Missing update fixtures");
        }
        public static int Main(string[] args)
        {
            int code = UpdateSelfTests.Run(args[0]); if (code != 0) return code;
            Run(args[0]); Console.WriteLine("PASS: existing update transaction " + Json.Int(Json.Read(Path.Combine(args[0], "selftest-result.json")), "count", 0) + " checks"); return 0;
        }
        internal static void Run(string temp)
        {
            string root = Path.Combine(temp, "automation"); Directory.CreateDirectory(root);
            var settings = Json.Map(null); Check(UpdatePolicy.Defaults(settings), "missing update migrated");
            var update = Json.Map(settings["update"]);
            Check(Json.Bool(update, "enabled") && Json.Bool(update, "auto") && UpdatePolicy.Interval(update) == 6, "all defaults enabled");
            Check(!UpdatePolicy.Defaults(settings), "migration idempotent");
            update["enabled"] = false; update["auto"] = false; UpdatePolicy.Defaults(settings);
            Check(!Json.Bool(update, "enabled") && !Json.Bool(update, "auto"), "explicit choices preserved");
            var legacy = Json.Map(null); legacy["update"] = new Dictionary<string, object> { { "enabled", false }, { "remoteDir", "~/custom/dist" } };
            Check(UpdatePolicy.Defaults(legacy), "old self-written default migrated");
            var migrated = Json.Map(legacy["update"]);
            Check(Json.Bool(migrated, "enabled") && Json.Bool(migrated, "auto") && Json.Str(migrated, "remoteDir") == "~/custom/dist", "old disabled default becomes auto-update, remoteDir kept");
            var schedule = new UpdateSchedule(); var now = DateTime.UtcNow;
            update["enabled"] = true; Check(schedule.Due(now, update, false), "startup check"); schedule.Started(now, update);
            Check(!schedule.Due(now.AddHours(5.99), update, false) && schedule.Due(now.AddHours(6), update, false), "six hour retry after every result");
            update["intervalHours"] = 2; schedule.Started(now, update); Check(schedule.Due(now.AddHours(2), update, false), "configured interval");
            Check(!schedule.Due(now.AddHours(6), update, true), "check waits mutations");
            update["enabled"] = false; Check(!schedule.Due(now.AddHours(8), update, false), "disabled means no requests");
            Check(!UpdateSchedule.Safe("применение конфига", false, false, false) && !UpdateSchedule.Safe("", true, false, false) &&
                !UpdateSchedule.Safe("", false, true, false) && !UpdateSchedule.Safe("", false, false, true) && UpdateSchedule.Safe("", false, false, false), "config / Disk / wizard / bridge wait then resume");
            var record = Json.Map(Json.Parse("{\r\n\"schema\":1,\"operations\":[{\"pid\":123,\"started\":456}]}"));
            Check(UpdateEnvironment.Active(record, (pid, stamp) => pid == 123 && stamp == "456"), "live bridge process blocks");
            Check(!UpdateEnvironment.Active(record, (pid, stamp) => false), "finished or reused bridge PID releases");
            Check(UpdateEnvironment.Active(Json.Map(Json.Parse("{\"schema\":9}")), (p, s) => false), "unknown coordination state defers");
            string cfg = Path.Combine(root, "config.json");
            foreach (var fixture in Directory.GetFiles(FixtureRoot(), "*.json")) {
                File.WriteAllText(cfg, File.ReadAllText(fixture).Replace("\n", "\r\n"), Files.Utf8); string before = Files.Hash(cfg);
                var migrated = UpdatePolicy.Compatible(cfg); Check(Json.Int(migrated, "schema", 0) == 1 && migrated.ContainsKey("update"), "old schema accepted and translated");
                Check(Files.Hash(cfg) == before, "candidate check never writes config");
            }
            foreach (string bad in new[] { "{\"schema\":2}", "{\"schema\":1,\"profile\":{\"kind\":\"remoteagents-config\",\"schema\":2}}", "{\"update\":{\"auto\":\"false\"}}", "broken" }) {
                File.WriteAllText(cfg, bad); Refuse(() => UpdatePolicy.Compatible(cfg), "unsupported config");
            }
            var m = Manifest.Parse(Json.Encode(new { version = "2.0.0", file = "2.zip", sha256 = new string('a',64), size = 1, minLauncher = "1.0.0", configSchema = 1, launcher = new { version = "1.4.0.0", sha256 = new string('b',64) } }));
            int reads = 0;
            Func<Manifest> read = () => { reads++; return m; };
            Check(UpdateProbe.Read(read, "1.0.0", "1.4.0", v => false, true).Offer == UpdateOffer.Available && reads == 1, "one manifest request offers update");
            Check(UpdateProbe.Read(read, "2.0.0", "1.4.0", v => false, true).Offer == UpdateOffer.Current, "no new version");
            Check(UpdateProbe.Read(read, "1.0.0", "1.4.0", v => true, true).Offer == UpdateOffer.Bad, "bad version never offered");
            Check(UpdateProbe.Read(read, "1.0.0", "1.4.0", v => false, false).Offer == UpdateOffer.ManualOnly, "auto false never installs even on button");
            Check(UpdateProbe.Read(() => { throw new IOException(); }, "1", "1", v => false, true).Offer == UpdateOffer.Failed, "offline stays quiet");
            Check(UpdateProbe.Read(() => Manifest.Parse("broken\r\n"), "1", "1", v => false, true).Offer == UpdateOffer.Failed, "corrupt manifest stays quiet");
            m.Minimum = "9.0"; Check(UpdateProbe.Read(read,"1","1.4",v=>false,true).Offer == UpdateOffer.NeedsInstaller,"minimum enforced");
            // Compatibility is checked inside the existing stage transaction BEFORE current/image switches.
            string compatHome = Path.Combine(root, "compat-install"); var compatEngine = new UpdateEngine(compatHome, "1.4.0");
            Directory.CreateDirectory(compatEngine.Folder("1.0.0"));
            string components = "[{\"name\":\"test\",\"exe\":\"unused\"}]";
            File.WriteAllText(Path.Combine(compatEngine.Folder("1.0.0"), "components.json"), components); compatEngine.Activate("1.0.0");
            string archive = Path.Combine(root, "compat.zip");
            using (var z = ZipFile.Open(archive, ZipArchiveMode.Create)) {
                using (var w = new StreamWriter(z.CreateEntry("components.json").Open())) w.Write(components);
                using (var w = new StreamWriter(z.CreateEntry("selftest.ps1").Open())) w.Write("exit 0");
                using (var w = z.CreateEntry(Product.ExeName).Open()) using (var r = File.OpenRead(typeof(UpdateAutomationTests).Assembly.Location)) r.CopyTo(w);
            }
            var staged = Manifest.Parse(Json.Encode(new { version="2.0.0",file="compat.zip",sha256=Files.Hash(archive),size=new FileInfo(archive).Length,configSchema=1,
                launcher=new {version=FileVersionInfo.GetVersionInfo(typeof(UpdateAutomationTests).Assembly.Location).FileVersion,sha256=Files.Hash(typeof(UpdateAutomationTests).Assembly.Location)} }));
            string activeConfig = Path.Combine(compatHome,"config.json"), secret = Path.Combine(compatHome,"secrets","untouched");
            Directory.CreateDirectory(Path.GetDirectoryName(secret)); File.WriteAllText(secret,"private test sentinel"); string secretHash=Files.Hash(secret);
            File.WriteAllText(activeConfig,"{\"schema\":2}"); string configHash=Files.Hash(activeConfig);
            Action stage = () => compatEngine.Prepare(staged, p => File.Copy(archive,p,true), f => { UpdatePolicy.Compatible(activeConfig); return true; }, (d,f)=>{}, CancellationToken.None);
            Refuse(stage,"incompatible config before activation");
            Check(compatEngine.Current=="1.0.0" && !compatEngine.Pending && !compatEngine.IsBad(staged.Version) && !Directory.Exists(compatEngine.Folder(staged.Version)), "refused update leaves running version and allows corrected config");
            Check(Files.Hash(activeConfig)==configHash && Files.Hash(secret)==secretHash,"refusal keeps config and secrets byte for byte");
            File.WriteAllText(activeConfig,"{\"schema\":1}");stage();compatEngine.Activate(staged.Version);
            Check(compatEngine.Observe(true)=="accepted" && Files.Hash(secret)==secretHash,"corrected old config can update without touching secrets");
            // The actual image transaction uses real managed PE resources, even under Linux.
            string home = Path.Combine(root, "installed"); var engine = new UpdateEngine(home, "1.4.0");
            Action<string> bundle = v => { Directory.CreateDirectory(engine.Folder(v)); Json.Write(Path.Combine(engine.Folder(v),"components.json"), new[] { new { name="test", exe="unused" } }); };
            bundle("1.0.0"); bundle("2.0.0"); engine.Activate("1.0.0");
            string target = Path.Combine(home, Product.ExeName), candidate = Path.Combine(engine.Folder("2.0.0"), Product.ExeName);
            File.WriteAllText(target, "old image"); string oldHash = Files.Hash(target);
            File.Copy(typeof(UpdateAutomationTests).Assembly.Location, candidate);
            m.Minimum = "1.0"; m.LauncherVersion = FileVersionInfo.GetVersionInfo(candidate).FileVersion; m.LauncherHash = Files.Hash(candidate);
            UpgradeInstaller.ActivatePrepared(home, engine, m);
            Check(engine.Pending && engine.Current == "2.0.0" && Files.Hash(target) == m.LauncherHash, "EXE and bundle switch together");
            Check(UpgradeInstaller.ObserveImage(home, engine, false, "", DateTime.UtcNow.AddSeconds(121)) == "rollback" && engine.Current == "1.0.0" && Files.Hash(target) == oldHash && engine.IsBad("2.0.0"), "health deadline rolls back EXE and bundle");
            // Fresh release is accepted only after both module and image health are acknowledged.
            bundle("3.0.0"); File.Copy(candidate, Path.Combine(engine.Folder("3.0.0"), Product.ExeName)); m.Version = "3.0.0";
            UpgradeInstaller.ActivatePrepared(home, engine, m);
            Check(engine.Observe(true) == "accepted" && UpgradeInstaller.ObserveImage(home, engine, true, "accepted") == "accepted", "successful image transaction");
            var receipt = Json.Map(Json.Parse(Json.Encode(new { session="test-session",parentPid=100,expiresUtc=now.AddSeconds(60).ToString("o") })));
            Check(VpnUpdateHandoff.Valid(receipt,"test-session",100,now) && !VpnUpdateHandoff.Valid(receipt,"foreign",100,now) && !VpnUpdateHandoff.Valid(receipt,"test-session",101,now) && !VpnUpdateHandoff.Valid(receipt,"test-session",100,now.AddSeconds(91)), "VPN handoff bounded and bound to parent/session");
            Console.WriteLine("PASS: update automation " + checks + " checks");
        }
    }
}
