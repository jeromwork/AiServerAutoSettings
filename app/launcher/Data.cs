using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
#if !PORTABLE_TEST
using System.Web.Script.Serialization;
#endif

namespace RemoteAgents.Launcher
{
    internal static class Product
    {
#if REMOTE_VPN
        public static bool IsVpn { get { return true; } }
#else
        public static bool IsVpn { get { return false; } }
#endif
        public static string Name { get { return IsVpn ? "RemoteVPN" : "RemoteAgents"; } }
        public static string ExeName { get { return Name + ".exe"; } }
        public static string BundleDirectory { get { return IsVpn ? "vpn-bundle" : "bundle"; } }
        public static string StatusName { get { return IsVpn ? "vpn-launcher.json" : "launcher.json"; } }
    }
    // Framework serializer keeps the distributable a single EXE, without JSON packages.
#if !PORTABLE_TEST
    internal static class Json
    {
        public static object Parse(string text) { return new JavaScriptSerializer { MaxJsonLength = 4 * 1024 * 1024 }.DeserializeObject(text.TrimStart('\uFEFF')); }
        public static Dictionary<string, object> Map(object value) { return value as Dictionary<string, object> ?? new Dictionary<string, object>(); }
        public static Dictionary<string, object> Read(string path) { return Map(Parse(File.ReadAllText(path))); }
        public static object Get(Dictionary<string, object> map, string key) { object value; return map.TryGetValue(key, out value) ? value : null; }
        public static string Str(Dictionary<string, object> map, string key, string fallback = "") { return Convert.ToString(Get(map, key), CultureInfo.InvariantCulture) ?? fallback; }
        public static string Text(Dictionary<string, object> map, string key, string fallback) { var s = Str(map, key); return s.Length == 0 ? fallback : s; }
        public static bool Bool(Dictionary<string, object> map, string key, bool fallback = false) { var v = Get(map, key); return v is bool ? (bool)v : fallback; }
        public static int Int(Dictionary<string, object> map, string key, int fallback) { int n; return int.TryParse(Str(map, key), out n) ? n : fallback; }
        public static object[] Array(object value) { return value is IEnumerable && !(value is string) && !(value is IDictionary) ? ((IEnumerable)value).Cast<object>().ToArray() : new object[0]; }
        public static string[] Strings(object value) { return Array(value).Select(x => Convert.ToString(x, CultureInfo.InvariantCulture)).ToArray(); }
        public static string Encode(object value) { return new JavaScriptSerializer { MaxJsonLength = 4 * 1024 * 1024 }.Serialize(value); }
        public static void Write(string path, object value) { Files.Atomic(path, Encode(value) + "\n"); }
    }
#endif
    internal static class Files
    {
        public static string Executable(string exe)
        {
            return string.Equals(exe, "powershell.exe", StringComparison.OrdinalIgnoreCase)
                ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe") : exe;
        }
        public static readonly UTF8Encoding Utf8 = new UTF8Encoding(false);
        public static string LF(string value) { return value.Replace("\r\n", "\n").Replace("\r", "\n"); }
        public static void Atomic(string path, string text)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path)));
            string temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try {
                using (var f = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None)) {
                    byte[] bytes = Utf8.GetBytes(text); f.Write(bytes, 0, bytes.Length); f.Flush(true);
                }
                if (File.Exists(path)) File.Replace(temp, path, null); else File.Move(temp, path);
            } finally { if (File.Exists(temp)) File.Delete(temp); }
        }
        public static string ReadLine(string path) { return File.Exists(path) ? LF(File.ReadAllText(path)).Trim('\uFEFF', ' ', '\n', '\t') : ""; }
        public static string Hash(string file) { using (var sha = SHA256.Create()) using (var f = File.OpenRead(file)) return BitConverter.ToString(sha.ComputeHash(f)).Replace("-", "").ToLowerInvariant(); }
        public static void HashValid(string hash) { if (!Regex.IsMatch(hash ?? "", "^[a-fA-F0-9]{64}$")) throw new InvalidDataException("Неверный SHA256"); }
        public static string SafeVersion(string version)
        {
            if (!Regex.IsMatch(version ?? "", "^[0-9][A-Za-z0-9._-]{0,79}$") || version.EndsWith(".") || version.Contains("..")) throw new InvalidDataException("Неверная версия");
            return version;
        }
        public static string Under(string root, string relative)
        {
            if (string.IsNullOrWhiteSpace(relative) || Path.IsPathRooted(relative) || relative.Contains(":")) throw new InvalidDataException("Недопустимый путь");
            root = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
            string normalized = relative.Replace('\\', Path.DirectorySeparatorChar).Replace('/', Path.DirectorySeparatorChar);
            string result = Path.GetFullPath(Path.Combine(root, normalized));
            if (!result.StartsWith(root, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Выход за каталог");
            return result;
        }
        // Numeric tokens allow both semver and UTC-date + git-hash bundle versions.
        public static int Compare(string a, string b)
        {
            var aa = Regex.Matches(a ?? "", "[0-9]+|[A-Za-z]+").Cast<Match>().Select(m => m.Value).ToArray();
            var bb = Regex.Matches(b ?? "", "[0-9]+|[A-Za-z]+").Cast<Match>().Select(m => m.Value).ToArray();
            for (int i = 0; i < Math.Max(aa.Length, bb.Length); i++) {
                string x = i < aa.Length ? aa[i] : "0", y = i < bb.Length ? bb[i] : "0";
                bool xn = x.All(char.IsDigit), yn = y.All(char.IsDigit); int c;
                if (xn && yn) { x = x.TrimStart('0'); y = y.TrimStart('0'); c = x.Length.CompareTo(y.Length); if (c == 0) c = string.CompareOrdinal(x, y); }
                else c = string.Compare(x, y, StringComparison.OrdinalIgnoreCase);
                if (c != 0) return c;
            }
            return 0;
        }
        public static string Quote(string s) { return "\"" + Regex.Replace(Regex.Replace(s, "(\\\\*)\"", "$1$1\\\""), "(\\\\+)$", "$1$1") + "\""; }
        public static string Arguments(IEnumerable<string> args) { return string.Join(" ", args.Select(Quote)); }
    }
    internal sealed class Journal
    {
        readonly string file; readonly object gate = new object();
        public Journal(string home) { Directory.CreateDirectory(Path.Combine(home, "logs")); file = Path.Combine(home, "logs", Product.IsVpn ? "vpn-launcher.log" : "launcher.log"); }
        // Event codes and validated component identifiers only; no exception messages, SSH arguments, status text or URLs.
        public void Write(string code)
        {
            lock (gate) {
                try {
                    var line = DateTime.UtcNow.ToString("o") + " " + code + "\n";
                    if (File.Exists(file) && new FileInfo(file).Length + Files.Utf8.GetByteCount(line) > 1048576) { if (File.Exists(file + ".old")) File.Delete(file + ".old"); File.Move(file, file + ".old"); }
                    File.AppendAllText(file, line, Files.Utf8);
                } catch { /* Disk failure must not stop supervision. */ }
            }
        }
    }
    internal sealed class Configuration
    {
        public readonly string PathName; public readonly Dictionary<string, object> Data;
        public Configuration(string home)
        {
            PathName = Path.Combine(home, "config.json");
            using (var lease = Lock(PathName)) {
            Data = File.Exists(PathName) ? Json.Read(PathName) : new Dictionary<string, object>();
            bool changed = false;
            if (!Data.ContainsKey("schema")) { Data["schema"] = 1; changed = true; }
            if (!Data.ContainsKey("version")) { Data["version"] = 1; changed = true; }
            if (!Data.ContainsKey("components")) { Data["components"] = new Dictionary<string, object>(); changed = true; }
            if (!Data.ContainsKey("update")) { Data["update"] = new Dictionary<string, object> { { "enabled", false }, { "remoteDir", "~/.local/share/remote-agents/dist" } }; changed = true; }
            if (Json.Int(Data, "schema", 0) != 1) throw new InvalidDataException("Неизвестная схема настроек");
            if (changed) Save();
            }
        }
        Configuration(Dictionary<string, object> data) { Data = data; }
        public static Configuration ForUpdate(string json) { return new Configuration(new Dictionary<string, object> { { "update", Json.Parse(json) } }); }
        public Dictionary<string, object> Update { get { return Json.Map(Json.Get(Data, "update")); } }
        public bool Enabled(Component c) { var map = Json.Map(Json.Get(Data, "components")); return Json.Bool(Json.Map(Json.Get(map, c.Name)), "enabled", c.Default); }
        // Required fields are the component's setup contract, independent of enabled intent.
        public bool Wanted(Component c)
        { return Enabled(c) && Ready(Data,c.RequiredConfig); }
        internal static bool Ready(Dictionary<string,object> data, string[] fields)
        {
            return fields.All(path=> {
                object value=data;foreach(string part in path.Split('.'))value=Json.Get(Json.Map(value),part);
                return value is bool ? (bool)value : value is string && !string.IsNullOrWhiteSpace((string)value);
            });
        }
        public void SetEnabled(Component c, bool enabled)
        {
            // Same per-home mutex as Edit-Transport/Set-VpnEnabled; refresh first so a tray toggle
            // cannot overwrite nodes just edited in Notepad or by the transport module.
            using (var lease = Lock(PathName)) {
                    if (File.Exists(PathName)) { var latest = Json.Read(PathName); Data.Clear(); foreach (var pair in latest) Data[pair.Key] = pair.Value; }
                    var map = Json.Map(Json.Get(Data, "components")); var item = Json.Map(Json.Get(map, c.Name)); item["enabled"] = enabled; map[c.Name] = item; Data["components"] = map; Save();
            }
        }
        public void SetInviteVpnIntent(bool enabled)
        {
            using(var lease=Lock(PathName)) {
                var latest=File.Exists(PathName)?Json.Read(PathName):Data;
                var wizard=Json.Map(Json.Get(latest,"wizard"));
                if(Json.Bool(wizard,"inviteVpn")){wizard["inviteVpnWanted"]=enabled;latest["wizard"]=wizard;Json.Write(PathName,latest);}
            }
        }
        public void SetHappier(string serverUrl, string webappUrl)
        {
            using(var lease=Lock(PathName)) {
                var latest=File.Exists(PathName)?Json.Read(PathName):Data;
                latest["happier"]=new {serverUrl,webappUrl};Json.Write(PathName,latest);
            }
        }
        sealed class Lease : IDisposable {
            readonly System.Threading.Mutex mutex;
            public Lease(string path) {
                string fingerprint;
                using (var sha = SHA256.Create()) fingerprint = BitConverter.ToString(sha.ComputeHash(Files.Utf8.GetBytes("CONFIG\n" + System.IO.Path.GetDirectoryName(path).ToLowerInvariant()))).Replace("-", "").ToLowerInvariant();
                mutex = new System.Threading.Mutex(false, "Global\\RemoteAgentsConfig-" + fingerprint);
                bool owned; try { owned = mutex.WaitOne(5000); } catch (System.Threading.AbandonedMutexException) { owned = true; }
                if (!owned) { mutex.Dispose(); throw new IOException("Конфиг занят"); }
            }
            public void Dispose() { mutex.ReleaseMutex(); mutex.Dispose(); }
        }
        static IDisposable Lock(string path) { return new Lease(path); }
        public void Save() { Json.Write(PathName, Data); }
    }
    internal sealed class MenuAction
    {
        public string Title, Exe; public string[] Args;
        public static MenuAction Read(object value) { var d = Json.Map(value); return new MenuAction { Title = Json.Str(d, "title"), Exe = Json.Str(d, "exe"), Args = Json.Strings(Json.Get(d, "args")) }; }
    }
    internal sealed class Component
    {
        public string Name, Title, Exe, Cwd, Restart, HealthFile, StopFile; public string[] Args, RequiredConfig; public bool Default, Critical, Elevated, CommandManaged; public int MaxAge; public MenuAction[] Menu;
        public static Component Read(object value)
        {
            var d = Json.Map(value); var c = new Component {
                Name = Json.Str(d, "name"), Title = Json.Str(d, "title"), Exe = Json.Str(d, "exe"), Args = Json.Strings(Json.Get(d, "args")),
                Cwd = Json.Text(d, "cwd", "{bundle}"), Restart = Json.Text(d, "restart", "never"), HealthFile = Json.Str(d, "healthFile"),
                MaxAge = Json.Int(d, "healthMaxAgeSec", 90), Default = Json.Bool(d, "enabledByDefault"), Critical = Json.Bool(d, "critical"), Elevated = Json.Bool(d, "elevated"), CommandManaged = Json.Bool(d, "commandManaged"), StopFile = Json.Str(d, "stopFile"),
                RequiredConfig = Json.Strings(Json.Get(d, "requiresConfig")),
                Menu = Json.Array(Json.Get(d, "menu")).Select(MenuAction.Read).ToArray()
            };
            if (!Regex.IsMatch(c.Name, "^[a-z][a-z0-9_-]{0,63}$") || string.IsNullOrWhiteSpace(c.Exe) || (c.Restart != "always" && c.Restart != "never") || c.MaxAge < 1) throw new InvalidDataException("Неверный компонент");
            if (string.IsNullOrEmpty(c.HealthFile)) c.HealthFile = "status/" + c.Name + ".json";
            return c;
        }
    }
    internal sealed class BundleDefinition
    {
        public Component[] Components; public MenuAction[] Menu; public Dictionary<string, object>[] Binaries;
        public static BundleDefinition Load(string folder)
        {
            var raw = Json.Parse(File.ReadAllText(Path.Combine(folder, "components.json"))); var map = Json.Map(raw);
            var result = new BundleDefinition {
                Components = Json.Array(raw is IDictionary ? Json.Get(map, "components") : raw).Select(Component.Read).ToArray(),
                Menu = Json.Array(Json.Get(map, "menu")).Select(MenuAction.Read).ToArray(),
                Binaries = Json.Array(Json.Get(map, "binaries")).Select(Json.Map).ToArray()
            };
            if (result.Components.Length == 0 || result.Components.Select(c => c.Name).Distinct(StringComparer.OrdinalIgnoreCase).Count() != result.Components.Length) throw new InvalidDataException("Список компонентов пуст или повторяется");
            return result;
        }
    }
}
