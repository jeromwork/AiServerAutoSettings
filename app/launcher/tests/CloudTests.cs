using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
namespace RemoteAgents.Launcher
{
    internal static class CloudTests
    {
        static int checks;
        static void Check(bool ok, string message) { if (!ok) throw new Exception("Cloud: " + message); checks++; }
        static Dictionary<string, object> Map(string json) { return Json.Map(Json.Parse(json)); }
        static void Reject(string json)
        { bool rejected = false; try { ConfigBundle.Parse(json); } catch (InvalidDataException) { rejected = true; } Check(rejected, "schema rejected invalid cloud"); }
        internal static void Run()
        {
            var profile = ConfigBundle.D("kind", "remoteagents-config", "schema", 1,
                "cloud", ConfigBundle.D("vendor", "mailru", "login", "user@mail.ru", "password", ConfigBundle.D("secret", "custom-cloud"), "remoteRoot", "Диск", "pollSeconds", 20),
                "secrets", ConfigBundle.D("custom-cloud", "fake-cloud-password"));
            var parsed = ConfigBundle.Parse(Json.Encode(profile).Replace(",", ",\r\n"));
            Check(parsed.Hints["custom-cloud"].Contains("внешних приложений"), "field supplies hint even with a custom name");
            Check(ConfigSections.Present(parsed.Profile, ConfigSections.Cloud), "cloud is a section");
            Check(!ConfigSections.Present(Map("{}"), ConfigSections.Cloud), "absent cloud has no section");
            Check(!ConfigSections.Known("disk") && ConfigSections.Known("cloud"), "profile keys retired");
            var old = ConfigBundle.Parse("{\r\n\"kind\":\"remoteagents-config\",\"schema\":1,\"disk\":{\"unexpected\":[false,\"legacy\"]},\"components\":{\"disk\":{\"enabled\":true}}\r\n}");
            Check(old.LegacyDiskIgnored && !old.Profile.ContainsKey("disk") && !Json.Map(old.Profile["components"]).ContainsKey("disk"), "old disk accepted and discarded before validation");
            object cloud = profile["cloud"];
            foreach (object invalid in new object[] { new object[0], "mailru", ConfigBundle.D("vendor", "other", "login", "a", "password", ConfigBundle.D("secret", "p")), ConfigBundle.D("vendor", "mailru", "login", "a", "password", "literal"), ConfigBundle.D("vendor", "mailru", "login", "a", "password", ConfigBundle.D("secret", "p"), "pollSeconds", 0) }) {
                profile["cloud"] = invalid; Reject(Json.Encode(profile));
            }
            profile["cloud"] = new object[] { cloud, ConfigBundle.D("vendor", "mailru", "login", "backup@mail.ru", "password", ConfigBundle.D("secret", "backup")) };
            parsed = ConfigBundle.Parse(Json.Encode(profile));
            Check(Json.Array(parsed.Profile["cloud"]).Length == 2, "priority array retained");
            Check(ConfigRequests.SecretsFor(ConfigSections.Cloud, parsed.Profile, n => false).SequenceEqual(new[] { "custom-cloud" }), "only first cloud's secret is needed now");
            int calls = 0;
            Func<string, string, CloudCommandResult> good = (command, input) => {
                calls++; var data = Map(input);
                Check(command == CloudApply.Command && !command.Contains("fake-cloud-password"), "fixed command without credential arguments");
                Check(input.EndsWith("\n") && !input.Contains("\r") && Json.Str(data, "password") == "fake-cloud-password", "JSON credential only on normalized stdin");
                Check(Json.Str(data, "login") == "user@mail.ru" && Json.Str(data, "localRoot") == "~/Disk" && Json.Str(data, "remoteRoot") == "Диск" && Json.Int(data, "pollSeconds", 0) == 20 && data.Count == 6, "first vendor and exact server contract");
                return new CloudCommandResult { ExitCode = 0, Output = "{\r\n\"ok\":true\r\n}\r\n" };
            };
            Check(CloudApply.Apply(parsed.Profile, _ => "fake-cloud-password", good).Ok && calls == 1, "code zero and CRLF ok:true accepted");
            foreach (var result in new[] {
                new CloudCommandResult { ExitCode = 1, Output = "{\"ok\":true}", Error = "Первая причина\r\nВторая" },
                new CloudCommandResult { ExitCode = 0, Output = "{}" }, new CloudCommandResult { ExitCode = 0, Output = "garbage" },
                new CloudCommandResult { ExitCode = 0, Output = "{\"ok\":\"true\"}" }, new CloudCommandResult { ExitCode = 0, Output = "{\"ok\":false}" } }) {
                var outcome = CloudApply.Apply(parsed.Profile, _ => "fake-cloud-password", (c, i) => result);
                Check(!outcome.Ok && !outcome.Pending, "nonconfirmation is failure");
                if (result.ExitCode == 1) Check(outcome.Summary == "Первая причина", "only first normalized stderr line shown");
            }
            Check(!CloudApply.Apply(parsed.Profile, _ => "", good).Ok && calls == 1, "missing credential makes no call");
            Check(CloudApply.Apply(Map("{}"), _ => "", good).Ok && calls == 1, "absent cloud skipped without executor");
            string leaked = CloudApply.Apply(parsed.Profile, _ => "fake-cloud-password", (c, i) => new CloudCommandResult { ExitCode = 3, Error = "отказ fake-cloud-password\r\nвторая" }).Summary;
            Check(leaked == "отказ <secret>", "even server echoed credential is scrubbed before row/log");
            string home = Path.Combine(Path.GetTempPath(), "cloud-config-" + Guid.NewGuid().ToString("N"));
            try {
                string bundle = Path.Combine(home, "old-bundle"); Directory.CreateDirectory(bundle);
                Json.Write(Path.Combine(bundle, "components.json"), new { components = new[] { new { name = "transport", exe = "fixture" }, new { name = "disk", exe = "legacy-tray" } } });
                Check(BundleDefinition.Load(bundle).Components.Select(c => c.Name).SequenceEqual(new[] { "transport" }), "rollback/legacy bundles cannot supervise Disk again");
                ConfigBundle.Store(home, old, null);
                Check(File.ReadAllLines(Path.Combine(home, "logs", Product.IsVpn ? "vpn-launcher.log" : "launcher.log")).Count(l => l.Contains("config.disk.ignored")) == 1, "legacy import has one journal event without its values");
                ConfigBundle.Store(home, parsed, null);
                Check(!ConfigBundle.ExportForAi(home).Contains("fake-cloud-password"), "AI export never carries cloud credential");
                Check(!File.ReadAllText(Path.Combine(home, "config.json")).Contains("fake-cloud-password"), "settings contain only reference");
                Check(ConfigBundle.Parse(ConfigBundle.Export(home, null)).Secrets["custom-cloud"] == "fake-cloud-password", "explicit backup restores cloud secret");
                string locked = ConfigBundle.Export(home, "master-password");
                Check(!locked.Contains("fake-cloud-password") && ConfigBundle.Unlock(ConfigBundle.Parse(locked), "master-password").Secrets["custom-cloud"] == "fake-cloud-password", "master password export roundtrip");
            } finally { if (Directory.Exists(home)) Directory.Delete(home, true); }
            var local = Map("{\"cloud\":{\"localFolder\":\"C:\\\\Cloud\"}}");
            Check(CloudSettings.LocalFolder(local) == @"C:\Cloud", "local folder belongs to device settings");
            Check(Path.GetFileName(CloudSettings.LocalFolder(Map("{}"))) == CloudSettings.MailFolder, "single Mail default");
            Check(CloudSettings.MissingFolder("folder").Contains("https://cloud.mail.ru/") && CloudSettings.MissingFolder("folder").Contains("folder"), "missing official app/folder has instructions");
            Migration();
            Console.WriteLine("PASS: " + checks + " cloud/config/stdin/migration checks (fake executor, FS and registry; no real Windows)");
        }
        static void Migration()
        {
            var system = new FakeSystem();
            string local = Path.Combine(Path.GetTempPath(), "migration-fixture"), home = Path.Combine(local, "RemoteDisk"), root = Path.Combine(local, "Disk"), target = Path.Combine(local, "external"), owned = Path.Combine(root, "Owned"), foreign = Path.Combine(root, "Foreign"), original = Path.Combine(root, "ReadOnly"), link = Path.Combine(root, "External");
            system.Dir(home); system.Dir(root); system.Dir(owned, FileAttributes.Directory | FileAttributes.ReadOnly); system.Dir(foreign); system.Dir(original);
            system.File(Path.Combine(owned, "notes.txt"), "user files"); system.File(Path.Combine(owned, "desktop.ini"), "[RemoteAgents]\r\nOwner=" + LegacyDiskMigration.Owner + "\r\nOriginalReadOnly=0\r\n");
            system.File(Path.Combine(original, "desktop.ini"), "[RemoteAgents]\r\nOwner=" + LegacyDiskMigration.Owner + "\r\nOriginalReadOnly=1\r\n");
            system.File(Path.Combine(foreign, "desktop.ini"), "[RemoteAgents]\r\nOwner=Other\r\nOriginalReadOnly=0\r\n");
            system.Dir(target); system.File(Path.Combine(target, "valuable.txt"), "external user files");
            system.Dir(link, FileAttributes.Directory | FileAttributes.ReparsePoint); system.Links[link] = target;
            system.File(Path.Combine(home, "base.txt"), root + "\r\n");
            system.File(Path.Combine(home, "external.json"), Json.Encode(new { schema = 1, items = new[] { new { path = target, junction = link, remote = "External" } } }));
            foreach (string name in new[] { "state", "tray", "selection-policies", "logs" }) { system.Dir(Path.Combine(home, name)); system.File(Path.Combine(home, name, "service.json"), "service"); }
            system.File(Path.Combine(home, "unrecognized-user.txt"), "keep");
            string icons = Path.Combine(local, "RemoteAgents", "icons"); system.Dir(icons);
            system.File(Path.Combine(icons, "RemoteAgents.Disk.sync.ico"), "owned icon"); system.File(Path.Combine(icons, "Other.ico"), "foreign icon");
            string invalid = Path.Combine(root, "InvalidMetadata"), linked = Path.Combine(root, "Linked"); system.Dir(invalid); system.Dir(linked, FileAttributes.Directory | FileAttributes.ReparsePoint);
            system.File(Path.Combine(invalid, "desktop.ini"), "[RemoteAgents]\r\nOwner=" + LegacyDiskMigration.Owner + "\r\nOriginalReadOnly=invalid\r\n");
            system.File(Path.Combine(linked, "desktop.ini"), "[RemoteAgents]\r\nOwner=" + LegacyDiskMigration.Owner + "\r\nOriginalReadOnly=0\r\n");
            string menu = LegacyDiskMigration.Menu + @"\RemoteAgents.Disk.sync", other = LegacyDiskMigration.Menu + @"\RemoteAgents.Disk.other";
            system.Set(menu, "RemoteAgentsOwner", LegacyDiskMigration.Owner); system.Set(other, "RemoteAgentsOwner", "foreign");
            system.Set(LegacyDiskMigration.Run, "OurSyncthing", Files.Quote(Path.Combine(home, "tray/syncthingtray.exe")) + " --tray");
            system.Set(LegacyDiskMigration.Run, "ForeignSyncthing", "\"C:\\Other\\syncthing.exe\"");
            string nav = @"Software\Classes\CLSID\" + LegacyDiskMigration.NavId;
            system.Set(nav, "", "Disk"); system.Set(@"Software\Classes\CLSID\{foreign}", "", "Other");
            var migration = new LegacyDiskMigration(system); migration.Clean(home, new[] { root });
            Check(system.Stopped && system.Shortcuts, "managed processes and shortcuts retired");
            Check(system.Value(LegacyDiskMigration.Run, "OurSyncthing") == null && system.Value(LegacyDiskMigration.Run, "ForeignSyncthing") != null, "only our autostart target removed");
            Check(!system.Registry.ContainsKey(menu) && system.Registry.ContainsKey(other), "foreign Explorer verb preserved even with our prefix");
            Check(!system.Registry.ContainsKey(nav) && system.Registry.ContainsKey(@"Software\Classes\CLSID\{foreign}"), "only fixed product nav GUID removed");
            Check(system.Read(Path.Combine(owned, "notes.txt")) == "user files" && system.Read(Path.Combine(target, "valuable.txt")) == "external user files", "all user files and junction target survive");
            Check(!system.DirectoryExists(link) && system.DirectoryExists(target), "only owned junction entry removed");
            Check(!system.FileExists(Path.Combine(owned, "desktop.ini")) && (system.Attributes(owned) & FileAttributes.ReadOnly) == 0, "owned metadata and original ReadOnly=0 restored");
            Check((system.Attributes(original) & FileAttributes.ReadOnly) != 0 && system.FileExists(Path.Combine(foreign, "desktop.ini")), "ReadOnly=1 restored, foreign desktop.ini intact");
            Check(!system.FileExists(Path.Combine(icons, "RemoteAgents.Disk.sync.ico")) && system.FileExists(Path.Combine(icons, "Other.ico")), "only owned icon filename removed");
            Check(system.FileExists(Path.Combine(invalid, "desktop.ini")) && system.FileExists(Path.Combine(linked, "desktop.ini")), "invalid ownership metadata and reparse directories never cleaned");
            Check(!system.DirectoryExists(Path.Combine(home, "state")) && !system.DirectoryExists(Path.Combine(home, "tray")) && system.FileExists(Path.Combine(home, "unrecognized-user.txt")), "only allowlisted service state removed");
            string before = system.Snapshot(); migration.Clean(home, new[] { root });
            Check(before == system.Snapshot() && system.Notified == 2, "second run idempotent and shell notified");
            system.Dir(link, FileAttributes.Directory | FileAttributes.ReparsePoint); system.Links[link] = Path.Combine(local, "foreign-target");
            system.File(Path.Combine(home, "base.txt"), root); system.File(Path.Combine(home, "external.json"), Json.Encode(new { schema = 1, items = new[] { new { path = target, junction = link, remote = "External" } } }));
            migration.Clean(home, new[] { root }); Check(system.DirectoryExists(link), "replaced foreign junction is preserved");
            string exe = Path.Combine(home, "tray/syncthingtray.exe"), state = Path.Combine(home, "state");
            Check(LegacyDiskMigration.OwnedProcess(exe, Files.Quote(exe) + " --wait", home), "owned tray process");
            Check(LegacyDiskMigration.OwnedProcess(exe, Files.Quote(exe) + " \"syncthing\" \"serve\" \"--home\" " + Files.Quote(state), home), "quoted embedded command with exact state");
            Check(!LegacyDiskMigration.OwnedProcess(exe, "syncthing serve --home " + Files.Quote(state + "-foreign"), home), "similar state is foreign");
            Check(!LegacyDiskMigration.OwnedProcess(exe, "syncthing serve --home " + Files.Quote(Path.Combine(local, "other")), home), "other embedded state untouched");
            Check(!LegacyDiskMigration.OwnedProcess(exe, "", home), "unreadable command line is not ownership proof");
            string standalone = Path.Combine(home, "bin/syncthing.exe");
            Check(!LegacyDiskMigration.OwnedProcess(standalone, Files.Quote(standalone) + " --home " + Files.Quote(state + "-foreign"), home), "standalone Syncthing foreign state preserved");
            Check(LegacyDiskMigration.OwnedProcess(standalone, Files.Quote(standalone) + " --home=" + Files.Quote(state), home), "standalone Syncthing exact managed state");
            Check(!LegacyDiskMigration.OwnedExecutable(Files.Quote(Path.Combine(home, "tray/syncthingtray.exe.evil")), home), "executable prefix is not ownership");
        }
        sealed class FakeSystem : ILegacyDiskSystem
        {
            readonly Dictionary<string, string> files = new Dictionary<string, string>();
            readonly Dictionary<string, FileAttributes> attrs = new Dictionary<string, FileAttributes>();
            internal readonly Dictionary<string, string> Links = new Dictionary<string, string>();
            internal readonly Dictionary<string, Dictionary<string, string>> Registry = new Dictionary<string, Dictionary<string, string>>();
            internal bool Stopped, Shortcuts; internal int Notified;
            internal void Dir(string p, FileAttributes a = FileAttributes.Directory) { attrs[p] = a; }
            internal void File(string p, string text) { files[p] = text; attrs[p] = FileAttributes.Normal; }
            internal void Set(string k, string n, string v) { if (!Registry.ContainsKey(k)) Registry[k] = new Dictionary<string, string>(); Registry[k][n] = v; }
            public bool FileExists(string p) { return files.ContainsKey(p); }
            public bool DirectoryExists(string p) { return attrs.ContainsKey(p) && (attrs[p] & FileAttributes.Directory) != 0; }
            public string Read(string p) { return files[p]; }
            public IEnumerable<string> Entries(string p) { return attrs.Keys.Where(k => Path.GetDirectoryName(k) == p).ToArray(); }
            public FileAttributes Attributes(string p) { return attrs[p]; }
            public void Attributes(string p, FileAttributes a) { attrs[p] = a; }
            public void DeleteFile(string p) { files.Remove(p); attrs.Remove(p); }
            public void DeleteDirectory(string p) { if (!Links.ContainsKey(p) && Entries(p).Any()) throw new Exception("nonempty"); attrs.Remove(p); Links.Remove(p); }
            public string JunctionTarget(string p) { string v; return Links.TryGetValue(p, out v) ? v : null; }
            public IEnumerable<string> Keys(string k) { return Registry.Keys.Where(p => p.StartsWith(k + "\\") && !p.Substring(k.Length + 1).Contains("\\")).Select(p => p.Substring(k.Length + 1)).ToArray(); }
            public IEnumerable<string> Values(string k) { return Registry.ContainsKey(k) ? Registry[k].Keys.ToArray() : new string[0]; }
            public string Value(string k, string n) { string v; return Registry.ContainsKey(k) && Registry[k].TryGetValue(n, out v) ? v : null; }
            public void DeleteKey(string k) { Registry.Remove(k); }
            public void DeleteValue(string k, string n) { if (Registry.ContainsKey(k)) Registry[k].Remove(n); }
            public void StopProcesses(string h) { Stopped = true; }
            public void RemoveShortcuts(string h) { Shortcuts = true; }
            public void Notify() { Notified++; }
            internal string Snapshot() { return string.Join("|", files.OrderBy(x => x.Key).Select(x => x.Key + "=" + x.Value)) + Json.Encode(attrs.OrderBy(x => x.Key).ToDictionary(x => x.Key, x => (int)x.Value)) + Json.Encode(Registry); }
        }
    }
}
