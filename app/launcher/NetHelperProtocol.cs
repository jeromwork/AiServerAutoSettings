using System;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace RemoteAgents.Launcher
{
    internal static class NetHelperProtocol
    {
        internal const int MaxMessageBytes = 64 * 1024;
        internal const string PipeName = "RemoteAgentsNet";
        internal const string BadRequest = "{\"ok\":false,\"error\":\"bad-request\"}";
        internal static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, true);

        // Validate the grammar and decoded property names before the Framework decoder,
        // which otherwise accepts duplicate keys. No paths, scripts or arbitrary config cross the pipe.
        internal static bool TryRequest(string line, out string command, out System.Collections.Generic.Dictionary<string, object> map)
        {
            command = null; map = null;
            try {
                if (line == null || Utf8.GetByteCount(line) > MaxMessageBytes) return false;
                new Grammar(line).Validate();
                map = Json.Map(Json.Parse(line));
                if (!(Json.Get(map, "cmd") is string)) return false;
                string value = Json.Str(map, "cmd");
                switch (value) {
                    case "status": case "ping": case "lan.apply": case "lan.stop": case "vpn.on": case "vpn.off": break;
                    default: return false;
                }
                if (value == "vpn.on") {
                    foreach (var key in map.Keys)
                        if (key != "cmd" && key != "socksPort" && key != "excludeCidrs" && key != "address" && key != "dnsServer" && key != "checkUrl" && key != "probeAddress") return false;
                    if (map.Count > 1) VpnTun.Read(map);
                } else if (map.Count != 1) return false;
                command = value; return true;
            } catch { map = null; return false; }
        }
        internal static bool TryCommand(string line, out string command)
        { System.Collections.Generic.Dictionary<string, object> map; return TryRequest(line, out command, out map); }
        sealed class Grammar
        {
            readonly string text; int position;
            static readonly Regex Token = new Regex(@"\G(?:""(?:[^""\\\x00-\x1f]|\\(?:[""\\/bfnrt]|u[0-9a-fA-F]{4}))*""|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|true|false|null)", RegexOptions.CultureInvariant);
            internal Grammar(string text) { this.text = text; }
            void Space() { while (position < text.Length && " \t\r\n".IndexOf(text[position]) >= 0) position++; }
            bool Eat(char c) { Space(); if (position < text.Length && text[position] == c) { position++; return true; } return false; }
            void Need(char c) { if (!Eat(c)) throw new InvalidDataException(); }
            string Scalar(bool key = false)
            {
                Space(); var m = Token.Match(text, position);
                if (!m.Success || m.Index != position || key && text[position] != '"') throw new InvalidDataException();
                position += m.Length; return m.Value;
            }
            void Value(int depth)
            {
                if (depth > 8) throw new InvalidDataException();
                if (Eat('{')) {
                    var keys = new System.Collections.Generic.HashSet<string>(StringComparer.Ordinal);
                    if (Eat('}')) return;
                    do { if (!keys.Add((string)Json.Parse(Scalar(true)))) throw new InvalidDataException(); Need(':'); Value(depth + 1); } while (Eat(','));
                    Need('}');
                } else if (Eat('[')) {
                    if (Eat(']')) return;
                    do { Value(depth + 1); } while (Eat(',')); Need(']');
                } else Scalar();
            }
            internal void Validate() { Space(); if (position >= text.Length || text[position] != '{') throw new InvalidDataException(); Value(0); Space(); if (position != text.Length) throw new InvalidDataException(); }
        }
        internal static string Reply(string line, Func<string[]> recentLog, Func<string, System.Collections.Generic.Dictionary<string, object>, string> execute = null)
        {
            string command; System.Collections.Generic.Dictionary<string, object> map;
            if (!TryRequest(line, out command, out map)) return BadRequest;
            if (command == "ping") return "{\"ok\":true,\"reply\":\"pong\"}";
            if (execute != null) return execute(command, map);
            if (command == "status") return Json.Encode(new { ok = true, state = "ready", helperVersion = NetHelperInstall.HelperVersion, log = recentLog() });
            return "{\"ok\":false,\"error\":\"not-implemented\"}";
        }
        internal static Task WriteLine(Stream stream, string line)
        {
            if (Utf8.GetByteCount(line) > MaxMessageBytes) throw new InvalidDataException("helper frame too large");
            byte[] bytes = Utf8.GetBytes(line + "\n");
            return stream.WriteAsync(bytes, 0, bytes.Length);
        }
        internal sealed class Reader
        {
            readonly Stream stream;
            readonly byte[] buffer = new byte[4096];
            int position, available;
            internal Reader(Stream stream) { this.stream = stream; }
            internal async Task<string> ReadLine()
            {
                using (var frame = new MemoryStream()) {
                    while (true) {
                        if (position == available) {
                            available = await stream.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false); position = 0;
                            if (available == 0) {
                                if (frame.Length != 0) throw new InvalidDataException("incomplete helper frame");
                                return null;
                            }
                        }
                        byte next = buffer[position++];
                        if (next == 10) {
                            byte[] data = frame.ToArray(); int length = data.Length;
                            if (length > 0 && data[length - 1] == 13) length--;
                            if (length > MaxMessageBytes) throw new InvalidDataException("helper frame too large");
                            try { return Utf8.GetString(data, 0, length); }
                            catch (DecoderFallbackException) { throw new InvalidDataException("invalid helper UTF8"); }
                        }
                        // One extra CR is permitted solely for a CRLF terminator.
                        if (frame.Length >= MaxMessageBytes && !(frame.Length == MaxMessageBytes && next == 13)) throw new InvalidDataException("helper frame too large");
                        frame.WriteByte(next);
                    }
                }
            }
        }
    }
}
