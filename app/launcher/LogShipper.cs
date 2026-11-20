using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

namespace RemoteAgents.Launcher
{
    internal sealed class SendResult
    {
        internal bool Ok;
        internal string Err = "", Stderr = "", Path = "";
        internal int Exit;
    }
    internal interface ILogSender { SendResult Send(byte[] gz, string batchId, string path, int timeoutMs); }

    // Отправка журналов на сервер пачками. Курсор двигается только после подтверждения «OK» (docs/LOGS.md).
    internal sealed class LogShipper
    {
        internal static readonly string[] Streams = { "launcher", "transport", "helper", "core", "config-window" };
        internal static readonly string[] Paths = { "channel", "direct" };
        internal const int MaxRawBytes = 512 * 1024, MaxBatchesPerCycle = 8, IntervalSec = 60;
        internal static readonly int[] Backoff = { 60, 120, 300 };

        sealed class Segment { internal string Stream, Fp; internal long From, To; internal int Lines, FpLen; internal byte[] Data; }
        sealed class Cursor { internal string Fp = ""; internal int FpLen; internal long Off; }

        readonly string logsDir, cursorFile, device, host, version;
        readonly ILogSender sender;
        readonly Action<LogLevel, string, string[]> log;
        readonly Func<DateTime> utcNow;
        readonly object gate = new object();
        int running, failures;
        DateTime nextAt = DateTime.MinValue;
        readonly HashSet<string> gaps = new HashSet<string>();
        bool kicked;

        internal LogShipper(string logsDir, string stateDir, ILogSender sender, Action<LogLevel, string, string[]> log, string device, string host, string version, Func<DateTime> utcNow = null)
        {
            this.logsDir = logsDir; cursorFile = Path.Combine(stateDir, "log-ship.json"); this.sender = sender; this.log = log;
            this.device = string.IsNullOrWhiteSpace(device) ? "unknown" : device; this.host = host; this.version = version; this.utcNow = utcNow ?? (() => DateTime.UtcNow);
            nextAt = this.utcNow().AddSeconds(15);
        }
        internal int FailureCount { get { return failures; } }
        internal DateTime NextAt { get { return nextAt; } }

        // ---- расписание ------------------------------------------------------------------
        internal void Kick() { lock (gate) { if (failures > 0) return; kicked = true; var soon = utcNow().AddSeconds(5); if (nextAt > soon) nextAt = soon; } }
        // Раз в секунду из Tick: дешёвое решение; сама отправка — в фоне.
        internal void Tick()
        {
            if (utcNow() < nextAt) return;
            if (Interlocked.CompareExchange(ref running, 1, 0) != 0) return;
            System.Threading.Tasks.Task.Run(() => { try { Cycle(false, DateTime.MaxValue); } catch (Exception e) { log(LogLevel.Warn, "ship.error", new[] { "err", e.GetType().Name }); } finally { Interlocked.Exchange(ref running, 0); } });
        }
        // При выходе: синхронно, не дольше timeout.
        internal void Flush(TimeSpan timeout)
        {
            var end = DateTime.UtcNow + timeout;
            while (Interlocked.CompareExchange(ref running, 1, 0) != 0) { if (DateTime.UtcNow >= end) return; Thread.Sleep(50); }
            // Даже задержка диска или ошибочный sender не держат UI дольше общего срока.
            var flush = System.Threading.Tasks.Task.Run(() => {
                try { Cycle(true, end); } catch { } finally { Interlocked.Exchange(ref running, 0); }
            });
            int left = Remaining(end);
            if (left > 0) flush.Wait(left);
        }
        internal static int DelaySeconds(int failures) { return failures <= 0 ? IntervalSec : Backoff[Math.Min(failures, Backoff.Length) - 1]; }

