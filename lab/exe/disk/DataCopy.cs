using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace RemoteAgents.Launcher
{
    internal static class Json
    {
        public static object Parse(string text) { return new JavaScriptSerializer { MaxJsonLength = 4 * 1024 * 1024 }.DeserializeObject(text.TrimStart('\uFEFF')); }
        public static Dictionary<string, object> Map(object value) { return value as Dictionary<string, object> ?? new Dictionary<string, object>(); }
        public static Dictionary<string, object> Read(string path) { return Map(Parse(Files.ReadSharedText(path))); }
        public static object Get(Dictionary<string, object> map, string key) { object value; return map != null && map.TryGetValue(key, out value) ? value : null; }
        public static string Str(Dictionary<string, object> map, string key, string fallback = "") { return Convert.ToString(Get(map, key), CultureInfo.InvariantCulture) ?? fallback; }
        public static string Text(Dictionary<string, object> map, string key, string fallback) { var s = Str(map, key); return s.Length == 0 ? fallback : s; }
        public static bool Bool(Dictionary<string, object> map, string key, bool fallback = false) { var v = Get(map, key); return v is bool ? (bool)v : fallback; }
        public static int Int(Dictionary<string, object> map, string key, int fallback) { int n; return int.TryParse(Str(map, key), out n) ? n : fallback; }
        public static object[] Array(object value) { return value is IEnumerable && !(value is string) && !(value is IDictionary) ? ((IEnumerable)value).Cast<object>().ToArray() : new object[0]; }
        public static string[] Strings(object value) { return Array(value).Select(x => Convert.ToString(x, CultureInfo.InvariantCulture)).ToArray(); }
        public static string Encode(object value) { return new JavaScriptSerializer { MaxJsonLength = 4 * 1024 * 1024 }.Serialize(value); }
        public static void Write(string path, object value) { Files.Atomic(path, Encode(value) + "\n"); }
    }
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
        public static string ReadSharedText(string path)
        {
            for (int attempt = 0; ; attempt++) {
                try {
                    string text;
                    using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                    using (var reader = new StreamReader(stream, Encoding.UTF8, true)) text = reader.ReadToEnd();
                    if (!string.IsNullOrWhiteSpace(text)) return text;
                    if (attempt >= 20) throw new InvalidDataException("Пустой JSON после повторного чтения");
                } catch (IOException ex) {
                    int code = ex.HResult & 0xffff;
                    if ((code != 32 && code != 33) || attempt >= 20) throw;
                }
                System.Threading.Thread.Sleep(50);
            }
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
}
