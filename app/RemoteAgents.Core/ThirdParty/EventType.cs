// Adapted from SyncTrayzor afac7f1; MIT, Antony Male 2015–2021, GermanCoding 2025.
// Full notice: THIRD-PARTY-NOTICES.txt. JSON attributes adapted to System.Text.Json.
using System.Text.Json.Serialization;

namespace RemoteAgents.Core.ThirdParty
{
    
    public enum EventType
    {
        Unknown,

        StartupComplete,
        DeviceConnected,
        DeviceDisconnected,
        RemoteIndexUpdated,
        LocalIndexUpdated,
        ItemStarted,
        ItemFinished,
        StateChanged,
        FolderRejected,
        DeviceRejected,
        ConfigSaved,
        DownloadProgress,
        FolderSummary,
        FolderErrors,
        DevicePaused,
        DeviceResumed,
    }
}
