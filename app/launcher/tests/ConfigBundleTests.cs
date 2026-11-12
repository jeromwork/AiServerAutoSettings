using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace RemoteAgents.Launcher
{
    internal static class ConfigBundleTests
    {
        static int count;
        static void Check(bool value, string label) { if (!value) throw new Exception("CONFIG: " + label); count++; }
        static void Reject(Action action, string label) { try { action(); } catch (InvalidDataException) { count++; return; } throw new Exception("CONFIG accepted: " + label); }
        static Dictionary<string, object> Example()
        {
            return ConfigBundle.D("kind", "remoteagents-config", "schema", 1,
                "device", ConfigBundle.D("name", "Ноутбук"),
                "server", ConfigBundle.D("address", "server.example.invalid", "port", 2222, "login", "worker", "key", ConfigBundle.D("secret", "server-key")),
                "disk", ConfigBundle.D("folders", new[]{"Project", "Документы"}),
                "secrets", ConfigBundle.D("server-key", "TEST-PRIVATE-KEY\r\nSECOND-LINE\r\n"));
        }
        internal static void Run()
        {
            var valid = Example();
            var p = ConfigBundle.Parse(Json.Encode(valid));
            Check(!p.Locked && p.Missing.Length == 0 && !p.Profile.ContainsKey("secrets"), "public profile separate");
            Check(p.Secrets["server-key"].Contains("\r\n"), "values preserved");
            Check(ConfigBundle.Parse("\uFEFF{\r\n\"kind\":\"remoteagents-config\",\r\n\"schema\":1\r\n}").Missing.Length == 0, "CRLF and BOM");
            foreach (var pair in ConfigBundle.D("schema", 2, "kind", "wrong", "extra", true, "device", ConfigBundle.D("extra", 1), "server", ConfigBundle.D("password", "must-be-reference"), "disk", ConfigBundle.D("folders", new[]{"Project/../escape"}), "vpn", ConfigBundle.D("enabled", "true"))) {
                var bad = new Dictionary<string, object>(valid); bad[pair.Key] = pair.Value;
                Reject(() => ConfigBundle.Parse(Json.Encode(bad)), "schema " + pair.Key);
            }
            foreach (string text in new[]{"", "[]", "null", "{\"kind\":\"remoteagents-config\",\"schema\":1,}", "{\"kind\":\"remoteagents-config\",\"schema\":1,\"schema\":1}", "{\"kind\":\"remoteagents-config\",\"schema\":1} trailing", "{'kind':'remoteagents-config','schema':1}"}) Reject(() => ConfigBundle.Parse(text), "invalid JSON");
            var newlineHost = Example(); Json.Map(newlineHost["server"])["address"] = "server.example.invalid\n";
            Reject(() => ConfigBundle.Parse(Json.Encode(newlineHost)),"trailing newline cannot bypass anchored schema pattern");
            var literalPrefix = Example(); Json.Map(literalPrefix["secrets"])["server-key"] = "enc1:literal-plaintext";
            var literal = ConfigBundle.Parse(Json.Encode(literalPrefix));
            Check(ConfigBundle.Unlock(ConfigBundle.Parse(ConfigBundle.Pack(literal,"master")),"master").Secrets["server-key"] == "enc1:literal-plaintext","protected flag determines encryption, literal prefix roundtrips");
            var missing = Example(); missing["secrets"] = ConfigBundle.D("server-key", "");
            p = ConfigBundle.Parse(Json.Encode(missing));
            Check(p.Missing.SequenceEqual(new[]{"server-key"}) && p.Hints["server-key"].Length > 0, "missing with standard hint");
            var reference = ConfigBundle.D("secret", "lan-Офис-ovpn", "hint", "Профиль сети");
            missing["server"] = ConfigBundle.D("key", reference);
            p = ConfigBundle.Parse(Json.Encode(missing));
            Check(p.Missing.Contains("lan-Офис-ovpn") && p.Hints["lan-Офис-ovpn"] == "Профиль сети", "Unicode and custom hint");
            foreach (string name in new[]{"", "../bad", "Upper", "trailing\n", "protected", "a/b", new string('a',65)}) { reference["secret"] = name; Reject(() => ConfigBundle.Parse(Json.Encode(missing)), "secret name"); }
            var nestedSelection = Example(); nestedSelection["disk"] = ConfigBundle.D("folders",new[]{"Project/docs","Проекты/Сайт"});
            Check(ConfigBundle.Parse(Json.Encode(nestedSelection)).Profile.ContainsKey("disk"), "nested selection retains first-level project roots");
            var namedPassword = ConfigBundle.Parse("{\"kind\":\"remoteagents-config\",\"schema\":1,\"server\":{\"rootPassword\":{\"secret\":\"custom-root\"}}}");
            Check(namedPassword.Hints["custom-root"].Contains("хостинг"),"standard field explanation independent of secret name");
            var route = Example(); route["server"] = ConfigBundle.D("routes", new[]{ConfigBundle.D("kind", "hop")});
            Reject(() => ConfigBundle.Parse(Json.Encode(route)), "hop required");
            string schemaPath = FindSchema();
            Check(Canonical(Json.Read(schemaPath)) == Canonical(ConfigBundle.SchemaDocument()), "published schema matches compiled schema");
            Check(ConfigBundle.Parse(File.ReadAllText(Path.Combine(Path.GetDirectoryName(schemaPath),"config.paste.example.json"))).Missing.Length == 2,"published example parses with missing secrets");
            p = ConfigBundle.Parse(Json.Encode(valid));
            string encrypted = ConfigBundle.Pack(p, "Тестовый мастер-пароль");
            var locked = ConfigBundle.Parse(encrypted);
            Check(locked.Locked && !encrypted.Contains("TEST-PRIVATE-KEY"), "encrypted values only");
            var unlocked = ConfigBundle.Unlock(locked, "Тестовый мастер-пароль");
            Check(unlocked.Secrets["server-key"] == p.Secrets["server-key"] && !unlocked.Locked, "enc1 roundtrip CRLF");
            Check(locked.Locked && locked.Secrets["server-key"].StartsWith("enc1:"), "unlock does not mutate input");
            Reject(() => ConfigBundle.Unlock(locked, "wrong"), "wrong master");
            foreach (string field in new[]{"server-key", "check"}) foreach (int offset in new[]{0,17,-1}) {
                var altered = Json.Map(Json.Parse(encrypted)); var sv = Json.Map(altered["secrets"]);
                var bytes = Convert.FromBase64String(((string)sv[field]).Substring(5)); bytes[offset < 0 ? bytes.Length-1 : offset] ^= 1;
                sv[field] = "enc1:" + Convert.ToBase64String(bytes);
                Reject(() => ConfigBundle.Unlock(ConfigBundle.Parse(Json.Encode(altered)), "Тестовый мастер-пароль"), "tamper " + field);
            }
            Reject(() => ConfigBundle.Pack(p, ""), "empty master");
            try { ConfigBundle.Unlock(locked,"wrong"); throw new Exception("password accepted"); } catch (InvalidDataException ex) { Check(ex.Message == "Неверный мастер-пароль","uniform safe password error"); }
            foreach (int iterations in new[]{0,199999,2000001}) {
                var invalidKdf = Json.Map(Json.Parse(encrypted)); Json.Map(Json.Map(invalidKdf["secrets"])["kdf"])["iterations"] = iterations;
                Reject(() => ConfigBundle.Parse(Json.Encode(invalidKdf)),"KDF resource bounds");
            }
            var noCheck = Json.Map(Json.Parse(encrypted)); Json.Map(noCheck["secrets"]).Remove("check"); Reject(() => ConfigBundle.Parse(Json.Encode(noCheck)),"check required");
            var badProtected = Json.Map(Json.Parse(encrypted)); Json.Map(badProtected["secrets"])["server-key"] = "plain";
            Reject(() => ConfigBundle.Parse(Json.Encode(badProtected)), "mixed protected/plain");
            // Independent PBKDF2/AES/HMAC fixture generated with Python hashlib + cryptography.
            var interop = ConfigBundle.Parse("{\"kind\":\"remoteagents-config\",\"schema\":1,\"server\":{\"key\":{\"secret\":\"server-key\"}},\"secrets\":{\"protected\":\"master-password\",\"kdf\":{\"name\":\"pbkdf2-sha256\",\"iterations\":200000,\"salt\":\"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=\"},\"check\":\"enc1:AAECAwQFBgcICQoLDA0ODxDf5ZSnK4rourEgLtBAHFjzLCoRAhgTD+rS5FqlAEve+Ksk7xocQcpH4kbgYFvw6Q==\",\"server-key\":\"enc1:EBESExQVFhcYGRobHB0eHyJI8g0R/TIwsFE14BZyX2wGtchuCE50mSqa/T3/JSZbfimgnDai2DDKLz2i8pV2UhyFlSKUxze5r42EgfJ+S/8=\"}}");
            Check(ConfigBundle.Unlock(interop,"master-interop").Secrets["server-key"] == "interop-line\r\nsecond", "Python enc1 interoperability");
            string home = Path.Combine(Path.GetTempPath(), "ra-config-a-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(home);
            try {
                ConfigBundle.Store(home, p, null);
                Check(!File.ReadAllText(Path.Combine(home, "config.json")).Contains("TEST-PRIVATE-KEY"), "settings never contain values");
                Check(SecretVault.Has(home, "server-key") && SecretVault.Names(home).Contains("server-key"), "vault has/names");
                Check(SecretVault.Get(home, "server-key") == p.Secrets["server-key"], "vault preserves bytes");
                if (!SecretVault.Windows) {
                    Check((File.GetUnixFileMode(Path.Combine(home, "secrets", "vault.json")) & (UnixFileMode.GroupRead | UnixFileMode.OtherRead | UnixFileMode.GroupWrite | UnixFileMode.OtherWrite)) == 0, "vault mode 0600");
                    Check(Json.Str(Json.Read(Path.Combine(home,"secrets","vault.json")), "protection") == "plaintext-linux", "honest plaintext Linux marker");
                }
                var full = ConfigBundle.Parse(ConfigBundle.Export(home, null));
                Check(Canonical(full.Profile) == Canonical(p.Profile) && full.Secrets["server-key"] == p.Secrets["server-key"], "Parse Export without loss");
                var encryptedFull = ConfigBundle.Parse(ConfigBundle.Export(home, "master"));
                Check(ConfigBundle.Unlock(encryptedFull,"master").Secrets["server-key"] == p.Secrets["server-key"], "protected Export roundtrip");
                SecretVault.Set(home, "unused-secret", "UNREFERENCED-SECRET-TOKEN");
                string ai = ConfigBundle.ExportForAi(home);
                Check(!ai.Contains("TEST-PRIVATE-KEY") && !ai.Contains("UNREFERENCED-SECRET-TOKEN"), "AI export zero secret values");
                Check(Json.Str(Json.Map(Json.Map(Json.Parse(ai))["secrets"]),"server-key") == ConfigBundle.Hidden, "AI markers");
                ConfigBundle.Store(home, ConfigBundle.Parse(ai), null);
                Check(SecretVault.Get(home,"server-key") == p.Secrets["server-key"], "AI edit preserves existing credentials");
                var changed = Example(); Json.Map(changed["server"])["address"] = "other.example.invalid";
                Json.Map(changed["secrets"])["server-key"] = "REPLACEMENT-KEY";
                changed["bridge"] = ConfigBundle.D("enabled", true);
                var change = ConfigBundle.Parse(Json.Encode(changed));
                Check(ConfigBundle.Conflicts(home, change).Single().StartsWith("server: сейчас "), "server conflict description");
                ConfigBundle.Store(home, change, null);
                var snapshot = ConfigBundle.Parse(ConfigBundle.Export(home,null));
                Check(Json.Str(Json.Map(snapshot.Profile["server"]),"address") == "server.example.invalid" && Json.Bool(Json.Map(snapshot.Profile["bridge"]),"enabled"), "conflict blocked, independent section stored");
                Check(SecretVault.Get(home,"server-key") != "REPLACEMENT-KEY", "blocked section cannot replace credential");
                ConfigBundle.Store(home, change, new[]{"server"});
                Check(ConfigBundle.Conflicts(home,change).Length == 0 && SecretVault.Get(home,"server-key") == "REPLACEMENT-KEY", "explicit conflict accepted");
                var diskChange = ConfigBundle.Parse(Json.Encode(ConfigBundle.D("kind","remoteagents-config","schema",1,"disk",ConfigBundle.D("folders", new[]{"Project"}))));
                Check(ConfigBundle.Conflicts(home,diskChange).Single().StartsWith("disk:"), "removed disk folders conflict");
                string oldConfig = File.ReadAllText(Path.Combine(home,"config.json")), oldVault = File.ReadAllText(Path.Combine(home,"secrets","vault.json"));
                Reject(() => ConfigBundle.Store(home,locked,null), "locked Store");
                Check(oldConfig == File.ReadAllText(Path.Combine(home,"config.json")) && oldVault == File.ReadAllText(Path.Combine(home,"secrets","vault.json")), "locked Store writes nothing");
                SecretVault.Set(home,"empty-secret", ""); Check(!SecretVault.Has(home,"empty-secret"), "empty is missing");
                var material = Example();
                material["server"] = ConfigBundle.D("address","other.example.invalid","port",2222,"login","worker","key",ConfigBundle.D("secret","server-key"),"rootPassword",ConfigBundle.D("secret","server-root-password"),"routes",new[]{ ConfigBundle.D("kind","hop","hop",ConfigBundle.D("host","hop.example.invalid","user","jump","port",2207,"hostKey","ssh-ed25519 FAKE","key",ConfigBundle.D("secret","hop-key"),"password",ConfigBundle.D("secret","hop-password"))) });
                material["happier"] = ConfigBundle.D("key",ConfigBundle.D("secret","happier-key"));
                material["proxyOut"] = ConfigBundle.D("type","socks","server","proxy.example.invalid","port",1080,"login","test-user","password",ConfigBundle.D("secret","proxy-out-password"));
                material["vpn"] = ConfigBundle.D("bootstrap",ConfigBundle.D("channel",ConfigBundle.D("secret","vpn-channel"),"entries",ConfigBundle.D("edge",ConfigBundle.D("secret","vpn-entry-edge")),"hops",ConfigBundle.D("jumper",ConfigBundle.D("host","hop.example.invalid","user","jump","key",ConfigBundle.D("secret","hop-key")))));
                material["lan"] = new[]{ConfigBundle.D("name","Офис","kind","openvpn","ovpn",ConfigBundle.D("secret","lan-Офис-ovpn"),"login","office-user","password",ConfigBundle.D("secret","lan-Офис-password"))};
                material["secrets"] = ConfigBundle.D("server-key","KEY\r\nLINE\r\n","server-root-password","ROOT-VALUE","happier-key","HAPPIER-VALUE","hop-key","HOP-KEY\r\n","hop-password","HOP-PASSWORD","proxy-out-password","PROXY-PASSWORD","vpn-channel","{\r\n\"inbounds\":[],\"outbounds\":[]\r\n}","vpn-entry-edge","{\"server\":\"entry.example.invalid\",\"secrets\":{\"fake\":\"ENTRY-SECRET\"}}","lan-Офис-ovpn","client\r\nremote vpn.example.invalid\r\n","lan-Офис-password","LAN-PASSWORD");
                ConfigBundle.Store(home,ConfigBundle.Parse(Json.Encode(material)),new[]{"server","happier","disk"});
                SecretVault.Materialize(home);
                var manifest = Json.Read(SecretVault.MaterializedPath(home));
                Check(File.ReadAllText(Json.Str(manifest,"serverKeyFile")) == "KEY\nLINE\n", "key materialization normalizes CRLF");
                Check(File.ReadAllText(Path.Combine(home,"secrets","happier-pending.key")) == "HAPPIER-VALUE" && !File.Exists(Path.Combine(home,"secrets","happier-account.key")), "account pending preserves rollback");
                Check(Json.Str(Json.Read(Path.Combine(home,"secrets","proxy-out.json")),"username") == "test-user" && Json.Str(Json.Read(Path.Combine(home,"secrets","proxy-out.json")),"password") == "PROXY-PASSWORD", "proxy legacy format");
                Check(File.Exists(Path.Combine(home,"secrets","channel.json")) && File.Exists(Path.Combine(home,"secrets","entries","edge.json")), "VPN paths match transport");
                var hopFiles = Json.Map(Json.Map(Json.Array(manifest["routes"])[0])["hop"]);
                Check(File.ReadAllText(Json.Str(hopFiles,"keyFile")) == "HOP-KEY\n" && File.ReadAllText(Json.Str(hopFiles,"knownHostsPath")).StartsWith("[hop.example.invalid]:2207 "), "hop private key and host pin");
                var lanFiles = Json.Map(Json.Array(manifest["lan"])[0]);
                Check(File.ReadAllText(Json.Str(lanFiles,"file")).Contains("client\nremote") && Json.Str(Json.Read(Json.Str(lanFiles,"authFile")),"password") == "LAN-PASSWORD", "LAN inline profile and auth");
                var allMaterialSecrets = Json.Map(material["secrets"]).Values.Cast<string>().Where(x => x.Length > 0).ToArray();
                string aiMaterial = ConfigBundle.ExportForAi(home), manifestText = File.ReadAllText(SecretVault.MaterializedPath(home));
                foreach(string secret in allMaterialSecrets) Check(!aiMaterial.Contains(secret) && !manifestText.Contains(secret), "no values in AI/manifest");
                Check(!aiMaterial.Contains("ENTRY-SECRET"), "no nested VPN credential");
                if (!SecretVault.Windows) foreach(string file in Json.Strings(manifest["files"])) Check((File.GetUnixFileMode(file) & (UnixFileMode.GroupRead | UnixFileMode.OtherRead)) == 0,"private materialized file");
                string priorChannel = File.ReadAllText(Path.Combine(home,"secrets","channel.json"));
                SecretVault.Set(home,"vpn-channel","invalid JSON");
                Reject(() => SecretVault.Materialize(home), "invalid snapshot preflight");
                Check(File.ReadAllText(Path.Combine(home,"secrets","channel.json")) == priorChannel, "failed preflight writes nothing");
                SecretVault.Set(home,"vpn-channel",Json.Str(Json.Map(material["secrets"]),"vpn-channel"));
                SecretVault.Set(home,"hop-password", ""); Reject(() => SecretVault.Materialize(home), "missing secret cannot reuse stale files");
                SecretVault.Set(home,"hop-password","HOP-PASSWORD");
                string runtimePath = Path.Combine(home,"ssh-profiles","current","ssh-transport.json"), keyTarget = Path.Combine(home,"ssh-profiles","current","id_ed25519");
                Json.Write(runtimePath,ConfigBundle.D("serverAddress","other.example.invalid","login","worker","keyPath",keyTarget,"arguments",new[]{"-p","2222"}));
                var runtimeSettings = Json.Read(Path.Combine(home,"config.json")); runtimeSettings["transport"] = ConfigBundle.D("profilePath",runtimePath); Json.Write(Path.Combine(home,"config.json"),runtimeSettings);
                SecretVault.Materialize(home);
                Check(File.ReadAllText(keyTarget) == "KEY\nLINE\n" && Json.Str(Json.Read(SecretVault.MaterializedPath(home)),"serverKeyFile") == keyTarget,"existing profile keyPath honored");
                SecretVault.Set(home,"server-key","NEW-UNVERIFIED-KEY"); SecretVault.Materialize(home);
                Check(File.ReadAllText(keyTarget) == "KEY\nLINE\n" && Json.Str(Json.Read(SecretVault.MaterializedPath(home)),"serverKeyFile") != keyTarget,"active key preserved until new key is verified");
                SecretVault.Set(home,"server-key","KEY\r\nLINE\r\n");
                Json.Write(runtimePath,ConfigBundle.D("serverAddress","other.example.invalid","login","worker","keyPath",Path.Combine(home,"config.json"),"arguments",new[]{"-p","2222"}));
                string configBeforePathAttack = File.ReadAllText(Path.Combine(home,"config.json"));
                Reject(() => SecretVault.Materialize(home),"keyPath cannot target config.json");
                Check(configBeforePathAttack == File.ReadAllText(Path.Combine(home,"config.json")),"config path attack leaves settings intact");
                runtimeSettings["transport"] = ConfigBundle.D(); Json.Write(Path.Combine(home,"config.json"),runtimeSettings);
                string roundtripHome = Path.Combine(home,"roundtrip");
                var recovery = ConfigBundle.Parse(ConfigBundle.Export(home,null)); ConfigBundle.Store(roundtripHome,recovery,null);
                var recovered = ConfigBundle.Parse(ConfigBundle.Export(roundtripHome,null));
                Check(Canonical(recovered.Profile) == Canonical(recovery.Profile) && recovered.Secrets.OrderBy(x=>x.Key).SequenceEqual(recovery.Secrets.OrderBy(x=>x.Key)),"all fields, empty and unreferenced secrets survive reinstall");
                var displaySettings = Json.Read(Path.Combine(home,"config.json"));
                Json.Map(displaySettings["profile"])["hint"] = "PREFIX HOP-PASSWORD SUFFIX"; Json.Write(Path.Combine(home,"config.json"),displaySettings);
                Check(!ConfigBundle.ExportForAi(home).Contains("HOP-PASSWORD"),"AI redacts known secrets even in public hints");
                Reject(() => ConfigBundle.Parse(new string(' ',ConfigBundle.MaxLength+1)),"input size limit");
                var tasks = Enumerable.Range(0,12).Select(i => System.Threading.Tasks.Task.Run(() => SecretVault.Set(home,"concurrent-"+i,"FAKE-"+i))).ToArray();
                System.Threading.Tasks.Task.WaitAll(tasks);
                Check(Enumerable.Range(0,12).All(i=>SecretVault.Get(home,"concurrent-"+i) == "FAKE-"+i),"parallel vault writes cannot lose values");
                string legacyParent = Path.Combine(home,"legacy"), legacyHome = Path.Combine(legacyParent,"RemoteAgents"), diskHome = Path.Combine(legacyParent,"RemoteDisk");
                Directory.CreateDirectory(legacyHome); Directory.CreateDirectory(diskHome);
                File.WriteAllText(Path.Combine(diskHome,"base.txt"),"C:\\Users\\owner\\Disk\r\n");
                Json.Write(Path.Combine(diskHome,"selection.json"),ConfigBundle.D("paths",new[]{"Project/docs"}));
                string legacyKey = Path.Combine(legacyHome,"ssh-profiles","current","id_ed25519"), legacySsh = Path.Combine(legacyHome,"ssh-profiles","current","ssh-transport.json");
                SecretVault.WritePrivate(legacyHome,legacyKey,"LEGACY-KEY\r\n");
                Json.Write(legacySsh,ConfigBundle.D("serverAddress","legacy.example.invalid","login","worker","keyPath",legacyKey));
                Json.Write(Path.Combine(legacyHome,"config.json"),ConfigBundle.D("transport",ConfigBundle.D("profilePath",legacySsh),"happier",ConfigBundle.D("label","Старый аккаунт")));
                SecretVault.WritePrivate(legacyHome,Path.Combine(legacyHome,"secrets","happier-account.key"),"LEGACY-HAPPIER-KEY");
                var legacyChange = ConfigBundle.Parse(Json.Encode(ConfigBundle.D("kind","remoteagents-config","schema",1,"disk",ConfigBundle.D("base","D:\\Disk","folders",new string[0]),"happier",ConfigBundle.D("label","Старый аккаунт","key",ConfigBundle.D("secret","happier-key")),"secrets",ConfigBundle.D("happier-key","CHANGED-ACCOUNT-KEY"))));
                Check(ConfigBundle.Conflicts(legacyHome,legacyChange).Length == 2,"legacy root/folders and account-key conflicts found");
                ConfigBundle.Store(legacyHome,ConfigBundle.Parse("{\"kind\":\"remoteagents-config\",\"schema\":1,\"bridge\":{\"enabled\":true}}"),null);
                var legacyRecovered = ConfigBundle.Parse(ConfigBundle.Export(legacyHome,null));
                Check(legacyRecovered.Secrets["server-key"] == "LEGACY-KEY\r\n" && legacyRecovered.Secrets["happier-key"] == "LEGACY-HAPPIER-KEY" && Json.Strings(Json.Get(Json.Map(legacyRecovered.Profile["disk"]),"folders")).Single() == "Project/docs","first profile preserves existing disk and keys");
                SecretVault.Materialize(legacyHome);
                SecretVault.Set(legacyHome,"server-key", "");
                Check(ConfigBundle.Parse(ConfigBundle.Export(legacyHome,null)).Secrets["server-key"] == "", "explicitly cleared key is not resurrected from old materialized file");
                int exitCode;
                string setOutput = Command(() => SecretCommand.Execute(home,new[]{"secret","set","command-secret","--why","Объяснение"},(name,why) => "SET-SECRET-VALUE"),out exitCode);
                Check(exitCode == 0 && setOutput.Trim() == "сохранено" && SecretVault.Get(home,"command-secret") == "SET-SECRET-VALUE", "set prints status only");
                string cancelOutput = Command(() => SecretCommand.Execute(home,new[]{"set","command-secret","--why","Объяснение"},(name,why) => null),out exitCode);
                Check(exitCode == 1 && cancelOutput.Trim() == "отменено" && SecretVault.Get(home,"command-secret") == "SET-SECRET-VALUE", "set canceled unchanged");
                const string variable = "RA_CONFIG_A_TEST_IMPORT";
                string priorEnv = Environment.GetEnvironmentVariable(variable);
                try {
                    Environment.SetEnvironmentVariable(variable,"ENV-IMPORT-VALUE");
                    string importOutput = Command(() => SecretCommand.Run(home,new[]{"secret","import","env-secret","--from","env:"+variable}),out exitCode);
                    Check(exitCode == 0 && importOutput.Trim() == "сохранено" && SecretVault.Get(home,"env-secret") == "ENV-IMPORT-VALUE","env import status only");
                    Environment.SetEnvironmentVariable(variable,null);
                    string failure = Command(() => SecretCommand.Run(home,new[]{"import","env-secret","--from","env:"+variable}),out exitCode);
                    Check(exitCode == 1 && !failure.Contains("ENV-IMPORT-VALUE") && SecretVault.Get(home,"env-secret") == "ENV-IMPORT-VALUE","missing source preserves value");
                } finally { Environment.SetEnvironmentVariable(variable,priorEnv); }
                string status = Command(() => SecretCommand.Run(home,new[]{"status"}),out exitCode);
                Check(exitCode == 0 && status.Contains("server-key: есть") && !status.Contains("SET-SECRET-VALUE") && !status.Contains("ENV-IMPORT-VALUE") && !status.Contains("HOP-PASSWORD"),"status without values");
                var bwItem = ConfigBundle.D("login",ConfigBundle.D("password","BW-PASSWORD","username","BW-USER"),"fields",new[]{ConfigBundle.D("name","ssh-key","value","BW-KEY")});
                Check(SecretCommand.BitwardenField(bwItem,"password") == "BW-PASSWORD" && SecretCommand.BitwardenField(bwItem,"ssh-key") == "BW-KEY","Bitwarden standard and custom fields");
                if (!SecretVault.Windows) {
                    string bin = Path.Combine(home,"test-bin"); Directory.CreateDirectory(bin); string bw = Path.Combine(bin,"bw");
                    File.WriteAllText(bw,"#!/bin/sh\n[ \"$1\" = get ] && [ \"$2\" = item ] || exit 2\nprintf '%s' '{\"login\":{\"password\":\"BW-CLI-SECRET\"}}'\n");
                    File.SetUnixFileMode(bw,UnixFileMode.UserRead|UnixFileMode.UserWrite|UnixFileMode.UserExecute);
                    string priorPath = Environment.GetEnvironmentVariable("PATH");
                    try {
                        Environment.SetEnvironmentVariable("PATH",bin+Path.PathSeparator+priorPath);
                        string bwOutput = Command(() => SecretCommand.Run(home,new[]{"import","bw-secret","--from","bitwarden:test-item/password"}),out exitCode);
                        Check(exitCode == 0 && bwOutput.Trim() == "сохранено" && SecretVault.Get(home,"bw-secret") == "BW-CLI-SECRET","Bitwarden CLI capture without leak");
                        File.WriteAllText(bw,"#!/bin/sh\nprintf '%s' 'SENSITIVE-CLI-ERROR' >&2\nexit 1\n");
                        string failure = Command(() => SecretCommand.Run(home,new[]{"import","bw-secret","--from","bitwarden:test-item/password"}),out exitCode);
                        Check(exitCode == 1 && !failure.Contains("SENSITIVE-CLI-ERROR") && SecretVault.Get(home,"bw-secret") == "BW-CLI-SECRET","Bitwarden error never exposed");
                    } finally { Environment.SetEnvironmentVariable("PATH",priorPath); }
                }
                if (!SecretVault.Windows) {
                    string outside = Path.Combine(Path.GetTempPath(),"ra-vault-outside-" + Guid.NewGuid().ToString("N"));
                    string linkedHome = Path.Combine(home,"linked"); Directory.CreateDirectory(linkedHome);
                    Directory.CreateDirectory(outside);
                    try { Directory.CreateSymbolicLink(Path.Combine(linkedHome,"secrets"),outside); Reject(() => SecretVault.Set(linkedHome,"server-key","never-written"), "symlink vault"); Check(!File.Exists(Path.Combine(outside,"vault.json")),"outside untouched"); }
                    finally { Directory.Delete(Path.Combine(linkedHome,"secrets")); Directory.Delete(outside); }
                }
            } finally { Directory.Delete(home,true); }
            Console.WriteLine("PASS: CONFIG: " + count + " assertions");
        }
        static string FindSchema()
        {
            foreach (string start in new[]{Environment.CurrentDirectory, AppContext.BaseDirectory}) for (string path=start; !string.IsNullOrEmpty(path); path=Path.GetDirectoryName(path)) {
                string candidate = Path.Combine(path,"app","launcher","config.paste.schema.json"); if(File.Exists(candidate))return candidate;
            }
            throw new FileNotFoundException("Published CONFIG schema missing");
        }
        static string Command(Func<int> action, out int code)
        {
            var output = new StringWriter(); var oldOut = Console.Out; var oldError = Console.Error;
            try { Console.SetOut(output); Console.SetError(output); code = action(); return output.ToString(); }
            finally { Console.SetOut(oldOut); Console.SetError(oldError); output.Dispose(); }
        }
        static string Canonical(object value)
        {
            var d = value as Dictionary<string, object>;
            if (d != null) return "{" + string.Join(",", d.OrderBy(x => x.Key, StringComparer.Ordinal).Select(x => Json.Encode(x.Key) + ":" + Canonical(x.Value))) + "}";
            if (!(value is string) && value is System.Collections.IEnumerable) return "[" + string.Join(",", Json.Array(value).Select(Canonical)) + "]";
            return Json.Encode(value);
        }
        public static int Main(string[] args)
        {
            if (args.Length == 2 && args[0] == "--schema") { File.WriteAllText(args[1], Json.Encode(ConfigBundle.SchemaDocument()) + "\n"); return 0; }
            Run(); return 0;
        }
    }
}
