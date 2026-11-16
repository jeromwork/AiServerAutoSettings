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
                "disk", ConfigBundle.D("folders", new object[]{ConfigBundle.D("id", "Project"), ConfigBundle.D("id", "Документы")}),
                "secrets", ConfigBundle.D("server-key", "TEST-PRIVATE-KEY\r\nSECOND-LINE\r\n"));
        }
        internal static void Run()
        {
            DiskChoiceTests.Run();
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
            var localWeb = Example();
            localWeb["happier"] = ConfigBundle.D("localWeb", ConfigBundle.D("enabled", true, "port", 1024, "serverPort", 65535));
            Check(Json.Bool(Json.Map(Json.Map(ConfigBundle.Parse(Json.Encode(localWeb).Insert(1, "\r\n")).Profile["happier"])["localWeb"]), "enabled"), "localWeb ports at boundaries accepted");
            Json.Map(Json.Map(localWeb["happier"])["localWeb"])["enabled"] = false;
            Check(!Json.Bool(Json.Map(Json.Map(ConfigBundle.Parse(Json.Encode(localWeb)).Profile["happier"])["localWeb"]), "enabled"), "localWeb explicit opt-out accepted");
            foreach (var patch in new[] {
                ConfigBundle.D("enabled", "true", "port", 47831, "serverPort", 47831),
                ConfigBundle.D("enabled", true, "port", 1023, "serverPort", 47831),
                ConfigBundle.D("enabled", true, "port", 65536, "serverPort", 47831),
                ConfigBundle.D("enabled", true, "port", 47831, "serverPort", 1023),
                ConfigBundle.D("enabled", true, "port", 47831, "serverPort", 65536),
                ConfigBundle.D("enabled", true, "port", 47831.5, "serverPort", 47831),
                ConfigBundle.D("enabled", true, "port", "47831", "serverPort", 47831),
                ConfigBundle.D("enabled", true, "port", 47831),
                ConfigBundle.D("enabled", true, "port", 47831, "serverPort", 47831, "unknown", true) }) {
                localWeb["happier"] = ConfigBundle.D("localWeb", patch);
                Reject(() => ConfigBundle.Parse(Json.Encode(localWeb)), "invalid localWeb rejected");
            }
            localWeb["happier"] = ConfigBundle.D("localWeb", null);
            Reject(() => ConfigBundle.Parse(Json.Encode(localWeb)), "explicit null localWeb is not an absent field");
            Check(!Json.Map(Json.Get(ConfigBundle.Parse(Json.Encode(Example())).Profile, "happier")).ContainsKey("localWeb"), "old paste does not enable local web");
            var webServer = ConfigBundle.D("kind", "remoteagents-config", "schema", 1,
                "happier", ConfigBundle.D("localWeb", ConfigBundle.D("enabled", true, "port", 47831, "serverPort", 47832)),
                "serverComponents", ConfigBundle.D("happierWeb", ConfigBundle.D("enabled", true, "port", 47832,
                    "updateIntervalHours", 6, "keepReleases", 2, "keepChats", 8, "quotas", ConfigBundle.D("enabled", true, "claudeProbe", true, "claudeProbeSec", 600))));
            Check(ConfigBundle.Parse(Json.Encode(webServer)).Profile.ContainsKey("serverComponents"), "documented single export accepts both server component and computer localWeb");
            var webComponent = Json.Map(Json.Map(webServer["serverComponents"])["happierWeb"]);
            foreach (string url in new[] { "https://api.example.invalid", "http://127.0.0.1:3005/" }) {
                webComponent["serverUrl"] = url;
                Check(ConfigBundle.Parse(Json.Encode(webServer)).Profile.ContainsKey("serverComponents"), "server export accepts configured Happier HTTP(S) origin");
            }
            foreach (string url in new[] { "https://user:pass@example.invalid", "https://api.example.invalid/path", "https://api.example.invalid/?q=1", "file:///tmp/page" }) {
                webComponent["serverUrl"] = url;
                Reject(() => ConfigBundle.Parse(Json.Encode(webServer)), "invalid server Happier origin rejected");
            }
            webComponent.Remove("serverUrl");
            foreach (var invalid in new[] { ConfigBundle.D("keepReleases", 1), ConfigBundle.D("keepChats", 101), ConfigBundle.D("updateIntervalHours", 169), ConfigBundle.D("quotas", ConfigBundle.D("claudeProbeSec", 59)) }) {
                var changed = Json.Map(Json.Parse(Json.Encode(webServer)));
                var component = Json.Map(Json.Map(changed["serverComponents"])["happierWeb"]);
                foreach (var pair in invalid) component[pair.Key] = pair.Value;
                Reject(() => ConfigBundle.Parse(Json.Encode(changed)), "client matches server component ranges");
            }
            Json.Map(Json.Map(webServer["serverComponents"])["happierWeb"])["unexpected"] = true;
            Reject(() => ConfigBundle.Parse(Json.Encode(webServer)), "unknown Happier web server setting refused by client schema");
            // happier.account: the public 64-hex id from the exporter (accounts/server-account.mjs list), nothing else.
            var pinned = Example(); pinned["happier"] = ConfigBundle.D("mode", "same", "account", new string('a', 64));
            Check(Json.Str(Json.Map(ConfigBundle.Parse(Json.Encode(pinned)).Profile["happier"]), "account") == new string('a', 64), "happier.account accepted");
            foreach (string bad in new[]{new string('A', 64), new string('a', 63), new string('a', 64) + "\n", "Основной"}) { Json.Map(pinned["happier"])["account"] = bad; Reject(() => ConfigBundle.Parse(Json.Encode(pinned)), "happier.account " + bad.Length); }
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
            Check(ConfigBundle.Parse(Json.Encode(nestedSelection)).Profile.ContainsKey("disk"), "earlier nested paths are still accepted (they become first-level folders)");
            var namedPassword = ConfigBundle.Parse("{\"kind\":\"remoteagents-config\",\"schema\":1,\"server\":{\"rootPassword\":{\"secret\":\"custom-root\"}}}");
            Check(namedPassword.Hints["custom-root"].Contains("хостинг"),"standard field explanation independent of secret name");
            var route = Example(); route["server"] = ConfigBundle.D("routes", new[]{ConfigBundle.D("kind", "hop")});
            Reject(() => ConfigBundle.Parse(Json.Encode(route)), "hop required");
            foreach (string ipv6 in new[]{"block", "allow"}) {
                var ipv6Config = ConfigBundle.D("kind", "remoteagents-config", "schema", 1, "proxyOut", ConfigBundle.D("type", "socks", "server", "8.8.8.8", "port", 1080, "ipv6", ipv6));
                Check(ConfigBundle.Parse(Json.Encode(ipv6Config)).Profile.ContainsKey("proxyOut"), "explicit IPv6 policy " + ipv6);
                Json.Map(ipv6Config["proxyOut"])["ipv6"] = "invalid";
                Reject(() => ConfigBundle.Parse(Json.Encode(ipv6Config)), "unknown IPv6 policy");
            }
            var defaults = ConfigBundle.Parse("{\"kind\":\"remoteagents-config\",\"schema\":1,\"proxyOut\":{\"type\":\"http\",\"server\":\"proxy.example\",\"port\":8080}}");
            Check(Json.Str(Json.Map(defaults.Profile["proxyOut"]), "ipv6") == "block", "new configs block IPv6 by default");
            foreach (string method in new[]{"host", "docker"}) {
                var deploy = ConfigBundle.D("kind", "remoteagents-config", "schema", 1, "deployment", ConfigBundle.D("method", method, "dockerfile", "server/docker/Dockerfile"));
                var parsedDeploy = ConfigBundle.Parse(Json.Encode(deploy));
                Check(ServerDeployment.Profile(parsedDeploy.Profile).ContainsKey("deployment"), "deployment method survives server projection: " + method);
            }
            Reject(() => ConfigBundle.Parse("{\"kind\":\"remoteagents-config\",\"schema\":1,\"tailscale\":{\"userspace\":false}}"), "server kernel Tailscale forbidden");
            var managed = ConfigBundle.Parse("{\"kind\":\"remoteagents-config\",\"schema\":1,\"serverComponents\":{\"disk\":{\"enabled\":true,\"identity\":{\"secret\":\"disk-id\"},\"discoveryIntervalSec\":5},\"bridge\":{\"enabled\":true},\"happier\":{\"enabled\":true,\"channel\":\"stable\"}},\"agents\":{\"codex\":{\"enabled\":true,\"version\":\"0.166.0\"},\"claude\":{\"enabled\":true,\"token\":{\"secret\":\"claude-token\"}}},\"desktop\":{\"enabled\":false},\"projectViews\":{\"enabled\":false},\"sessions\":{\"cleanupEnabled\":true,\"idleHours\":2,\"intervalMinutes\":15},\"ssh\":{\"keepaliveIntervalSec\":30,\"keepaliveCountMax\":3}}");
            Check(managed.Missing.Contains("disk-id") && managed.Missing.Contains("claude-token"), "portable managed identities and provider credentials remain secret refs");
            Check(ServerDeployment.Profile(managed.Profile).ContainsKey("agents") && ServerDeployment.Profile(managed.Profile).ContainsKey("serverComponents"), "EXE forwards user components and agents to root reconciler");
            var loginOnly = ConfigBundle.Parse("{\"kind\":\"remoteagents-config\",\"schema\":1,\"agents\":{\"claude\":{\"enabled\":true,\"auth\":{\"secret\":\"missing-login\"}}}}");
            Check(ConfigRequests.SecretsFor(ConfigSections.Server, loginOnly.Profile, n => false).Count == 0, "missing agent auth allows CLI install and server waiting state");
            string schemaPath = FindSchema();
            Check(Canonical(Json.Read(schemaPath)) == Canonical(ConfigBundle.SchemaDocument()), "published schema matches compiled schema");
            Check(ConfigBundle.Parse(File.ReadAllText(Path.Combine(Path.GetDirectoryName(schemaPath),"config.paste.example.json"))).Missing.Length == 2,"published example parses with missing secrets");
            var serverExample = ConfigBundle.Parse(File.ReadAllText(Path.Combine(Path.GetDirectoryName(schemaPath), "..", "..", "server", "server-apply.example.json")));
            Check(serverExample.Missing.Contains("tailscale-auth-key") && serverExample.Missing.Contains("lan-clinic-auth"), "server apply example accepts all declarative sections");
            var serverFields = ConfigBundle.Parse("{\"kind\":\"remoteagents-config\",\"schema\":1,\"tailscale\":{\"enabled\":true,\"authKey\":{\"secret\":\"custom-tail-key\"}},\"agent\":{\"sudo\":\"apply\"}}");
            foreach (string mode in new[] { "none", "apply", "full" }) {
                var agent = ConfigBundle.Parse(Json.Encode(ConfigBundle.D("kind", "remoteagents-config", "schema", 1, "agent", ConfigBundle.D("sudo", mode))));
                Check(Json.Str(Json.Map(ServerDeployment.Profile(agent.Profile)["agent"]), "sudo") == mode, "agent.sudo accepted and forwarded: " + mode);
            }
            Reject(() => ConfigBundle.Parse(Json.Encode(ConfigBundle.D("kind", "remoteagents-config", "schema", 1, "agent", ConfigBundle.D("sudo", "invalid")))), "invalid agent.sudo");
            Check(serverFields.Hints["custom-tail-key"].Contains("Tailscale"), "Tailscale explanation independent of secret name");
            Reject(() => ConfigBundle.Parse("{\"kind\":\"remoteagents-config\",\"schema\":1,\"tailscale\":{\"advertiseRoutes\":[\"10.0.0.0/8\"]}}"), "no Tailscale subnet advertisement in master config");
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
            // Shared vector of docs/CONFIG-SERVER.md «Тестовый вектор enc1» (server/remoteagents_config.py produces it).
            var vector = ConfigBundle.Parse("{\"kind\":\"remoteagents-config\",\"schema\":1,\"server\":{\"key\":{\"secret\":\"server-key\"}},\"secrets\":{\"protected\":\"master-password\",\"kdf\":{\"name\":\"pbkdf2-sha256\",\"iterations\":200000,\"salt\":\"AAECAwQFBgcICQoLDA0ODw==\"}," +
                "\"check\":\"enc1:EBESExQVFhcYGRobHB0eH5S/AYvjmvqbyp4eatsIP0ESDucdw0ufuFBNWskJNZdj/a/PyROkWqohaJO+d8dnCA==\"," +
                "\"server-key\":\"enc1:EBESExQVFhcYGRobHB0eH9EATN4mI2yZF1iffFippgsKu5D1MyvAG2NfKVaGcnHzvCO5vWsIX2yfsu90ejzi8negWZF8qpwxkbFOMwPwBMnei8w8zX8GwmtQ4CNs3ZfL\"}}");
            Check(ConfigBundle.Unlock(vector, "Мастер-пароль 1").Secrets["server-key"] == "секрет\nвторая строка", "enc1 vector of docs/CONFIG-SERVER.md (Python/OpenSSL/.NET) decrypts");
            Reject(() => ConfigBundle.Unlock(vector, "Мастер-пароль 2"), "enc1 vector: wrong master password");
            // Shape printed by `remoteagents config export` (docs/CONFIG-SERVER.md): catalog, hop/vpn-hop/vpn-entry names,
            // disk without base, happier without key, server without rootPassword, JSON text values.
            var exported = ConfigBundle.Parse("{\"kind\":\"remoteagents-config\",\"schema\":1,\"device\":{\"name\":\"Ноутбук сына\"}," +
                "\"server\":{\"address\":\"203.0.113.10\",\"port\":22,\"login\":\"worker\",\"hostKeys\":[\"ssh-ed25519 AAAA\"],\"key\":{\"secret\":\"server-key\"}," +
                "\"routes\":[{\"kind\":\"direct\"},{\"kind\":\"proxy\",\"proxy\":{\"type\":\"socks\",\"server\":\"127.0.0.1\",\"port\":10808}}," +
                "{\"kind\":\"hop\",\"hop\":{\"host\":\"relay.example.invalid\",\"port\":22,\"user\":\"relay\",\"hostKey\":\"ssh-ed25519 AAAA\",\"key\":{\"secret\":\"hop-relay-key\"},\"password\":{\"secret\":\"hop-relay-password\"}}}]}," +
                "\"vpn\":{\"enabled\":true,\"checkUrl\":\"https://check.example.invalid/\",\"dnsServer\":\"192.0.2.53\",\"bootstrap\":{\"catalog\":{\"schema\":1,\"entries\":[{\"name\":\"Entry1\",\"ssh\":\"entry1\"}],\"hops\":[{\"name\":\"vhop\",\"ssh\":\"vhop\",\"hostKey\":[\"ssh-ed25519 AAAA\"]}],\"relays\":[],\"cdn\":[]}," +
                "\"channel\":{\"secret\":\"vpn-channel\"},\"entries\":{\"Entry1\":{\"secret\":\"vpn-entry-entry1\"}},\"hops\":{\"vhop\":{\"host\":\"127.0.0.1\",\"port\":2222,\"user\":\"hopuser\",\"key\":{\"secret\":\"vpn-hop-vhop\"}}}}}," +
                "\"happier\":{\"mode\":\"same\",\"label\":\"Основной\"},\"bridge\":{\"enabled\":true,\"allowShell\":false},\"disk\":{\"folders\":[\"Проект\",\"Проект/docs\"]}," +
                "\"secrets\":{\"server-key\":\"K\",\"hop-relay-key\":\"H\",\"hop-relay-password\":\"P\",\"vpn-channel\":\"{\\\"outbounds\\\":[]}\",\"vpn-entry-entry1\":\"{\\\"server\\\":\\\"e\\\"}\",\"vpn-hop-vhop\":\"V\"}}".Replace("\n", "\r\n"));
            Check(exported.Missing.Length == 0 && Json.Map(Json.Get(Json.Map(Json.Get(exported.Profile, "vpn")), "bootstrap")).ContainsKey("catalog"), "server export shape (catalog, hop/vpn names, JSON text values) is accepted");
            var interop = ConfigBundle.Parse("{\"kind\":\"remoteagents-config\",\"schema\":1,\"server\":{\"key\":{\"secret\":\"server-key\"}},\"secrets\":{\"protected\":\"master-password\",\"kdf\":{\"name\":\"pbkdf2-sha256\",\"iterations\":200000,\"salt\":\"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=\"},\"check\":\"enc1:AAECAwQFBgcICQoLDA0ODxDf5ZSnK4rourEgLtBAHFjzLCoRAhgTD+rS5FqlAEve+Ksk7xocQcpH4kbgYFvw6Q==\",\"server-key\":\"enc1:EBESExQVFhcYGRobHB0eHyJI8g0R/TIwsFE14BZyX2wGtchuCE50mSqa/T3/JSZbfimgnDai2DDKLz2i8pV2UhyFlSKUxze5r42EgfJ+S/8=\"}}");
            Check(ConfigBundle.Unlock(interop,"master-interop").Secrets["server-key"] == "interop-line\r\nsecond", "Python enc1 interoperability");
            string home = Path.Combine(Path.GetTempPath(), "ra-config-a-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(home);
            try {
                var embedded = Example();
                embedded["vpn"] = ConfigBundle.D("bootstrap", ConfigBundle.D("channel", ConfigBundle.D("secret", "vpn-channel")));
                Json.Map(embedded["secrets"])["vpn-channel"] = "{\"outbounds\":[]}\r\n";
                var pasted = ConfigBundle.Parse("{\r\n" + Json.Encode(embedded).Substring(1));
                Check(pasted.Missing.Length == 0, "embedded server-key and vpn-channel are counted, including CRLF values");
                string messageHome = Path.Combine(home, "message-test"); Directory.CreateDirectory(messageHome);
                ConfigBundle.Store(messageHome, pasted, null);
                Check(ConfigBundle.AcceptedSummary(messageHome) == "Конфиг принят.", "accepted embedded secrets are never logged as empty");
                Json.Map(embedded["secrets"])["server-key"] = ""; Json.Map(embedded["secrets"])["vpn-channel"] = "";
                var placeholders = ConfigBundle.Parse(Json.Encode(embedded));
                ConfigBundle.Store(messageHome, placeholders, null);
                Check(placeholders.Missing.Length == 2 && ConfigBundle.AcceptedSummary(messageHome) == "Конфиг принят.", "existing vault values are not reported as missing after placeholder paste");
                SecretVault.Set(messageHome, "vpn-channel", "");
                Check(ConfigBundle.AcceptedSummary(messageHome) == "Конфиг принят; не заданы секреты: vpn-channel (спрошу по одному).", "truly missing secret is named without values");
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
                var diskChange = ConfigBundle.Parse(Json.Encode(ConfigBundle.D("kind","remoteagents-config","schema",1,"disk",ConfigBundle.D("folders", new object[]{ConfigBundle.D("id", "Project")}))));
                Check(ConfigBundle.Conflicts(home,diskChange).Length == 0, "leaving a folder out of disk.folders is not a conflict (it only lists what to accept)");
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
                SecretVault.Set(home,"hop-password", ""); SecretVault.Materialize(home);
                var withoutPassword = Json.Read(SecretVault.MaterializedPath(home));
                Check(Json.Strings(withoutPassword["missing"]).Contains("hop-password") && !Json.Encode(Json.Get(withoutPassword,"routes")).Contains("passwordFile"), "missing secret is listed, its stale file is not referenced");
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
                Json.Write(Path.Combine(diskHome,"selection.json"),ConfigBundle.D("paths",new[]{"Project/docs"})); // earlier install: no longer read
                string legacyKey = Path.Combine(legacyHome,"ssh-profiles","current","id_ed25519"), legacySsh = Path.Combine(legacyHome,"ssh-profiles","current","ssh-transport.json");
                SecretVault.WritePrivate(legacyHome,legacyKey,"LEGACY-KEY\r\n");
                Json.Write(legacySsh,ConfigBundle.D("serverAddress","legacy.example.invalid","login","worker","keyPath",legacyKey));
                Json.Write(Path.Combine(legacyHome,"config.json"),ConfigBundle.D("transport",ConfigBundle.D("profilePath",legacySsh),"happier",ConfigBundle.D("label","Старый аккаунт")));
                SecretVault.WritePrivate(legacyHome,Path.Combine(legacyHome,"secrets","happier-account.key"),"LEGACY-HAPPIER-KEY");
                var legacyChange = ConfigBundle.Parse(Json.Encode(ConfigBundle.D("kind","remoteagents-config","schema",1,"disk",ConfigBundle.D("base","D:\\Disk","folders",new string[0]),"happier",ConfigBundle.D("label","Старый аккаунт","key",ConfigBundle.D("secret","happier-key")),"secrets",ConfigBundle.D("happier-key","CHANGED-ACCOUNT-KEY"))));
                Check(ConfigBundle.Conflicts(legacyHome,legacyChange).Length == 2,"legacy root and account-key conflicts found");
                ConfigBundle.Store(legacyHome,ConfigBundle.Parse("{\"kind\":\"remoteagents-config\",\"schema\":1,\"bridge\":{\"enabled\":true}}"),null);
                var legacyRecovered = ConfigBundle.Parse(ConfigBundle.Export(legacyHome,null));
                Check(legacyRecovered.Secrets["server-key"] == "LEGACY-KEY\r\n" && legacyRecovered.Secrets["happier-key"] == "LEGACY-HAPPIER-KEY" && Json.Str(Json.Map(legacyRecovered.Profile["disk"]),"base") == "C:\\Users\\owner\\Disk" && !Json.Map(legacyRecovered.Profile["disk"]).ContainsKey("folders"),"first profile preserves the existing Disk root and keys; accepted folders live in Syncthing, not in the config");
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
