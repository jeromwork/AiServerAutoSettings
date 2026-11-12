using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace RemoteAgents.Launcher
{
    internal sealed class ParsedConfig
    {
        public Dictionary<string, object> Profile;
        public Dictionary<string, string> Secrets;
        public bool Locked;
        public string[] Missing;
        public Dictionary<string, string> Hints;
        internal Dictionary<string, object> Protection;
    }

    // A small declarative schema is compiled into the EXE so validation also works before
    // the bundle is unpacked. ConfigBundleTests verifies it matches config.paste.schema.json.
    internal static class ConfigBundle
    {
        internal const int MaxLength = 4 * 1024 * 1024;
        internal const string Hidden = "<есть, скрыт>";
        internal const string NamePattern = "^(?!.*[A-Z])[a-z0-9\\u0080-\\uFFFF][a-z0-9._\\u0080-\\uFFFF-]{0,63}$";
        internal static Dictionary<string, object> D(params object[] pairs)
        {
            var d = new Dictionary<string, object>(StringComparer.Ordinal);
            for (int i = 0; i < pairs.Length; i += 2) d[(string)pairs[i]] = pairs[i + 1];
            return d;
        }
        static Dictionary<string, object> S(int max = 4096, int min = 0, string pattern = null)
        {
            var d = D("type", "string", "minLength", min, "maxLength", max);
            if (pattern != null) d["pattern"] = pattern + "(?![\\s\\S])";
            return d;
        }
        static Dictionary<string, object> E(params string[] values) { return D("type", "string", "enum", values); }
        static Dictionary<string, object> B() { return D("type", "boolean"); }
        static Dictionary<string, object> N(int min, int max) { return D("type", "integer", "minimum", min, "maximum", max); }
        static Dictionary<string, object> A(object item, int max = 256) { return D("type", "array", "items", item, "maxItems", max, "uniqueItems", true); }
        static Dictionary<string, object> O(Dictionary<string, object> fields, params string[] required)
        {
            fields["hint"] = S(2048);
            var d = D("type", "object", "properties", fields, "additionalProperties", false);
            if (required.Length > 0) d["required"] = required;
            return d;
        }
        static Dictionary<string, object> Named(object item, string pattern = NamePattern)
        { return D("type", "object", "propertyNames", S(64, 1, pattern), "additionalProperties", item, "maxProperties", 256); }
        static Dictionary<string, object> Ref(string standard = null)
        {
            var d = O(D("secret", S(64, 1, NamePattern)), "secret");
            d["description"] = standard == null ? "Именованная ссылка; значение хранится только в secrets/vault" : StandardHint(standard);
            if (standard != null) d["examples"] = new[]{D("secret", standard)};
            return d;
        }
        static Dictionary<string, object> Host() { return S(253, 1, "^[a-zA-Z0-9][a-zA-Z0-9.:-]{0,252}$"); }
        static Dictionary<string, object> User() { return S(32, 1, "^[a-z_][a-z0-9_-]{0,31}$"); }
        static Dictionary<string, object> Url()
        { var d = S(2048, 1); d["format"] = "https-url"; return d; }
        static Dictionary<string, object> Proxy()
        { return O(D("type", E("socks", "http"), "server", Host(), "port", N(1, 65535), "login", S(256), "password", Ref("proxy-out-password"), "checkUrl", Url()), "type", "server", "port"); }
        static Dictionary<string, object> Hop()
        { return O(D("host", Host(), "port", N(1, 65535), "user", User(), "hostKey", S(4096, 1, "^[^\\r\\n\\x00]+$"), "key", Ref("hop-key"), "password", Ref("hop-password")), "host", "user"); }
        internal static Dictionary<string, object> SchemaDocument()
        {
            var route = O(D("kind", E("direct", "proxy", "hop"), "proxy", Proxy(), "hop", Hop()), "kind");
            route["allOf"] = new object[] {
                D("if", D("properties", D("kind", D("const", "proxy"))), "then", D("required", new[]{"proxy"})),
                D("if", D("properties", D("kind", D("const", "hop"))), "then", D("required", new[]{"hop"}))
            };
            // Public transport catalog as printed by `remoteagents config export` (server-transport-catalog.py, schema 1).
            // Only its shape is checked here; Wizard.ps1 Assert-WizardCatalog validates every row before use.
            var rows = D("type", "array", "items", D("type", "object", "maxProperties", 64), "maxItems", 256);
            var catalog = D("type", "object", "properties", D("schema", D("const", 1), "entries", rows, "hops", rows, "relays", rows, "cdn", rows),
                "additionalProperties", false, "required", new[]{"schema"});
            var bootstrap = O(D("catalog", catalog, "channel", Ref("vpn-channel"), "entries", Named(Ref(), "^[a-zA-Z0-9][a-zA-Z0-9_-]{0,47}$"), "hops", Named(Hop(), "^[a-zA-Z0-9][a-zA-Z0-9_-]{0,47}$")));
            var component = O(D("enabled", B()));
            var props = D(
                "kind", D("const", "remoteagents-config"), "schema", D("const", 1),
                "device", O(D("name", S(80, 1, "^[^\\r\\n\\x00]+$"))),
                "server", O(D("address", Host(), "port", N(1, 65535), "login", User(),
                    "hostKeys", A(S(4096, 1, "^[^\\r\\n\\x00]+$"), 32), "key", Ref("server-key"), "rootPassword", Ref("server-root-password"), "routes", A(route, 32))),
                "connection", O(D("enabled", B())),
                "bridge", O(D("enabled", B(), "allowShell", B())),
                "happier", O(D("mode", E("same", "new"), "label", S(80, 1), "serverUrl", Url(), "webappUrl", Url(), "key", Ref("happier-key"))),
                "disk", O(D("base", S(1024, 1, "^[^\\r\\n\\x00]+$"), "folders", A(S(1024, 1, "^[^\\\\<>:\"|?*\\x00-\\x1f]+$")))),
                "vpn", O(D("enabled", B(), "checkUrl", Url(), "dnsServer", S(253, 1), "bootstrap", bootstrap)),
                "proxyOut", Proxy(),
                "lan", A(O(D("name", S(64, 1, "^[^/\\\\\\r\\n\\x00]+$"), "kind", E("openvpn"), "ovpn", Ref(),
                    "login", S(256), "password", Ref(), "host", Host(), "port", N(1, 65535), "checkUrl", Url()), "name", "kind", "ovpn"), 64),
                "components", O(D("transport", component, "disk", component, "control", component, "vpn", component)),
                "secrets", D("type", "object", "properties", D(
                    "protected", E("master-password"),
                    "kdf", O(D("name", E("pbkdf2-sha256"), "iterations", N(200000, 2000000), "salt", S(128, 1)), "name", "iterations", "salt"),
                    "check", S(MaxLength, 1)), "additionalProperties", S(MaxLength), "propertyNames", S(64, 1, NamePattern), "maxProperties", 259));
            var schema = O(props, "kind", "schema");
            schema["$schema"] = "https://json-schema.org/draft/2020-12/schema";
            schema["title"] = "RemoteAgents paste configuration v1";
            return schema;
        }

        public static ParsedConfig Parse(string text)
        {
            if (text == null || text.Length > MaxLength || Files.Utf8.GetByteCount(text) > MaxLength) throw Bad("Конфиг пуст или превышает 4 МиБ");
            Dictionary<string, object> root;
            try {
                root = StrictParse(text) as Dictionary<string, object>;
            } catch { throw Bad("Конфиг должен быть корректным JSON без повторяющихся полей"); }
            Validate(root, SchemaDocument(), "конфиг");
            var p = new ParsedConfig { Profile = new Dictionary<string, object>(root), Secrets = new Dictionary<string, string>(StringComparer.Ordinal), Protection = new Dictionary<string, object>() };
            p.Profile.Remove("secrets");
            var secrets = Json.Map(Json.Get(root, "secrets"));
            p.Locked = secrets.ContainsKey("protected");
            foreach (var pair in secrets) {
                if (pair.Key == "protected" || pair.Key == "kdf" || pair.Key == "check") { p.Protection[pair.Key] = pair.Value; continue; }
                ValidName(pair.Key);
                string value = (string)pair.Value;
                if (value == Hidden) value = ""; // AI copies are editable public profiles, never literal credentials.
                if (p.Locked && value.Length > 0) CheckEnvelope(value);
                p.Secrets[pair.Key] = value;
            }
            if (p.Locked) {
                if (!secrets.ContainsKey("kdf") || !secrets.ContainsKey("check")) throw Bad("Нужны secrets.kdf и secrets.check");
                var kdf = Json.Map(secrets["kdf"]);
                byte[] salt = Base64(Json.Str(kdf, "salt"));
                if (salt.Length < 16 || salt.Length > 64) throw Bad("Соль мастер-пароля: 16–64 байта");
                CheckEnvelope(Json.Str(secrets, "check"));
            } else if (secrets.ContainsKey("check") || secrets.ContainsKey("kdf")) throw Bad("kdf/check допустимы только с мастер-паролем");
            CheckSemantics(p.Profile);
            RefreshMissing(p);
            return p;
        }
        internal static object StrictParse(string text)
        {
            if (text == null || text.Length > MaxLength || Files.Utf8.GetByteCount(text) > MaxLength) throw Bad("JSON превышает 4 МиБ");
            try { StrictJson.Check(text); return Json.Parse(text); }
            catch { throw Bad("Некорректный JSON без допустимого однозначного разбора"); }
        }
        internal static InvalidDataException Bad(string message) { return new InvalidDataException(message); }
        internal static void ValidName(string name)
        {
            if (name == null || name.Length == 0 || Regex.Match(name, NamePattern).Length != name.Length || name.Any(c => c > 127 && !char.IsLetter(c)) || new[]{"protected", "kdf", "check", "hint"}.Contains(name)) throw Bad("Недопустимое имя секрета");
        }
        static void Validate(object value, Dictionary<string, object> schema, string path)
        {
            object constant;
            if (schema.TryGetValue("const", out constant) && Json.Encode(value) != Json.Encode(constant)) throw Bad("Неизвестный формат или версия: " + path);
            string type = Json.Str(schema, "type");
            if (schema.ContainsKey("required")) foreach (string req in Json.Strings(schema["required"])) if (!Json.Map(value).ContainsKey(req)) throw Bad("Отсутствует поле " + path + "." + req);
            if (type == "object") {
                var map = value as Dictionary<string, object>;
                if (map == null) throw Bad("Нужен объект: " + path);
                if (map.Count > Json.Int(schema, "maxProperties", 512)) throw Bad("Слишком много полей: " + path);
                var props = Json.Map(Json.Get(schema, "properties"));
                foreach (string req in Json.Strings(Json.Get(schema, "required"))) if (!map.ContainsKey(req)) throw Bad("Отсутствует поле " + path + "." + req);
                foreach (var pair in map) {
                    if (schema.ContainsKey("propertyNames")) Validate(pair.Key, Json.Map(schema["propertyNames"]), path);
                    object rule;
                    if (props.TryGetValue(pair.Key, out rule)) Validate(pair.Value, Json.Map(rule), path + "." + pair.Key);
                    else {
                        rule = Json.Get(schema, "additionalProperties");
                        if (rule is bool && !(bool)rule) throw Bad("Неизвестное поле в разделе " + path);
                        if (rule is Dictionary<string, object>) Validate(pair.Value, Json.Map(rule), path);
                    }
                }
            } else if (type == "array") {
                if (!(value is System.Collections.IEnumerable) || value is string || value is System.Collections.IDictionary) throw Bad("Нужен список: " + path);
                var items = Json.Array(value);
                if (items.Length > Json.Int(schema, "maxItems", 256)) throw Bad("Слишком длинный список: " + path);
                if (Json.Bool(schema, "uniqueItems") && items.Select(Json.Encode).Distinct(StringComparer.Ordinal).Count() != items.Length) throw Bad("Повторяющиеся элементы: " + path);
                foreach (var item in items) Validate(item, Json.Map(schema["items"]), path);
            } else if (type == "string") {
                var s = value as string;
                if (s == null || s.Length < Json.Int(schema, "minLength", 0) || s.Length > Json.Int(schema, "maxLength", MaxLength)) throw Bad("Неверная строка: " + path);
                if (schema.ContainsKey("pattern")) { var match = Regex.Match(s,(string)schema["pattern"]); if (!match.Success || match.Index != 0 || match.Length != s.Length) throw Bad("Недопустимые символы: " + path); }
                if (Json.Str(schema, "format") == "https-url") {
                    Uri u;
                    if (!Uri.TryCreate(s, UriKind.Absolute, out u) || u.Scheme != "https" || u.UserInfo.Length > 0 || s.Any(char.IsWhiteSpace) || s.IndexOfAny(new[]{'\'', '"', '\\', '`', '$'}) >= 0) throw Bad("Нужен HTTPS URL без пароля: " + path);
                }
            } else if (type == "integer") {
                decimal n;
                if (value == null || value is bool || value is string || !decimal.TryParse(Convert.ToString(value, CultureInfo.InvariantCulture), NumberStyles.Number, CultureInfo.InvariantCulture, out n) || n != decimal.Truncate(n) || n < Json.Int(schema, "minimum", int.MinValue) || n > Json.Int(schema, "maximum", int.MaxValue)) throw Bad("Неверное целое число: " + path);
            } else if (type == "boolean" && !(value is bool)) throw Bad("Нужно true или false: " + path);
            if (schema.ContainsKey("enum") && !Json.Strings(schema["enum"]).Contains(value as string, StringComparer.Ordinal)) throw Bad("Неизвестный вариант: " + path);
            foreach (var condition in Json.Array(Json.Get(schema, "allOf"))) {
                var c = Json.Map(condition);
                var expected = Json.Map(Json.Get(Json.Map(Json.Get(c, "if")), "properties"));
                var map = Json.Map(value);
                if (expected.All(x => Json.Encode(Json.Get(map, x.Key)) == Json.Encode(Json.Get(Json.Map(x.Value), "const")))) Validate(value, Json.Map(Json.Get(c, "then")), path);
            }
        }
        static void CheckSemantics(Dictionary<string, object> profile)
        {
            foreach (var reference in References(profile)) ValidName(Json.Str(reference, "secret"));
            var server = Json.Map(Json.Get(profile, "server"));
            foreach (var row in Json.Array(Json.Get(server, "routes")).Select(Json.Map)) {
                string kind = Json.Str(row, "kind");
                if ((kind != "proxy" && row.ContainsKey("proxy")) || (kind != "hop" && row.ContainsKey("hop"))) throw Bad("Поля маршрута не соответствуют kind");
            }
            var folders = Json.Strings(Json.Get(Json.Map(Json.Get(profile, "disk")), "folders"));
            if (folders.Distinct(StringComparer.OrdinalIgnoreCase).Count() != folders.Length) throw Bad("Повторяющиеся папки Disk");
            foreach (string f in folders) {
                string[] parts = f.Split('/');
                if (!Regex.IsMatch(parts[0], "^[\\p{L}\\p{N}_][\\p{L}\\p{N}_. -]{0,127}$") || parts[0].Contains("..")) throw Bad("Недопустимое имя проекта Disk");
                foreach (string part in parts) if (part.Length == 0 || part.Length > 255 || part == "." || part == ".." || part.EndsWith(".") || part.EndsWith(" ") || Regex.IsMatch(part, "^(?i:con|prn|aux|nul|com[0-9]|lpt[0-9])(?:\\.|$)")) throw Bad("Недопустимый путь выбора Disk");
            }
        }
        internal static IEnumerable<Dictionary<string, object>> References(object value)
        {
            var map = value as Dictionary<string, object>;
            if (map != null) {
                if (map.ContainsKey("secret")) yield return map;
                else foreach (var child in map.Values) foreach (var r in References(child)) yield return r;
            } else foreach (var child in Json.Array(value)) foreach (var r in References(child)) yield return r;
        }
        internal static void RefreshMissing(ParsedConfig p)
        {
            p.Hints = new Dictionary<string, string>(StringComparer.Ordinal);
            ReferenceHints(p.Profile, "", p.Hints);
            p.Missing = p.Hints.Keys.Where(n => !p.Secrets.ContainsKey(n) || p.Secrets[n].Length == 0).OrderBy(n => n, StringComparer.Ordinal).ToArray();
        }
        static void ReferenceHints(object value, string path, Dictionary<string,string> hints)
        {
            var map = value as Dictionary<string, object>;
            if (map != null) {
                if (map.ContainsKey("secret")) {
                    string name = Json.Str(map,"secret"), custom = Json.Str(map,"hint");
                    string standard = name;
                    if (path == "server.rootPassword") standard = "server-root-password";
                    else if (path == "server.key") standard = "server-key";
                    else if (path == "happier.key") standard = "happier-key";
                    else if (path.EndsWith(".hop.password") || path.StartsWith("vpn.bootstrap.hops.") && path.EndsWith(".password")) standard = "hop-password";
                    else if (path.EndsWith(".hop.key") || path.StartsWith("vpn.bootstrap.hops.") && path.EndsWith(".key")) standard = "hop-key";
                    else if (path == "proxyOut.password" || path.EndsWith(".proxy.password")) standard = "proxy-out-password";
                    else if (path == "vpn.bootstrap.channel") standard = "vpn-channel";
                    if (!hints.ContainsKey(name) || custom.Length > 0) hints[name] = custom.Length > 0 ? custom : StandardHint(standard);
                } else foreach (var pair in map) ReferenceHints(pair.Value,path.Length == 0 ? pair.Key : path + "." + pair.Key,hints);
            } else foreach (var item in Json.Array(value)) ReferenceHints(item,path + "[]",hints);
        }
        internal static string StandardHint(string name)
        {
            if (name.StartsWith("vpn-entry-",StringComparison.Ordinal)) return "JSON client.json VPN-узла целиком, полученный у владельца сервера";
            if (name.StartsWith("lan-",StringComparison.Ordinal) && name.EndsWith("-ovpn",StringComparison.Ordinal)) return "Профиль OpenVPN этой сети с включёнными сертификатами и ключами";
            if (name.StartsWith("lan-",StringComparison.Ordinal) && name.EndsWith("-password",StringComparison.Ordinal)) return "Пароль пользователя локальной сети, выданный её администратором";
            switch (name) {
                case "server-root-password": return "Пароль root сервера — его присылает хостинг при покупке сервера";
                case "server-key": return "Закрытый SSH-ключ доступа к серверу";
                case "happier-key": return "Секретный ключ аккаунта Happier из его настроек";
                case "hop-key": return "Закрытый SSH-ключ промежуточного сервера";
                case "hop-password": return "Пароль SSH промежуточного сервера";
                case "route-proxy-password":
                case "proxy-out-password": return "Пароль серверного прокси, выданный его владельцем";
                case "vpn-channel": return "JSON канала связи с сервера";
                default: return "Введите секрет «" + name + "» в этом окне. Он не попадёт в чат или журнал";
            }
        }
        static byte[] Base64(string value) { try { return Convert.FromBase64String(value); } catch { throw Bad("Неверный base64 защищённого секрета"); } }
        static byte[] CheckEnvelope(string value)
        {
            if (!value.StartsWith("enc1:", StringComparison.Ordinal)) throw Bad("Защищённые секреты должны иметь формат enc1");
            var bytes = Base64(value.Substring(5));
            if (bytes.Length < 64 || (bytes.Length - 48) % 16 != 0) throw Bad("Повреждён enc1");
            return bytes;
        }

        internal static Dictionary<string, object> ReadSettings(string home)
        {
            string path = Path.Combine(Path.GetFullPath(home), "config.json"); SecretVault.SafePath(home, path);
            return File.Exists(path) ? Json.Read(path) : D();
        }
        internal static Dictionary<string, object> CurrentProfile(string home, Dictionary<string, object> settings)
        {
            if (settings.ContainsKey("profile")) return Parse(Json.Encode(Json.Get(settings, "profile"))).Profile;
            var profile = D("kind", "remoteagents-config", "schema", 1);
            // Legacy settings are public; only known fields are copied. Runtime-only knobs
            // and executable/command fields are never accepted from a paste configuration.
            var definitions = Json.Map(SchemaDocument()["properties"]);
            foreach (string section in new[]{"device", "bridge", "happier", "components"}) {
                var source = Json.Map(Json.Get(settings, section));
                var fields = Json.Map(Json.Get(Json.Map(definitions[section]), "properties"));
                var target = source.Where(x => fields.ContainsKey(x.Key)).ToDictionary(x => x.Key, x => x.Value);
                if (section == "happier" && target.Count > 0 && File.Exists(Path.Combine(home,"secrets","happier-account.key"))) target["key"] = D("secret","happier-key");
                if (target.Count > 0) profile[section] = target;
            }
            var oldProxy = Json.Map(Json.Get(settings,"proxy"));
            if (oldProxy.ContainsKey("type") && oldProxy.ContainsKey("server") && oldProxy.ContainsKey("port")) {
                var proxy = D("type",oldProxy["type"],"server",oldProxy["server"],"port",oldProxy["port"]);
                if (oldProxy.ContainsKey("ipCheckUrl")) proxy["checkUrl"] = oldProxy["ipCheckUrl"];
                if (File.Exists(Path.Combine(home,"secrets","proxy-out.json"))) proxy["password"] = D("secret","proxy-out-password");
                profile["proxyOut"] = proxy;
            }
            var transport = Json.Map(Json.Get(settings, "transport"));
            string path = Json.Str(transport, "profilePath");
            if (path.Length > 0 && File.Exists(path)) {
                SecretVault.SafePath(home, path); var ssh = Json.Read(path);
                profile["server"] = D("address", Json.Str(ssh, "serverAddress"), "port", RuntimePort(ssh), "login", Json.Str(ssh, "login"), "key", D("secret", "server-key"));
            }
            string homePath = Path.GetFullPath(home).TrimEnd(Path.DirectorySeparatorChar,Path.AltDirectorySeparatorChar);
            if (string.Equals(Path.GetFileName(homePath), "RemoteAgents", StringComparison.OrdinalIgnoreCase) || string.Equals(Path.GetFileName(homePath), "RemoteVPN", StringComparison.OrdinalIgnoreCase)) {
                string parent = Path.GetDirectoryName(homePath), diskHome = Path.Combine(parent,"RemoteDisk");
                string basePath = Path.Combine(diskHome,"base.txt"), selectionPath = Path.Combine(diskHome,"selection.json");
                var disk = D();
                if (File.Exists(basePath)) { SecretVault.SafePath(parent,basePath); disk["base"] = Files.ReadLine(basePath); }
                if (File.Exists(selectionPath)) { SecretVault.SafePath(parent,selectionPath); disk["folders"] = Json.Strings(Json.Get(Json.Read(selectionPath),"paths")); }
                if (disk.Count > 0) profile["disk"] = disk;
            }
            return Parse(Json.Encode(profile)).Profile;
        }
        internal static void LegacyValues(string home, Dictionary<string, object> settings, Dictionary<string, object> profile, Dictionary<string,string> values)
        {
            if (settings.ContainsKey("profile")) return;
            Action<string,string> read = (name,path) => {
                if (values.ContainsKey(name) || !File.Exists(path)) return;
                SecretVault.SafePath(home,path); if (new FileInfo(path).Length > MaxLength) throw Bad("Слишком большой файл секрета");
                values[name] = File.ReadAllText(path);
            };
            string sshPath = Json.Str(Json.Map(Json.Get(settings,"transport")),"profilePath");
            if (sshPath.Length > 0 && File.Exists(sshPath)) { SecretVault.SafePath(home,sshPath); var ssh = Json.Read(sshPath); string keyPath = Json.Str(ssh,"keyPath"); if (keyPath.Length > 0) read("server-key",keyPath); }
            if (profile.ContainsKey("happier")) read("happier-key",Path.Combine(home,"secrets","happier-account.key"));
            string proxyPath = Path.Combine(home,"secrets","proxy-out.json");
            if (profile.ContainsKey("proxyOut") && File.Exists(proxyPath)) {
                SecretVault.SafePath(home,proxyPath); var auth = Json.Read(proxyPath);
                if (!values.ContainsKey("proxy-out-password")) values["proxy-out-password"] = Json.Str(auth,"password");
                Json.Map(profile["proxyOut"])["login"] = Json.Str(auth,"username");
            }
        }
        internal static int RuntimePort(Dictionary<string, object> ssh)
        {
            int port = Json.Int(ssh, "serverPort", Json.Int(ssh, "port", 22));
            var args = Json.Strings(Json.Get(ssh, "arguments"));
            for (int i = 0; i + 1 < args.Length; i++) if (args[i] == "-p") { int n; if (int.TryParse(args[i+1], out n)) port = n; }
            return port;
        }
        static Dictionary<string, object> Merge(Dictionary<string, object> before, Dictionary<string, object> patch)
        {
            var result = new Dictionary<string, object>(before, StringComparer.Ordinal);
            foreach (var pair in patch) {
                var map = pair.Value as Dictionary<string, object>;
                result[pair.Key] = map != null && !map.ContainsKey("secret") ? Merge(Json.Map(Json.Get(before, pair.Key)), map) : pair.Value;
            }
            return result;
        }
        static Dictionary<string, string> FindConflicts(string home, ParsedConfig p, Dictionary<string, object> settings, Dictionary<string, string> vault)
        {
            var result = new Dictionary<string, string>(StringComparer.Ordinal);
            var before = CurrentProfile(home, settings); LegacyValues(home,settings,before,vault);
            var oldServer = Json.Map(Json.Get(before, "server")); var server = Json.Map(Json.Get(p.Profile, "server"));
            if (new[]{"address", "port", "login"}.Any(k => server.ContainsKey(k) && oldServer.ContainsKey(k) && Json.Encode(server[k]) != Json.Encode(oldServer[k]))) {
                var merged = Merge(oldServer, server);
                result["server"] = "сейчас " + Endpoint(oldServer) + " / в конфиге " + Endpoint(merged);
            }
            var oldAccount = Json.Map(Json.Get(before, "happier")); var account = Json.Map(Json.Get(p.Profile, "happier"));
            bool different = new[]{"mode", "label", "serverUrl", "webappUrl"}.Any(k => account.ContainsKey(k) && oldAccount.ContainsKey(k) && Json.Encode(account[k]) != Json.Encode(oldAccount[k]));
            string oldKey = Json.Str(Json.Map(Json.Get(oldAccount, "key")), "secret"), key = Json.Str(Json.Map(Json.Get(account, "key")), "secret");
            if (key.Length > 0 && oldAccount.Count > 0) {
                if (oldKey != key) different = true;
                string previous, incoming;
                if (p.Secrets.TryGetValue(key, out incoming) && incoming.Length > 0 && vault.TryGetValue(oldKey.Length > 0 ? oldKey : key, out previous) && previous.Length > 0 && incoming != previous) different = true;
            }
            if (account.Count > 0 && oldAccount.Count > 0 && different) result["happier"] = "сейчас аккаунт «" + Json.Str(oldAccount, "label") + "» / в конфиге другой аккаунт «" + Json.Str(account, "label") + "»";
            var oldDisk = Json.Map(Json.Get(before, "disk")); var disk = Json.Map(Json.Get(p.Profile, "disk"));
            if (disk.ContainsKey("base") && oldDisk.ContainsKey("base") && !string.Equals(Json.Str(disk,"base").TrimEnd('\\','/'), Json.Str(oldDisk,"base").TrimEnd('\\','/'), StringComparison.OrdinalIgnoreCase))
                result["disk"] = "сейчас корень «" + Json.Str(oldDisk,"base") + "» / в конфиге «" + Json.Str(disk,"base") + "»";
            if (disk.ContainsKey("folders")) {
                var kept = new HashSet<string>(Json.Strings(disk["folders"]), StringComparer.OrdinalIgnoreCase);
                var removed = Json.Strings(Json.Get(oldDisk, "folders")).Where(f => !kept.Any(k => string.Equals(f,k,StringComparison.OrdinalIgnoreCase) || f.StartsWith(k+"/",StringComparison.OrdinalIgnoreCase))).ToArray();
                if (removed.Length > 0) result["disk"] = (result.ContainsKey("disk") ? result["disk"] + "; " : "") + "сейчас выбраны папки «" + string.Join(", ", removed) + "» / в конфиге они убраны";
            }
            var values = vault.Values.Concat(p.Locked ? (IEnumerable<string>)new string[0] : p.Secrets.Values).Where(v => v.Length > 0).Distinct().OrderByDescending(v => v.Length).ToArray();
            foreach (string section in result.Keys.ToArray()) result[section] = Scrub(result[section], values);
            return result;
        }
        static string Endpoint(Dictionary<string, object> server)
        { return Json.Str(server, "login") + "@" + Json.Str(server, "address") + ":" + Json.Int(server, "port", 22); }
        public static string[] Conflicts(string home, ParsedConfig p)
        {
            if (p == null) throw Bad("Нет конфига");
            using (var lease = new SecretVault.Lease(home)) return FindConflicts(home, p, ReadSettings(home), SecretVault.Load(home)).Select(x => x.Key + ": " + x.Value).ToArray();
        }
        public static void Store(string home, ParsedConfig p, IEnumerable<string> acceptSections)
        {
            if (p == null || p.Locked) throw Bad("Сначала введите мастер-пароль");
            // Revalidate even if the caller has edited the public fields after Parse.
            p = Parse(Pack(p, null));
            using (var lease = new SecretVault.Lease(home)) {
                var settings = ReadSettings(home); var oldValues = SecretVault.Load(home);
                var before = CurrentProfile(home, settings); LegacyValues(home,settings,before,oldValues);
                var conflicts = FindConflicts(home, p, settings, oldValues);
                var accepted = new HashSet<string>(acceptSections ?? new string[0], StringComparer.OrdinalIgnoreCase);
                var blocked = new HashSet<string>(conflicts.Keys.Where(k => !accepted.Contains(k)), StringComparer.Ordinal);
                var patch = p.Profile.Where(x => !blocked.Contains(x.Key)).ToDictionary(x => x.Key, x => x.Value);
                var profile = Merge(before, patch);
                var protectedNames = new HashSet<string>(blocked.SelectMany(k => References(Json.Get(before, k)).Concat(References(Json.Get(p.Profile, k)))).Select(r => Json.Str(r, "secret")), StringComparer.Ordinal);
                var values = new Dictionary<string, string>(oldValues, StringComparer.Ordinal);
                foreach (var pair in p.Secrets) if (!protectedNames.Contains(pair.Key) && (pair.Value.Length > 0 || !values.ContainsKey(pair.Key))) values[pair.Key] = pair.Value;
                // Empty/AI placeholders preserve values already present in the vault.
                var checkedRoot = new Dictionary<string, object>(profile); checkedRoot["secrets"] = values; Parse(Json.Encode(checkedRoot));
                settings["profile"] = profile;
                if (!settings.ContainsKey("schema")) settings["schema"] = 1;
                if (!settings.ContainsKey("version")) settings["version"] = 1;
                SecretVault.Save(home, values);
                try { Json.Write(Path.Combine(Path.GetFullPath(home), "config.json"), settings); }
                catch { SecretVault.Save(home, oldValues); throw; }
            }
        }
        static ParsedConfig Snapshot(string home)
        {
            var settings = ReadSettings(home); var profile = CurrentProfile(home, settings); var secrets = SecretVault.Load(home);
            LegacyValues(home,settings,profile,secrets);
            // Legacy installations already have a key on disk; include that exact key in a
            // recovery export instead of asking for the root password again.
            var server = Json.Map(Json.Get(profile, "server"));
            string keyName = Json.Str(Json.Map(Json.Get(server, "key")), "secret");
            string sshPath = Json.Str(Json.Map(Json.Get(settings, "transport")), "profilePath");
            if (keyName.Length > 0 && !secrets.ContainsKey(keyName) && sshPath.Length > 0 && File.Exists(sshPath)) {
                SecretVault.SafePath(home, sshPath); var ssh = Json.Read(sshPath);
                string keyPath = Json.Str(ssh, "keyPath");
                if (Json.Str(server, "address") == Json.Str(ssh, "serverAddress") && Json.Int(server,"port",22) == RuntimePort(ssh) && Json.Str(server,"login") == Json.Str(ssh,"login") && keyPath.Length > 0 && File.Exists(keyPath)) { SecretVault.SafePath(home, keyPath); secrets[keyName] = File.ReadAllText(keyPath); }
            }
            foreach (var r in References(profile)) { string name = Json.Str(r, "secret"); if (!secrets.ContainsKey(name)) secrets[name] = ""; }
            var root = new Dictionary<string, object>(profile); root["secrets"] = secrets;
            return Parse(Json.Encode(root));
        }
        public static string Export(string home, string master)
        { using (var lease = new SecretVault.Lease(home)) return Pack(Snapshot(home), master); }
        static string Scrub(string text, IEnumerable<string> values)
        { foreach (string value in values) text = text.Replace(value, Hidden); return text; }
        static object PublicValue(object value, string[] secrets)
        {
            var map = value as Dictionary<string, object>;
            if (map != null) return map.ToDictionary(x => x.Key, x => PublicValue(x.Value, secrets));
            if (value is string) return Scrub((string)value, secrets);
            if (value is System.Collections.IEnumerable) return Json.Array(value).Select(x => PublicValue(x, secrets)).ToArray();
            return value;
        }
        public static string ExportForAi(string home)
        {
            using (var lease = new SecretVault.Lease(home)) {
                var p = Snapshot(home); var values = p.Secrets.Values.Where(v => v.Length > 0).Distinct().OrderByDescending(v => v.Length).ToArray();
                var root = (Dictionary<string, object>)PublicValue(p.Profile, values);
                root["secrets"] = p.Secrets.ToDictionary(x => x.Key, x => x.Value.Length > 0 ? Hidden : "");
                return Json.Encode(root) + "\n";
            }
        }

        public static ParsedConfig Unlock(ParsedConfig p, string master)
        {
            if (p == null) throw Bad("Нет конфига");
            if (!p.Locked) return p;
            byte[] keys = null;
            try {
                var kdf = Json.Map(Json.Get(p.Protection, "kdf"));
                keys = Derive(master, Base64(Json.Str(kdf, "salt")), Json.Int(kdf, "iterations", 0));
                if (Decrypt(Json.Str(p.Protection, "check"), keys) != "remoteagents") throw new CryptographicException();
                var secrets = new Dictionary<string, object>(StringComparer.Ordinal);
                // Authenticate every value before returning any plaintext or writing anything.
                foreach (var pair in p.Secrets) secrets[pair.Key] = pair.Value.Length == 0 ? "" : Decrypt(pair.Value, keys);
                var root = new Dictionary<string, object>(p.Profile); root["secrets"] = secrets;
                return Parse(Json.Encode(root));
            } catch { throw Bad("Неверный мастер-пароль"); }
            finally { if (keys != null) Array.Clear(keys, 0, keys.Length); }
        }
        internal static string Pack(ParsedConfig p, string master)
        {
            if (p.Locked) throw Bad("Сначала введите мастер-пароль");
            var root = new Dictionary<string, object>(p.Profile);
            var secrets = new Dictionary<string, object>(StringComparer.Ordinal);
            byte[] keys = null;
            try {
                if (master != null) {
                    if (master.Length == 0) throw Bad("Мастер-пароль не должен быть пустым");
                    byte[] salt = Random(32);
                    keys = Derive(master, salt, 200000);
                    secrets["protected"] = "master-password";
                    secrets["kdf"] = D("name", "pbkdf2-sha256", "iterations", 200000, "salt", Convert.ToBase64String(salt));
                    secrets["check"] = Encrypt("remoteagents", keys);
                }
                foreach (var pair in p.Secrets) secrets[pair.Key] = keys == null || pair.Value.Length == 0 ? pair.Value : Encrypt(pair.Value, keys);
                root["secrets"] = secrets;
                string encoded = Json.Encode(root) + "\n";
                if (encoded.Length > MaxLength || Files.Utf8.GetByteCount(encoded) > MaxLength) throw Bad("Полный конфиг превышает 4 МиБ");
                return encoded;
            } finally { if (keys != null) Array.Clear(keys, 0, keys.Length); }
        }
        static byte[] Random(int count)
        { var bytes = new byte[count]; using (var rng = RandomNumberGenerator.Create()) rng.GetBytes(bytes); return bytes; }
        // The static Pbkdf2 API is absent from the shipped .NET Framework 4.8.
#pragma warning disable SYSLIB0060
        static byte[] Derive(string master, byte[] salt, int iterations)
        {
            if (master == null || iterations < 200000 || iterations > 2000000 || salt.Length < 16 || salt.Length > 64) throw new CryptographicException();
            using (var kdf = new Rfc2898DeriveBytes(master, salt, iterations, HashAlgorithmName.SHA256)) return kdf.GetBytes(64);
        }
#pragma warning restore SYSLIB0060
        static byte[] Part(byte[] bytes, int offset, int count)
        { var p = new byte[count]; Buffer.BlockCopy(bytes, offset, p, 0, count); return p; }
        static string Encrypt(string text, byte[] keys)
        {
            byte[] plain = new UTF8Encoding(false, true).GetBytes(text);
            try {
                using (var aes = Aes.Create()) {
                    aes.Key = Part(keys, 0, 32); aes.IV = Random(16); aes.Mode = CipherMode.CBC; aes.Padding = PaddingMode.PKCS7;
                    byte[] cipher; using (var encrypt = aes.CreateEncryptor()) cipher = encrypt.TransformFinalBlock(plain, 0, plain.Length);
                    var payload = new byte[16 + cipher.Length + 32];
                    Buffer.BlockCopy(aes.IV, 0, payload, 0, 16); Buffer.BlockCopy(cipher, 0, payload, 16, cipher.Length);
                    using (var mac = new HMACSHA256(Part(keys, 32, 32))) Buffer.BlockCopy(mac.ComputeHash(payload, 0, payload.Length - 32), 0, payload, payload.Length - 32, 32);
                    return "enc1:" + Convert.ToBase64String(payload);
                }
            } finally { Array.Clear(plain, 0, plain.Length); }
        }
        static string Decrypt(string value, byte[] keys)
        {
            byte[] payload = CheckEnvelope(value);
            // Encrypt-then-MAC: never attempt CBC decryption of unauthenticated data.
            using (var mac = new HMACSHA256(Part(keys, 32, 32))) {
                byte[] expected = mac.ComputeHash(payload, 0, payload.Length - 32); int difference = 0;
                for (int i = 0; i < 32; i++) difference |= expected[i] ^ payload[payload.Length - 32 + i];
                if (difference != 0) throw new CryptographicException();
            }
            using (var aes = Aes.Create()) {
                aes.Key = Part(keys, 0, 32); aes.IV = Part(payload, 0, 16); aes.Mode = CipherMode.CBC; aes.Padding = PaddingMode.PKCS7;
                byte[] plain; using (var decrypt = aes.CreateDecryptor()) plain = decrypt.TransformFinalBlock(payload, 16, payload.Length - 48);
                try { return new UTF8Encoding(false, true).GetString(plain); }
                finally { Array.Clear(plain, 0, plain.Length); }
            }
        }

        // Framework JSON parsing accepts duplicate properties and some non-JSON syntax.
        // This guard enforces strict syntax before using the existing serializer on both runtimes.
        static class StrictJson
        {
            sealed class Reader
            {
                readonly string s; int i;
                static readonly Regex Token = new Regex("\\G(?:true|false|null|-?(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)");
                internal Reader(string text) { s = text.TrimStart('\uFEFF'); }
                void White() { while (i < s.Length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n')) i++; }
                void Need(char c) { White(); if (i == s.Length || s[i++] != c) throw new FormatException(); }
                string String()
                {
                    White(); int start = i; Need('"');
                    while (i < s.Length) {
                        char c = s[i++];
                        if (c == '"') return (string)Json.Parse(s.Substring(start, i - start));
                        if (c < 32) throw new FormatException();
                        if (c == '\\') {
                            if (i == s.Length) throw new FormatException();
                            char escape = s[i++];
                            if (escape == 'u') { for (int k = 0; k < 4; k++) if (i == s.Length || !Uri.IsHexDigit(s[i++])) throw new FormatException(); }
                            else if ("\"\\/bfnrt".IndexOf(escape) < 0) throw new FormatException();
                        }
                    }
                    throw new FormatException();
                }
                void Value(int depth)
                {
                    White(); if (depth > 64 || i == s.Length) throw new FormatException();
                    char c = s[i];
                    if (c == '{') {
                        i++; White(); if (i < s.Length && s[i] == '}') { i++; return; }
                        var keys = new HashSet<string>(StringComparer.Ordinal);
                        while (true) {
                            string key = String(); if (!keys.Add(key) || keys.Count > 512) throw new FormatException();
                            Need(':'); Value(depth + 1); White();
                            if (i < s.Length && s[i] == '}') { i++; return; }
                            Need(',');
                        }
                    } else if (c == '[') {
                        i++; White(); if (i < s.Length && s[i] == ']') { i++; return; }
                        int count = 0;
                        while (true) { if (++count > 512) throw new FormatException(); Value(depth + 1); White(); if (i < s.Length && s[i] == ']') { i++; return; } Need(','); }
                    } else if (c == '"') String();
                    else {
                        var m = Token.Match(s, i);
                        if (!m.Success || m.Index != i) throw new FormatException(); i += m.Length;
                    }
                }
                internal void Check() { Value(0); White(); if (i != s.Length) throw new FormatException(); }
            }
            internal static void Check(string text) { new Reader(text).Check(); }
        }
    }
}
