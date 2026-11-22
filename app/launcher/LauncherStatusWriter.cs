using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;

namespace RemoteAgents.Launcher
{
    // Один экземпляр на файл/запуск трея, вызовы только из UI-потока.
    // updatedUtc — время изменения снимка, не heartbeat: одинаковый статус не создаёт ReplaceFile/RF-событий.
    internal sealed class LauncherStatusWriter
    {
        readonly string path;
        readonly Action<string, object> write;
        readonly Func<DateTime> clock;
        string lastHash; // один SHA-256 вместо удержания снимка с произвольными строками компонентов

        internal LauncherStatusWriter(string path, Action<string, object> write = null, Func<DateTime> clock = null)
        {
            this.path = path; this.write = write ?? Json.Write; this.clock = clock ?? (() => DateTime.UtcNow);
        }

        internal bool Write(Dictionary<string, object> snapshot)
        {
            var status = new Dictionary<string, object>(snapshot);
            status.Remove("updatedUtc");
            string hash;
            using (var sha = SHA256.Create())
                hash = BitConverter.ToString(sha.ComputeHash(Files.Utf8.GetBytes(Json.Encode(status))));
            if (hash == lastHash && File.Exists(path)) return false;
            status["updatedUtc"] = clock().ToString("o");
            write(path, status);
            // Не подтверждать неудавшуюся запись: следующий вызов повторит тот же снимок.
            lastHash = hash;
            return true;
        }
    }
}
