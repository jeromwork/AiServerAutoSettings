using System.Text.Json;

namespace RemoteAgents.Core;

public enum SyncState { Synced, Transferring, Paused, Disconnected, Error, Conflict }
public sealed record SyncStatus(SyncState State, double Percent = 0, long BytesDone = 0, long BytesTotal = 0, double BytesPerSecond = 0, string? Detail = null);
public sealed record SyncthingFolderStatus(string State, long NeedBytes, long NeedItems, long PullErrors, long ReceiveOnlyChangedItems, bool Connected, long InSyncBytes, long GlobalBytes);

public static class SyncStatusMapper
{
    public static SyncStatus Map(SyncthingFolderStatus s)
    {
        if (s.PullErrors > 0 || s.ReceiveOnlyChangedItems > 0) return new(SyncState.Conflict, Detail: "Обнаружены ошибки или локальные изменения");
        if (!s.Connected) return new(SyncState.Disconnected);
        if (s.State.Equals("paused", StringComparison.OrdinalIgnoreCase)) return new(SyncState.Paused);
        if (s.NeedItems > 0 || s.NeedBytes > 0 || s.State.Equals("scanning", StringComparison.OrdinalIgnoreCase))
        {
            var total = Math.Max(s.GlobalBytes, s.InSyncBytes + s.NeedBytes);
            var done = Math.Max(0, total - s.NeedBytes);
            return new(SyncState.Transferring, total == 0 ? 0 : Math.Clamp(100d * done / total, 0, 100), done, total);
        }
        return s.State.Equals("idle", StringComparison.OrdinalIgnoreCase) ? new(SyncState.Synced, 100, s.GlobalBytes, s.GlobalBytes) : new(SyncState.Error, Detail: "Неизвестное состояние Syncthing: " + s.State);
    }
}

public sealed record SyncConfig(int SchemaVersion, string ProjectId, string HostId, string FolderId, string ReplicaPath, int VersioningDays = 30, long? MaxSendRateKbps = null, long? MaxReceiveRateKbps = null);
public static class SyncConfigStore
{
    public const int CurrentSchema = 1;
    public static void Save(string path, SyncConfig config)
    {
        if (config.SchemaVersion != CurrentSchema) throw new InvalidDataException("Unsupported config schema");
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        var tmp = path + ".tmp"; File.WriteAllText(tmp, JsonSerializer.Serialize(config, new JsonSerializerOptions { WriteIndented = true })); File.Move(tmp, path, true);
    }
    public static SyncConfig Load(string path)
    {
        var value = JsonSerializer.Deserialize<SyncConfig>(File.ReadAllText(path)) ?? throw new InvalidDataException("Empty config");
        if (value.SchemaVersion != CurrentSchema || value.VersioningDays < 1 || value.VersioningDays > 3650) throw new InvalidDataException("Invalid config schema or settings");
        return value;
    }
}

public static class IgnorePolicy
{
    // Kept in parity with server-sync.py DENIED plus sensitive file suffixes.
    public static readonly string[] DeniedPatterns = ["(?i).env*", "(?i)env.example", "(?i).npmrc", "(?i).pypirc", "(?i).netrc", "auth.json", "(?i)*credential*", "(?i)*token*", "(?i)*secret*", "(?i)*private*", "id_*", ".git", ".tools", ".ssh", ".codex", ".claude", "node_modules", "vendor", "deps", "dependencies", ".gradle", ".next", ".cache", ".stversions", ".stfolder", ".stignore", "build", "dist", "target", "obj", "bin", ".dart_tool", ".nuxt", ".output", ".turbo", ".cxx", "coverage", "logs", "log", "cache", "caches", "db", "database", "databases", "backup", "backups", "uploads", "storage", "android-sdk", ".idea", ".vscode", "local.properties", "google-services*.json", "GoogleService-Info.plist", "config.php", "*.pem", "*.key", "*.keystore", "*.jks", "*.p8", "*.p12", "*.pfx", "*.sqlite*", "*.db", "*.bak", "*.dump", "*.log", "*.zip", "*.tar", "*.gz", "*.exe", "*.dll", "*.so", "*.bin"];
    public static string Generate(IEnumerable<string>? additional = null) => string.Join("\n", DeniedPatterns.Concat(additional ?? []).Distinct(StringComparer.OrdinalIgnoreCase)) + "\n";
}

public sealed record ContextCommand(string Name, string? Path = null);
public static class ContextMenuLogic
{
    public static IReadOnlyList<string> Items(bool connectedFolder, bool isBackground, bool isFolder, bool excluded)
    {
        if (!connectedFolder) return isBackground || !isFolder ? [] : ["connect"];
        if (isBackground) return ["status"];
        if (isFolder) return ["status", "pause-resume", "disconnect", "log"];
        return [excluded ? "include" : "exclude", "versions"];
    }
    public static ContextCommand? Parse(IEnumerable<string> args)
    {
        var a = args.ToArray(); if (a.Length == 0) return null;
        var allowed = new HashSet<string>(["--connect", "--status", "--pause", "--resume", "--disconnect", "--exclude", "--include", "--versions", "--log"]);
        return allowed.Contains(a[0]) && a.Length <= 2 ? new(a[0][2..], a.Length == 2 ? a[1] : null) : null;
    }
}

public sealed class RestartThrottle(TimeSpan minimumDelay)
{
    private DateTimeOffset _last = DateTimeOffset.MinValue;
    public bool TryStart(DateTimeOffset now) { if (now - _last < minimumDelay) return false; _last = now; return true; }
}
