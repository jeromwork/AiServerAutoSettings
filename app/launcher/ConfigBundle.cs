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
            if (pattern != null) d["pattern"] = pattern;
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
        static Dictionary<string, object> Named(object item)
        { return D("type", "object", "propertyNames", S(64, 1, NamePattern), "additionalProperties", item, "maxProperties", 256); }
        static Dictionary<string, object> Ref()
        { return O(D("secret", S(64, 1, NamePattern)), "secret"); }
        static Dictionary<string, object> Host() { return S(253, 1, "^[a-zA-Z0-9][a-zA-Z0-9.:-]{0,252}$"); }
        static Dictionary<string, object> User() { return S(32, 1, "^[a-z_][a-z0-9_-]{0,31}$"); }
        static Dictionary<string, object> Url()
        { var d = S(2048, 1); d["format"] = "https-url"; return d; }
        static Dictionary<string, object> Proxy()
        { return O(D("type", E("socks", "http"), "server", Host(), "port", N(1, 65535), "login", S(256), "password", Ref(), "checkUrl", Url()), "type", "server", "port"); }
        static Dictionary<string, object> Hop()
        { return O(D("host", Host(), "port", N(1, 65535), "user", User(), "hostKey", S(4096, 1, "^[^\\r\\n\\x00]+$"), "key", Ref(), "password", Ref()), "host", "user"); }
        internal static Dictionary<string, object> SchemaDocument()
        {
            var route = O(D("kind", E("direct", "proxy", "hop"), "proxy", Proxy(), "hop", Hop()), "kind");
            route["allOf"] = new object[] {
                D("if", D("properties", D("kind", D("const", "proxy"))), "then", D("required", new[]{"proxy"})),
                D("if", D("properties", D("kind", D("const", "hop"))), "then", D("required", new[]{"hop"}))
            };
            var bootstrap = O(D("channel", Ref(), "entries", Named(Ref()), "hops", Named(Hop())));
            var component = O(D("enabled", B()));
            var props = D(
                "kind", D("const", "remoteagents-config"), "schema", D("const", 1),
                "device", O(D("name", S(80, 1, "^[^\\r\\n\\x00]+$"))),
                "server", O(D("address", Host(), "port", N(1, 65535), "login", User(),
                    "hostKeys", A(S(4096, 1, "^[^\\r\\n\\x00]+$"), 32), "key", Ref(), "rootPassword", Ref(), "routes", A(route, 32))),
                "connection", O(D("enabled", B())),
                "bridge", O(D("enabled", B(), "allowShell", B())),
                "happier", O(D("mode", E("same", "new"), "label", S(80, 1), "serverUrl", Url(), "webappUrl", Url(), "key", Ref())),
                "disk", O(D("base", S(1024, 1, "^[^\\r\\n\\x00]+$"), "folders", A(S(255, 1, "^[^/\\\\<>:\"|?*\\x00-\\x1f]+$")))),
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
            if (text == null || text.Length > MaxLength) throw Bad("Конфиг пуст или превышает 4 МиБ");
            Dictionary<string, object> root;
            try {
                StrictJson.Check(text);
                root = Json.Parse(text) as Dictionary<string, object>;
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
                if (!p.Locked && value.StartsWith("enc1:", StringComparison.Ordinal)) throw Bad("Для enc1 нужен secrets.protected");
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
        internal static InvalidDataException Bad(string message) { return new InvalidDataException(message); }
        internal static void ValidName(string name)
        {
            if (name == null || !Regex.IsMatch(name, NamePattern) || name.Any(c => c > 127 && !char.IsLetter(c)) || new[]{"protected", "kdf", "check", "hint"}.Contains(name)) throw Bad("Недопустимое имя секрета");
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
                if (schema.ContainsKey("pattern") && !Regex.IsMatch(s, (string)schema["pattern"])) throw Bad("Недопустимые символы: " + path);
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
            foreach (string f in Json.Strings(Json.Get(Json.Map(Json.Get(profile, "disk")), "folders"))) {
                if (f == "." || f == ".." || f.EndsWith(".") || f.EndsWith(" ") || Regex.IsMatch(f, "^(?i:con|prn|aux|nul|com[0-9]|lpt[0-9])(?:\\.|$)")) throw Bad("Недопустимое имя папки Disk");
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
            foreach (var r in References(p.Profile)) {
                string name = Json.Str(r, "secret"), hint = Json.Str(r, "hint");
                p.Hints[name] = hint.Length > 0 ? hint : StandardHint(name);
            }
            p.Missing = p.Hints.Keys.Where(n => !p.Secrets.ContainsKey(n) || p.Secrets[n].Length == 0).OrderBy(n => n, StringComparer.Ordinal).ToArray();
        }
        internal static string StandardHint(string name)
        {
            switch (name) {
                case "server-root-password": return "Пароль root сервера — его присылает хостинг при покупке сервера";
                case "server-key": return "Закрытый SSH-ключ доступа к серверу";
                case "happier-key": return "Секретный ключ аккаунта Happier из его настроек";
                case "hop-key": return "Закрытый SSH-ключ промежуточного сервера";
                case "hop-password": return "Пароль SSH промежуточного сервера";
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

        // Framework JSON parsing accepts duplicate properties and some non-JSON syntax.
        // This guard enforces strict syntax before using the existing serializer on both runtimes.
        static class StrictJson
        {
            sealed class Reader
            {
                readonly string s; int i;
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
                            string key = String(); if (!keys.Add(key)) throw new FormatException();
                            Need(':'); Value(depth + 1); White();
                            if (i < s.Length && s[i] == '}') { i++; return; }
                            Need(',');
                        }
                    } else if (c == '[') {
                        i++; White(); if (i < s.Length && s[i] == ']') { i++; return; }
                        while (true) { Value(depth + 1); White(); if (i < s.Length && s[i] == ']') { i++; return; } Need(','); }
                    } else if (c == '"') String();
                    else {
                        var m = Regex.Match(s.Substring(i), "\\A(?:true|false|null|-?(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)");
                        if (!m.Success) throw new FormatException(); i += m.Length;
                    }
                }
                internal void Check() { Value(0); White(); if (i != s.Length) throw new FormatException(); }
            }
            internal static void Check(string text) { new Reader(text).Check(); }
        }
    }
}