        // Один цикл: до 8 пачек. Возвращает число отправленных пачек (для тестов).
        internal int Cycle(bool flushing, DateTime? deadline = null)
        {
            var end = deadline ?? (flushing ? DateTime.UtcNow.AddSeconds(5) : DateTime.MaxValue);
            lock (gate) { kicked = false; }
            int sent = 0; long bytes = 0; var watch = System.Diagnostics.Stopwatch.StartNew(); string path = "";
            for (int n = 0; n < (flushing ? 2 : MaxBatchesPerCycle) && Remaining(end) > 0; n++) {
                var cursors = LoadCursors();
                var segments = Collect(cursors);
                if (segments.Count == 0) break;
                string batchId = Guid.NewGuid().ToString("N");
                byte[] gz = Pack(batchId, segments);
                SendResult result = null; var failed = new List<SendResult>();
                foreach (string p in Paths) {
                    int left = Remaining(end); if (left <= 0) break;
                    result = sender.Send(gz, batchId, p, Math.Min(20000, left)); result.Path = p;
                    if (result.Ok) break;
                    failed.Add(result);
                }
                if (result == null || !result.Ok) {
                    failures++; int delay = DelaySeconds(failures);
                    foreach (var f in failed) log(LogLevel.Warn, "ship.failed", new[] { "path", f.Path, "err", f.Err, "exit", f.Exit.ToString(CultureInfo.InvariantCulture), "stderr", Tail(f.Stderr), "next_in", delay.ToString(CultureInfo.InvariantCulture) });
                    lock (gate) { kicked = false; nextAt = utcNow().AddSeconds(delay); }
                    return sent;
                }
                Advance(cursors, segments);
                failures = 0; sent++; bytes += gz.Length; path = result.Path;
            }
            lock (gate) { nextAt = utcNow().AddSeconds(kicked ? 5 : IntervalSec); kicked = false; }
            if (sent > 0) {
                log(LogLevel.Debug, "ship.ok", new[] { "path", path, "batches", sent.ToString(CultureInfo.InvariantCulture), "bytes", bytes.ToString(CultureInfo.InvariantCulture), "ms", watch.ElapsedMilliseconds.ToString(CultureInfo.InvariantCulture) });
            }
            return sent;
        }
        static int Remaining(DateTime end)
        { return (int)Math.Max(0, Math.Min(int.MaxValue, (end - DateTime.UtcNow).TotalMilliseconds)); }
        static string Tail(string text) { text = (text ?? "").Trim(); return text.Length > 300 ? text.Substring(text.Length - 300) : text; }

        // ---- курсоры -----------------------------------------------------------------------
        Dictionary<string, Cursor> LoadCursors()
        {
            var map = new Dictionary<string, Cursor>();
            try {
                var streams = Json.Map(Json.Get(Json.Read(cursorFile), "streams"));
                foreach (var pair in streams) {
                    var c = Json.Map(pair.Value);
                    long off; long.TryParse(Json.Str(c, "off"), NumberStyles.None, CultureInfo.InvariantCulture, out off);
                    map[pair.Key] = new Cursor { Fp = Json.Str(c, "fp"), FpLen = Json.Int(c, "fpLen", 0), Off = off };
                }
            } catch { }
            return map;
        }
        void SaveCursors(Dictionary<string, Cursor> cursors)
        {
            var streams = new Dictionary<string, object>();
            foreach (var pair in cursors) streams[pair.Key] = new Dictionary<string, object> { { "fp", pair.Value.Fp }, { "fpLen", pair.Value.FpLen }, { "off", pair.Value.Off.ToString(CultureInfo.InvariantCulture) } };
            Json.Write(cursorFile, new Dictionary<string, object> { { "schema", 1 }, { "streams", streams } });
        }
        void Advance(Dictionary<string, Cursor> cursors, List<Segment> segments)
        {
            foreach (var group in segments.GroupBy(s => s.Stream)) {
                var last = group.Last();
                cursors[group.Key] = new Cursor { Fp = last.Fp, FpLen = FpLength(last), Off = last.To };
            }
            SaveCursors(cursors);
        }
        static int FpLength(Segment s) { return s.FpLen; }

        static string[] FilesOf(string dir, string stream)
        {
            var list = new List<string>();
            string path = Path.Combine(dir, stream + ".log");
            for (int i = 5; i >= 1; i--) { string a = path + "." + i.ToString(CultureInfo.InvariantCulture); if (File.Exists(a)) list.Add(a); }
            if (File.Exists(path)) list.Add(path);
            return list.ToArray();
        }
        static string Fingerprint(string file, int length, out int actual)
        {
            using (var f = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
                var buffer = new byte[length]; int read = 0, n;
                while (read < length && (n = f.Read(buffer, read, length - read)) > 0) read += n;
                actual = read;
                using (var sha = SHA1.Create()) return BitConverter.ToString(sha.ComputeHash(buffer, 0, read)).Replace("-", "").ToLowerInvariant();
            }
        }

