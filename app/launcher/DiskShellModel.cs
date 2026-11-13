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
        readonly List<DiskShellRequest> active = new List<DiskShellRequest>();
        DateTime deadline, first;
        internal bool Pending { get { return waiting.Count > 0 || active.Count > 0; } }
        internal void Receive(DiskShellRequest request, DateTime now, Action<bool> present)
        { bool added = Add(request, now); present(added); }
        internal bool Add(DiskShellRequest request, DateTime now)
        {
            if (active.Concat(waiting).Any(r => DiskSyncSnapshot.SamePath(r.Path, request.Path))) return false;
            if (waiting.Count == 0) first = now;
            if (!waiting.Any(r => r.Action == request.Action && DiskSyncSnapshot.SamePath(r.Path, request.Path))) waiting.Add(request);
            deadline = now.AddMilliseconds(550); if (deadline > first.AddSeconds(2)) deadline = first.AddSeconds(2);
            return true;
        }
        internal void Complete(IEnumerable<DiskShellRequest> batch) { foreach (var request in batch) active.Remove(request); }
        internal IList<DiskShellRequest> Take(DateTime now)
        {
            if (waiting.Count == 0 || now < deadline) return new DiskShellRequest[0];
            var result = waiting.ToArray(); waiting.Clear(); active.AddRange(result); return result;
        }
    }
    // Shared operation rows precede REST observations; guarded because wizard reports arrive on workers.
    internal sealed class DiskCommandProgress
    {
        readonly object gate = new object();
        readonly Dictionary<string, DiskCommandRow> rows = new Dictionary<string, DiskCommandRow>(StringComparer.OrdinalIgnoreCase);
        static string Key(string path) { return path.Replace('\\', '/').TrimEnd('/'); }
        internal void Begin(IEnumerable<string> paths)
        { lock (gate) foreach (string path in paths) rows[Key(path)] = new DiskCommandRow { Path = path, Active = true, Step = "Подключаю к серверу…" }; }
        internal void Report(IEnumerable<string> paths, string text)
        {
            text = text.Replace("\r", "").Split('\n')[0];
            lock (gate) foreach (string path in paths) {
                DiskCommandRow row; if (!rows.TryGetValue(Key(path), out row)) continue;
                string prefix = "Не подключена папка «", marker = "»: "; int end = text.IndexOf(marker, StringComparison.Ordinal);
                if (text.StartsWith(prefix, StringComparison.Ordinal) && end > prefix.Length) {
                    string name = text.Substring(prefix.Length, end - prefix.Length);
                    if (Key(path).Split('/').Last().Equals(name, StringComparison.OrdinalIgnoreCase) && row.Failure.Length == 0) row.Failure = text.Substring(end + marker.Length);
                } else row.Step = text;
            }
        }
        internal void Finish(IEnumerable<string> paths, bool ok, string reason)
        {
            lock (gate) foreach (string path in paths) {
                DiskCommandRow row; if (!rows.TryGetValue(Key(path), out row)) continue;
                if (ok) rows.Remove(Key(path));
                else { row.Active = false; if (row.Failure.Length == 0) row.Failure = Reason(path, reason); }
            }
        }
        internal Dictionary<string, DiskCommandRow> Snapshot()
        { lock (gate) return rows.ToDictionary(p => p.Key, p => p.Value.Copy(), StringComparer.OrdinalIgnoreCase); }
        internal static string[] SelectedPaths(DiskChoice choice, string root)
        {
            var names = choice.Folders.Select(f => DiskChoice.Project(f.Path));
            if (choice.All && Directory.Exists(root)) names = names.Concat(Directory.EnumerateDirectories(root).Select(Path.GetFileName));
            return names.Distinct(StringComparer.OrdinalIgnoreCase).Select(n => Path.Combine(root, n)).Concat(choice.External.Select(e => e.Path)).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        }
        static string Reason(string path, string reason)
        {
            string clean = reason.Replace("\r", "").Split('\n')[0];
            string marker = "«" + Key(path).Split('/').Last() + "» — ";
            int start = clean.IndexOf(marker, StringComparison.OrdinalIgnoreCase);
            if (start >= 0) clean = clean.Substring(start + marker.Length).Split(';')[0].Replace(". Остальные папки подключены; локальные файлы сохранены.", "");
            int cause = clean.IndexOf("Причина: ", StringComparison.Ordinal);
            if (cause >= 0) clean = clean.Substring(cause + 9);
            return clean.Length > 220 ? clean.Substring(0, 217) + "…" : clean;
        }
        internal void EnsureFailure(IEnumerable<string> paths, string reason)
        {
            lock (gate) foreach (string path in paths) {
                DiskCommandRow row;
                if (!rows.TryGetValue(Key(path), out row)) rows[Key(path)] = row = new DiskCommandRow { Path = path };
                row.Active = false; row.Recoverable = true;
                if (row.Failure.Length == 0) row.Failure = Reason(path, reason);
                if (!row.RetryUtc.HasValue) row.RetryUtc = DateTime.UtcNow.AddSeconds(30);
            }
        }
        internal void Clear() { lock (gate) rows.Clear(); }
        internal void Reconcile(Dictionary<string, string> selected, Dictionary<string, string> missing, DateTime? next)
        {
            lock (gate) {
                foreach (var key in rows.Keys.ToArray()) {
                    var row = rows[key]; if (row.Active) continue;
                    bool wanted = selected.Values.Any(p => DiskSyncSnapshot.SamePath(p, row.Path));
                    bool absent = missing.Values.Any(p => DiskSyncSnapshot.SamePath(p, row.Path));
                    if (wanted && !absent || row.Recoverable && !wanted) rows.Remove(key);
                }
                foreach (string path in missing.Values) {
                    DiskCommandRow row;
                    if (!rows.TryGetValue(Key(path), out row)) rows[Key(path)] = row = new DiskCommandRow { Path = path, Failure = "Выбрана, но ещё не подключена к серверу" };
                    row.Recoverable = true; row.RetryUtc = row.Active ? null : next;
                }
            }
        }
        internal DiskCommandRow Row(string path)
        { lock (gate) { DiskCommandRow row; return rows.TryGetValue(Key(path), out row) ? row.Copy() : null; } }
    }
    // Scheduling only: every attempt uses ConfigSession.ApplyDisk and the existing serial runner.
    internal sealed class DiskRecoverySchedule
    {
        string binding = ""; int delay = 30; bool missing;
        internal DateTime? NextUtc { get; private set; }
        internal bool Observe(string currentBinding, bool hasMissing, DateTime now)
        {
            bool changed = binding.Length > 0 && binding != currentBinding;
            if (binding != currentBinding) { binding = currentBinding; NextUtc = null; delay = 30; }
            missing = hasMissing;
            if (!missing) { NextUtc = null; delay = 30; }
            else if (!NextUtc.HasValue) NextUtc = now.AddSeconds(30);
            return changed;
        }
        internal bool Due(bool connected, bool occupied, DateTime now)
        { return missing && connected && !occupied && NextUtc.HasValue && now >= NextUtc.Value; }
        internal void RetryNow(DateTime now) { if (missing) NextUtc = now; }
        internal void Started() { delay = Math.Min(300, delay * 2); }
        internal void Finished(DateTime now) { if (missing) NextUtc = now.AddSeconds(delay); }
        internal static Dictionary<string, string> Missing(Dictionary<string, string> selected, DiskSyncSnapshot snapshot)
        {
            return selected.Where(p => {
                DiskSyncFolder folder;
                return !snapshot.Folders.TryGetValue(p.Key, out folder) || folder.Id.Length == 0 || !folder.Shared || folder.Pending || !DiskSyncSnapshot.SamePath(folder.Path, p.Value);
            }).ToDictionary(p => p.Key, p => p.Value, StringComparer.OrdinalIgnoreCase);
        }
    }
    internal sealed class DiskCommandRow
    {
        internal string Path = "", Step = "", Failure = ""; internal bool Active, Recoverable;
        internal DateTime? RetryUtc;
        internal DiskCommandRow Copy() { return (DiskCommandRow)MemberwiseClone(); }
        internal string NextText { get { return RetryUtc.HasValue ? "Автоповтор в " + RetryUtc.Value.ToLocalTime().ToString("HH:mm:ss") + " при наличии связи" : ""; } }
        internal string Text { get { return Failure.Length > 0 ? "⚠ " + Failure + (NextText.Length > 0 ? " · " + NextText : "") : Step; } }
        internal bool Marquee { get { return Active && Failure.Length == 0; } }
        internal bool CanRetry { get { return !Active && Failure.Length > 0 && Recoverable; } }
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
