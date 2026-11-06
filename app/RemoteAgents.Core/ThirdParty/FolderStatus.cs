// Adapted from SyncTrayzor afac7f1; MIT, Antony Male 2015–2021, GermanCoding 2025.
// Full notice: THIRD-PARTY-NOTICES.txt. JSON attributes adapted to System.Text.Json.
using System.Text.Json.Serialization;
using System;

namespace RemoteAgents.Core.ThirdParty
{
    public class FolderStatus
    {
        [JsonPropertyName("globalBytes")]
        public long GlobalBytes { get; set; }

        [JsonPropertyName("globalDeleted")]
        public int GlobalDeleted { get; set; }

        [JsonPropertyName("globalFiles")]
        public int GlobalFiles { get; set; }

        [JsonPropertyName("localBytes")]
        public long LocalBytes { get; set; }

        [JsonPropertyName("localDeleted")]
        public int LocalDeleted { get; set; }

        [JsonPropertyName("localFiles")]
        public int LocalFiles { get; set; }

        [JsonPropertyName("inSyncBytes")]
        public long InSyncBytes { get; set; }

        [JsonPropertyName("inSyncFiles")]
        public int InSyncFiles { get; set; }

        [JsonPropertyName("needBytes")]
        public long NeedBytes { get; set; }

        [JsonPropertyName("needFiles")]
        public int NeedFiles { get; set; }

        [JsonPropertyName("invalid")]
        public string? Invalid { get; set; }

        [JsonPropertyName("state")]
        public string? State { get; set; }

        [JsonPropertyName("stateChanged")]
        public DateTime StateChanged { get; set; }

        [JsonPropertyName("version")]
        public int Version { get; set; }

        public override string ToString()
        {
            return $"<FolderStatus GlobalBytes={GlobalBytes} GlobalDeleted={GlobalDeleted} GlobalFiles={GlobalFiles} " +
                $"LocalBytes={LocalBytes} LocalDeleted={LocalDeleted} LocalFiles={LocalFiles} " +
                $"InSyncBytes={InSyncBytes} InSyncFiles={InSyncFiles} NeedBytes={NeedBytes} NeedFiles={NeedFiles} " +
                $"Invalid={Invalid} State={State} StateChanged={StateChanged} Version={Version}>";
        }
    }
}
