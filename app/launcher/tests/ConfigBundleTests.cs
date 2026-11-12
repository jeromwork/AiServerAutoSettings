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
            foreach (var pair in ConfigBundle.D("schema", 2, "kind", "wrong", "extra", true, "device", ConfigBundle.D("extra", 1), "server", ConfigBundle.D("password", "must-be-reference"), "disk", ConfigBundle.D("folders", new[]{"Project/nested"}), "vpn", ConfigBundle.D("enabled", "true"))) {
                var bad = new Dictionary<string, object>(valid); bad[pair.Key] = pair.Value;
                Reject(() => ConfigBundle.Parse(Json.Encode(bad)), "schema " + pair.Key);
            }
            foreach (string text in new[]{"", "[]", "null", "{\"kind\":\"remoteagents-config\",\"schema\":1,}", "{\"kind\":\"remoteagents-config\",\"schema\":1,\"schema\":1}", "{\"kind\":\"remoteagents-config\",\"schema\":1} trailing", "{'kind':'remoteagents-config','schema':1}"}) Reject(() => ConfigBundle.Parse(text), "invalid JSON");
            var missing = Example(); missing["secrets"] = ConfigBundle.D("server-key", "");
            p = ConfigBundle.Parse(Json.Encode(missing));
            Check(p.Missing.SequenceEqual(new[]{"server-key"}) && p.Hints["server-key"].Length > 0, "missing with standard hint");
            var reference = ConfigBundle.D("secret", "lan-Офис-ovpn", "hint", "Профиль сети");
            missing["server"] = ConfigBundle.D("key", reference);
            p = ConfigBundle.Parse(Json.Encode(missing));
            Check(p.Missing.Contains("lan-Офис-ovpn") && p.Hints["lan-Офис-ovpn"] == "Профиль сети", "Unicode and custom hint");
            foreach (string name in new[]{"../bad", "Upper", "protected", "a/b", new string('a',65)}) { reference["secret"] = name; Reject(() => ConfigBundle.Parse(Json.Encode(missing)), "secret name"); }
            var route = Example(); route["server"] = ConfigBundle.D("routes", new[]{ConfigBundle.D("kind", "hop")});
            Reject(() => ConfigBundle.Parse(Json.Encode(route)), "hop required");
            string schemaPath = Path.GetFullPath("app/launcher/config.paste.schema.json");
            if (File.Exists(schemaPath)) Check(Canonical(Json.Read(schemaPath)) == Canonical(ConfigBundle.SchemaDocument()), "published schema matches compiled schema");
            Console.WriteLine("PASS: CONFIG: " + count + " assertions");
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