        // Собирает новые строки по всем потокам до 512 КБ.
        List<Segment> Collect(Dictionary<string, Cursor> cursors)
        {
            var result = new List<Segment>(); int budget = MaxRawBytes;
            foreach (string stream in Streams) {
                if (budget <= 0) break;
                string[] files = FilesOf(logsDir, stream);
                if (files.Length == 0) continue;
                Cursor cursor; cursors.TryGetValue(stream, out cursor);
                int startIndex = 0; long startOffset = 0;
                if (cursor != null && cursor.Fp.Length > 0) {
                    int found = -1;
                    for (int i = files.Length - 1; i >= 0 && found < 0; i--) {
                        try { int actual; if (new FileInfo(files[i]).Length >= cursor.FpLen && Fingerprint(files[i], cursor.FpLen, out actual) == cursor.Fp && actual == cursor.FpLen) found = i; } catch { }
                    }
                    if (found < 0) { if (gaps.Add(stream + "|" + cursor.Fp)) log(LogLevel.Warn, "ship.gap", new[] { "stream", stream, "lost", "unknown" }); }
                    else { gaps.RemoveWhere(g => g.StartsWith(stream + "|", StringComparison.Ordinal)); startIndex = found; startOffset = cursor.Off; }
                }
                for (int i = startIndex; i < files.Length && budget > 0; i++) {
                    long offset = i == startIndex ? startOffset : 0;
                    var seg = ReadSegment(stream, files[i], offset, budget);
                    if (seg != null) { result.Add(seg); budget -= seg.Data.Length; }
                }
            }
            return result;
        }
        Segment ReadSegment(string stream, string file, long offset, int budget)
        {
            try {
                using (var f = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
                    if (offset > f.Length) offset = 0; // файл заменён
                    int want = (int)Math.Min(f.Length - offset, budget);
                    if (want <= 0) return null;
                    f.Seek(offset, SeekOrigin.Begin);
                    var buffer = new byte[want]; int read = 0, n;
                    while (read < want && (n = f.Read(buffer, read, want - read)) > 0) read += n;
                    // Только целые строки. Неполный хвост дочитается позже.
                    int end = read; while (end > 0 && buffer[end - 1] != 10) end--;
                    if (end == 0) return null;
                    int skip = offset == 0 && end >= 3 && buffer[0] == 0xEF && buffer[1] == 0xBB && buffer[2] == 0xBF ? 3 : 0;
                    var data = new byte[end - skip];
                    Buffer.BlockCopy(buffer, skip, data, 0, data.Length);
                    int lines = 0;
                    foreach (byte value in data) if (value == 10) lines++;
                    int fpActual; string fp = Fingerprint(file, 256, out fpActual);
                    return new Segment { Stream = stream, Fp = fp, FpLen = fpActual, From = offset + skip, To = offset + end, Lines = lines, Data = data };
                }
            } catch { return null; }
        }

        byte[] Pack(string batchId, List<Segment> segments)
        {
            var text = new StringBuilder();
            text.Append("RA-LOGS 1 batch=").Append(batchId).Append(" device=").Append(Base64Url(device)).Append(" host=").Append(host)
                .Append(" ver=").Append(version).Append(" sent=").Append(utcNow().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture)).Append('\n');
            using (var ms = new MemoryStream()) {
                using (var gz = new GZipStream(ms, CompressionMode.Compress, true)) {
                    var header = Encoding.UTF8.GetBytes(text.ToString());
                    gz.Write(header, 0, header.Length);
                    foreach (var s in segments) {
                        text.Clear();
                        text.Append("@@ ").Append(s.Stream).Append(" fp=").Append(s.Fp).Append(" from=").Append(s.From.ToString(CultureInfo.InvariantCulture))
                            .Append(" to=").Append(s.To.ToString(CultureInfo.InvariantCulture)).Append(" lines=").Append(s.Lines.ToString(CultureInfo.InvariantCulture)).Append('\n');
                        header = Encoding.UTF8.GetBytes(text.ToString());
                        gz.Write(header, 0, header.Length);
                        // Смещения и число строк относятся к исходным байтам, включая неверный UTF-8.
                        gz.Write(s.Data, 0, s.Data.Length);
                    }
                }
                return ms.ToArray();
            }
        }
        internal static string Base64Url(string value)
        { return Convert.ToBase64String(Encoding.UTF8.GetBytes(value)).TrimEnd('=').Replace('+', '-').Replace('/', '_'); }
    }
}
