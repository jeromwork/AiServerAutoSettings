// Only the Linux harness uses System.Text.Json. The shipped net48 EXE uses JavaScriptSerializer.
using System;
using System.Collections.Generic;
using System.Collections;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.Json;
namespace RemoteAgents.Launcher
{
    internal static class Json
    {
        public static object Parse(string s) { using (var doc = JsonDocument.Parse(s.TrimStart('\uFEFF'))) return ConvertElement(doc.RootElement); }
        static object ConvertElement(JsonElement e) { switch (e.ValueKind) {
            case JsonValueKind.Object: return e.EnumerateObject().ToDictionary(p => p.Name, p => ConvertElement(p.Value));
            case JsonValueKind.Array: return e.EnumerateArray().Select(ConvertElement).ToArray();
            case JsonValueKind.String: return e.GetString(); case JsonValueKind.True: return true; case JsonValueKind.False: return false;
            case JsonValueKind.Number: return e.GetDecimal(); default: return null;
        } }
        public static Dictionary<string, object> Map(object value) { return value as Dictionary<string, object> ?? new Dictionary<string, object>(); }
        public static Dictionary<string, object> Read(string path) { return Map(Parse(File.ReadAllText(path))); }
        public static object Get(Dictionary<string, object> map, string key) { object v; return map.TryGetValue(key, out v) ? v : null; }
        public static string Str(Dictionary<string, object> map, string key, string fallback = "") { return Convert.ToString(Get(map, key), CultureInfo.InvariantCulture) ?? fallback; }
        public static string Text(Dictionary<string, object> map, string key, string fallback) { var s = Str(map, key); return s.Length == 0 ? fallback : s; }
        public static bool Bool(Dictionary<string, object> map, string key, bool fallback = false) { var v = Get(map, key); return v is bool ? (bool)v : fallback; }
        public static int Int(Dictionary<string, object> map, string key, int fallback) { int n; return int.TryParse(Str(map, key), out n) ? n : fallback; }
        public static object[] Array(object value) { return value is IEnumerable && !(value is string) && !(value is IDictionary) ? ((IEnumerable)value).Cast<object>().ToArray() : new object[0]; }
        public static string[] Strings(object value) { return Array(value).Select(x => Convert.ToString(x, CultureInfo.InvariantCulture)).ToArray(); }
        public static string Encode(object value) { return JsonSerializer.Serialize(value); }
        public static void Write(string path, object value) { Files.Atomic(path, Encode(value) + "\n"); }
    }
    internal static class TestEntry
    {
        static int Main(string[] args) { if(args.Length>0 && args[0]=="--proxy-connect")return ProxyRelay.Run(args); InvitationTests.Run(); DiskTreeTests.Run(); ProxyRelayTests.Run(); int code = UpdateSelfTests.Run(args[0]); Console.WriteLine(File.ReadAllText(Path.Combine(args[0], "selftest-result.json"))); return code; }
    }
}
