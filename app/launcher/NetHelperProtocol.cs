using System;
using System.IO;
using System.Collections.Generic;
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

        // This stage has exactly one string property. Matching the JSON grammar before
        // deserializing also rejects duplicate keys (JavaScriptSerializer accepts them).
        static readonly Regex Request = new Regex(@"\A[ \t\r\n]*\{[ \t\r\n]*""(?:[^""\\\x00-\x1f]|\\(?:[""\\/bfnrt]|u[0-9a-fA-F]{4}))*""[ \t\r\n]*:[ \t\r\n]*""(?:[^""\\\x00-\x1f]|\\(?:[""\\/bfnrt]|u[0-9a-fA-F]{4}))*""[ \t\r\n]*\}[ \t\r\n]*\z", RegexOptions.CultureInvariant);
        internal static bool TryCommand(string line, out string command)
        {
            command = null;
            try {
                if (line == null || Utf8.GetByteCount(line) > MaxMessageBytes || !Request.IsMatch(line)) return false;
                var map = Json.Map(Json.Parse(line));
                if (map.Count != 1 || !(Json.Get(map, "cmd") is string)) return false;
                string value = (string)map["cmd"];
                switch (value) {
                    case "status": case "ping": case "lan.apply": case "lan.stop": case "vpn.on": case "vpn.off": command = value; return true;
                    default: return false;
                }
            } catch (Exception) { return false; } // Both framework and portable JSON decoders fail closed.
        }
        internal static string Reply(string line, Func<string[]> recentLog, Func<Dictionary<string, object>, object> lanCommand = null, Func<object> lanStatus = null)
        {
            string command;
            Dictionary<string, object> request = null;
            if (!TryCommand(line, out command)) {
                try {
                    if (line == null || Utf8.GetByteCount(line) > MaxMessageBytes) return BadRequest;
                    new StrictJson(line).Check();
                    request = Json.Map(Json.Parse(line));
                    if (Json.Str(request, "cmd") != "lan.apply") return BadRequest;
                    LanTunNetwork.Parse(request); command = "lan.apply";
                } catch { return BadRequest; }
            }
            if (command == "ping") return "{\"ok\":true,\"reply\":\"pong\"}";
            if (command == "status") return Json.Encode(new { ok = true, state = "ready", helperVersion = NetHelperInstall.HelperVersion, log = recentLog(), lan = lanStatus == null ? null : lanStatus() });
            if (lanCommand != null && (command == "lan.apply" || command == "lan.stop")) {
                if (command == "lan.apply" && request == null) return BadRequest;
                return Json.Encode(lanCommand(request ?? new Dictionary<string, object> { { "cmd", command } }));
            }
            return "{\"ok\":false,\"error\":\"not-implemented\"}";
        }
        // Framework's JSON decoder accepts duplicate keys and non-JSON syntax. Validate the
        // wire grammar before decoding; keys are compared after unescaping, at every depth.
        sealed class StrictJson
        {
            readonly string text; int at;
            static readonly Regex Token = new Regex(@"\G(?:-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|true|false|null)");
            static readonly Regex StringToken = new Regex(@"\G""(?:[^""\\\x00-\x1f]|\\(?:[""\\/bfnrt]|u[0-9a-fA-F]{4}))*""");
            internal StrictJson(string text) { this.text = text; }
            void Space() { while (at < text.Length && " \t\r\n".IndexOf(text[at]) >= 0) at++; }
            bool Take(char c) { Space(); if (at < text.Length && text[at] == c) { at++; return true; } return false; }
            void Need(char c) { if (!Take(c)) throw new InvalidDataException(); }
            string String() { Space(); var m = StringToken.Match(text, at); if (!m.Success) throw new InvalidDataException(); at += m.Length; return (string)Json.Parse(m.Value); }
            void Value(int depth)
            {
                if (depth > 16) throw new InvalidDataException();
                Space(); if (at >= text.Length) throw new InvalidDataException();
                if (Take('{')) {
                    var keys = new HashSet<string>(StringComparer.Ordinal);
                    if (Take('}')) return;
                    do { if (!keys.Add(String())) throw new InvalidDataException(); Need(':'); Value(depth + 1); } while (Take(','));
                    Need('}');
                } else if (Take('[')) {
                    if (Take(']')) return;
                    do { Value(depth + 1); } while (Take(',')); Need(']');
                } else if (text[at] == '"') String();
                else { var m = Token.Match(text, at); if (!m.Success) throw new InvalidDataException(); at += m.Length; }
            }
            internal void Check() { Value(0); Space(); if (at != text.Length) throw new InvalidDataException(); }
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
