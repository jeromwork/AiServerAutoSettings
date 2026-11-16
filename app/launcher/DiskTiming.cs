using System;
using System.Globalization;
using System.IO;

namespace RemoteAgents.Launcher
{
    // All values retain their shipping defaults. Tests use per-setting overrides.
    internal static class DiskTiming
    {
        internal static int Milliseconds(string name, int fallback)
        {
            string value = Environment.GetEnvironmentVariable("REMOTE_DISK_" + name + "_MS");
            if (string.IsNullOrEmpty(value)) return fallback;
            int parsed;
            if (!int.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out parsed) || parsed <= 0)
                throw new IOException("Недопустимый интервал Диска: " + name);
            return parsed;
        }
        internal static int Seconds(string name, int fallback) { return Milliseconds(name, fallback * 1000) / 1000; }
    }
}
