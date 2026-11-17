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
        internal static string Reply(string line, Func<string[]> recentLog)
        {
            string command;
            if (!TryCommand(line, out command)) return BadRequest;
            if (command == "ping") return "{\"ok\":true,\"reply\":\"pong\"}";
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
