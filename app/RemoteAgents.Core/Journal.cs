using System.IO.Compression;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace RemoteAgents.Core;

// Closed event vocabulary: never accepts exception messages, process output, paths or file contents.
public sealed class Journal
{
    readonly object gate = new();
    readonly string root, host;
    readonly long rotationBytes;
    public string DirectoryPath => root;
    public string QueuePath => Path.Combine(root, "queue");
    public Journal(string root, string hostId, long rotationBytes = 2 * 1024 * 1024)
    {
        if (!Regex.IsMatch(hostId, "^[a-z0-9][a-z0-9_-]{0,63}$")) throw new ArgumentException("Invalid host identity");
        this.root = root; host = hostId; this.rotationBytes = rotationBytes;
        Directory.CreateDirectory(root); Directory.CreateDirectory(QueuePath);
    }
    static string Label(string value) => Regex.IsMatch(value, "^[a-z][a-z0-9_.-]{0,63}$") ? value : "redacted";
    public void Write(string component, string action, string outcome, long durationMs = 0, int? exitCode = null, long? bytes = null)
    {
        var line = JsonSerializer.Serialize(new { time = DateTimeOffset.UtcNow, hostId = host, component = Label(component), action = Label(action), outcome = Label(outcome), durationMs, exitCode, bytes }) + "\n";
        lock (gate)
        {
            var date = DateTime.UtcNow.ToString("yyyyMMdd");
            var files = Directory.GetFiles(root, date + "-*.jsonl").Order().ToArray();
            var file = files.LastOrDefault();
            if (file == null || new FileInfo(file).Length >= rotationBytes) file = Path.Combine(root, date + "-" + DateTime.UtcNow.Ticks + ".jsonl");
            // Local write precedes queue and every network operation. Flush to disk.
            using (var stream = new FileStream(file, FileMode.Append, FileAccess.Write, FileShare.Read))
            { var data = System.Text.Encoding.UTF8.GetBytes(line); stream.Write(data); stream.Flush(true); }
            var target = Path.Combine(QueuePath, Guid.NewGuid().ToString("N") + ".jsonl");
            File.WriteAllText(target + ".tmp", line); File.Move(target + ".tmp", target);
        }
    }
    public string CollectDiagnostics(string destination)
    {
        lock (gate)
        {
            using var archive = ZipFile.Open(destination, ZipArchiveMode.Create);
            // Explicit allowlist: no config, API keys, stdout, SSH profiles or user files.
            foreach (var path in Directory.GetFiles(root, "*.jsonl")) archive.CreateEntryFromFile(path, Path.GetFileName(path));
            using var writer = new StreamWriter(archive.CreateEntry("README.txt").Open());
            writer.Write("RemoteAgents diagnostics: structured local events only. Network and config contents deliberately omitted.");
        }
        return destination;
    }
    public async Task<int> FlushQueueAsync(Func<string, CancellationToken, Task<bool>> send, CancellationToken token)
    {
        int count = 0;
        foreach (var file in Directory.GetFiles(QueuePath, "*.jsonl").Order())
        {
            token.ThrowIfCancellationRequested();
            if (!await send(await File.ReadAllTextAsync(file, token), token)) break;
            File.Delete(file); count++;
        }
        return count;
    }
}
