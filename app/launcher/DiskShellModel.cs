using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Threading;

namespace RemoteAgents.Launcher
{
    // Explorer's static verbs have no batching protocol. This short queue only groups the arguments
    // forwarded by the existing single-instance pipe; Syncthing still performs all transfers.
    internal sealed class DiskShellRequest
    {
        internal string Action = "", Path = "";
        internal static bool TryParse(string[] args, out DiskShellRequest request)
        {
            request = null;
            if (args != null) {
                var clean = new List<string>();
                for (int i = 0; i < args.Length; i++) { if (args[i] == "--home" && i + 1 < args.Length) { i++; continue; } clean.Add(args[i]); }
                args = clean.ToArray();
            }
            if (args == null || args.Length < 2 || args[0] != "--disk-shell") return false;
            if (!new[] { "download", "sync", "keep-server", "add", "progress" }.Contains(args[1])) throw new IOException("Неизвестная команда Диска");
            if (args.Length != 3 || string.IsNullOrWhiteSpace(args[2]) || args[2].Any(c => c < ' ')) throw new IOException("Проводник не передал путь папки");
            request = new DiskShellRequest { Action = args[1], Path = args[2] }; return true;
        }
    }
    internal sealed class DiskShellBatchQueue
    {
        readonly List<DiskShellRequest> waiting = new List<DiskShellRequest>();
        DateTime deadline, first;
        internal void Add(DiskShellRequest request, DateTime now)
        {
            if (waiting.Count == 0) first = now;
            if (!waiting.Any(r => r.Action == request.Action && DiskSyncSnapshot.SamePath(r.Path, request.Path))) waiting.Add(request);
            deadline = now.AddMilliseconds(550); if (deadline > first.AddSeconds(2)) deadline = first.AddSeconds(2);
        }
        internal IList<DiskShellRequest> Take(DateTime now)
        {
            if (waiting.Count == 0 || now < deadline) return new DiskShellRequest[0];
            var result = waiting.ToArray(); waiting.Clear(); return result;
        }
    }
    internal sealed class DiskTransferRate
    {
        DiskSyncSnapshot previous;
        internal string Observe(DiskSyncSnapshot snapshot)
        {
            var old = previous; previous = snapshot;
            if (old == null || snapshot.Failure.Length > 0 || old.Failure.Length > 0 || snapshot.InBytesTotal < 0 || old.InBytesTotal < 0 || snapshot.OutBytesTotal < 0 || old.OutBytesTotal < 0) return "Скорость ещё не измерена";
            double seconds = (snapshot.ObservedUtc - old.ObservedUtc).TotalSeconds;
            if (seconds <= 0) return "Скорость ещё не измерена";
            decimal down = snapshot.InBytesTotal - old.InBytesTotal, up = snapshot.OutBytesTotal - old.OutBytesTotal;
            if (down < 0 || up < 0) return "Счётчики Syncthing перезапущены";
            return "Приём: " + Speed(down / (decimal)seconds) + " · отдача: " + Speed(up / (decimal)seconds);
        }
        static string Speed(decimal n) { return (n / 1048576).ToString("0.##", CultureInfo.GetCultureInfo("ru-RU")) + " МБ/с"; }
    }
    internal static class DiskDetailsSettings
    {
        // --windowed calls launcher.autostart() in upstream v2.1.9 too. A private INI in the
        // working directory disables both the engine launcher and optional external tool launchers.
        internal static string WithoutAutostart(string text)
        {
            var lines = Files.LF(text).Split('\n').ToList(); string section = ""; bool startup = false, seen = false;
            for (int i = 0; i < lines.Count; i++) {
                string value = lines[i].Trim();
                if (value.StartsWith("[") && value.EndsWith("]")) { section = value.ToLowerInvariant(); if (section == "[startup]") startup = true; }
                int equal = value.IndexOf('=');
                if (equal < 0) continue;
                string key = value.Substring(0, equal).Trim();
                if (section == "[startup]" && key.Equals("syncthingAutostart", StringComparison.OrdinalIgnoreCase)) { lines[i] = "syncthingAutostart=false"; seen = true; }
                else if (key.Equals("autostart", StringComparison.OrdinalIgnoreCase) || key.EndsWith("\\autostart", StringComparison.OrdinalIgnoreCase)) lines[i] = key + "=false";
            }
            if (!seen) {
                int at = lines.FindIndex(l => l.Trim().Equals("[startup]", StringComparison.OrdinalIgnoreCase));
                if (!startup) { lines.Add("[startup]"); lines.Add("syncthingAutostart=false"); }
                else lines.Insert(at + 1, "syncthingAutostart=false");
            }
            return string.Join("\r\n", lines).TrimEnd('\r', '\n') + "\r\n";
        }
    }
    internal static class DiskEvictionProof
    {
        internal static string Refusal(DiskSyncSnapshot snapshot, DiskSyncFolder folder, Dictionary<string, object> completion)
        {
            if (!DiskSyncStatus.Complete(snapshot, folder)) return "Локальная папка ещё не синхронизирована: " + DiskSyncStatus.Text(snapshot, folder);
            if (DiskSyncStatus.Number(completion, "completion") != 100 || DiskSyncStatus.Number(completion, "needBytes") != 0 || DiskSyncStatus.Number(completion, "needItems") != 0 || DiskSyncStatus.Number(completion, "needDeletes") != 0 || Json.Str(completion, "remoteState") != "valid") return "Сервер не подтвердил полную копию папки (100%)";
            return "";
        }
        // REST exposes blocksHash but omits RawBlockSize. Syncthing's public format is SHA256
        // of the concatenated SHA256 block digests; test supported power-of-two block sizes whose
        // count agrees with numBlocks. This checks content without implementing a sync engine.
        // https://github.com/syncthing/syncthing/blob/v1.30.0/lib/protocol/bep_fileinfo.go (BlocksHash)
        // https://github.com/syncthing/syncthing/blob/v1.30.0/lib/protocol/protocol.go (Min/MaxBlockSize)
        internal static bool ContentConfirmed(Stream content, Dictionary<string, object> local, CancellationToken token)
        {
            if (!content.CanSeek || DiskSyncStatus.Number(local, "size") != content.Length) return false;
            byte[] expected;
            try { expected = Convert.FromBase64String(Json.Str(local, "blocksHash")); } catch (FormatException) { return false; }
            if (expected.Length != 32) return false;
            decimal count = DiskSyncStatus.Number(local, "numBlocks");
            for (int blockSize = 128 * 1024; blockSize <= 16 * 1024 * 1024; blockSize *= 2) {
                if (count != Math.Max(1, (content.Length + blockSize - 1) / blockSize)) continue;
                content.Position = 0; var buffer = new byte[blockSize];
                using (var aggregate = SHA256.Create()) using (var block = SHA256.Create()) {
                    do {
                        token.ThrowIfCancellationRequested(); int read = 0, n;
                        while (read < blockSize && (n = content.Read(buffer, read, blockSize - read)) > 0) { read += n; token.ThrowIfCancellationRequested(); }
                        byte[] digest = block.ComputeHash(buffer, 0, read);
                        aggregate.TransformBlock(digest, 0, digest.Length, digest, 0);
                    } while (content.Position < content.Length);
                    aggregate.TransformFinalBlock(new byte[0], 0, 0);
                    if (aggregate.Hash.SequenceEqual(expected)) return true;
                }
            }
            return false;
        }
        internal static bool FileConfirmed(Dictionary<string, object> response, string peer, bool directory, long length)
        {
            var local = Json.Map(Json.Get(response, "local")); var global = Json.Map(Json.Get(response, "global"));
            if (local.Count == 0 || global.Count == 0 || new[] { "deleted", "ignored", "invalid", "mustRescan" }.Any(k => Json.Bool(local, k) || Json.Bool(global, k))) return false;
            if (DiskSyncStatus.Number(local, "localFlags", 0) != 0 || Json.Str(local, "name").Length == 0) return false;
            string type = directory ? "FILE_INFO_TYPE_DIRECTORY" : "FILE_INFO_TYPE_FILE";
            if (Json.Str(local, "type") != type || Json.Str(global, "type") != type) return false;
            var version = Json.Array(Json.Get(local, "version"));
            if (version.Length == 0 || ConfigSections.Canonical(version) != ConfigSections.Canonical(Json.Get(global, "version"))) return false;
            if (!directory && (DiskSyncStatus.Number(local, "size") != length || DiskSyncStatus.Number(global, "size") != length || Json.Str(local, "blocksHash") != Json.Str(global, "blocksHash"))) return false;
            // Availability is returned for files, not consistently for directories across engine versions.
            return directory || Json.Array(Json.Get(response, "availability")).Select(Json.Map).Any(a => Json.Str(a, "id") == peer && !Json.Bool(a, "fromTemporary"));
        }
    }
}
