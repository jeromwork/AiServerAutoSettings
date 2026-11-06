using System.Text.Json;
namespace RemoteAgents.Core;

public sealed record ProjectBinding(string ProjectId, string HostId, string ReplicaPath, string FolderId, string StateDirectory);
public static class SyncDiscovery
{
    public static IReadOnlyList<ProjectBinding> Find(string dataDir)
    {
        var root = Path.Combine(dataDir, "sync", "projects");
        if (!Directory.Exists(root)) return [];
        var result = new List<ProjectBinding>();
        foreach (var file in Directory.EnumerateFiles(root, "project.json", SearchOption.AllDirectories))
        {
            try
            {
                using var doc = JsonDocument.Parse(File.ReadAllText(file));
                var e = doc.RootElement;
                result.Add(new(e.GetProperty("projectId").GetString()!, e.GetProperty("hostId").GetString()!,
                    e.GetProperty("replicaPath").GetString()!, e.GetProperty("folderId").GetString()!, Path.GetDirectoryName(file)!));
            }
            catch (Exception ex) when (ex is IOException or JsonException or KeyNotFoundException or InvalidOperationException) { }
        }
        return result;
    }
}

public sealed class PauseController
{
    private DateTimeOffset? _until;
    private bool _untilResume;
    public bool IsPaused => _untilResume || (_until is not null && _until > DateTimeOffset.UtcNow);
    public void Pause(TimeSpan duration) { _until = DateTimeOffset.UtcNow + duration; _untilResume = false; }
    public void PauseUntilResume() { _until = null; _untilResume = true; }
    public void Resume() { _until = null; _untilResume = false; }
}
