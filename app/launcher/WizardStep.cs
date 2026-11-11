using System;
using System.Diagnostics;
using System.IO;
using System.Collections.Generic;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

namespace RemoteAgents.Launcher
{
    // Old installation (RemoteDiskChannel task + syncthingtray + old bridge): the old channel holds the
    // production ports until Migrate.ps1 takes over. The tray must not start conflicting components.
    internal static class LegacyInstall
    {
        internal static readonly string[] HeldComponents = { "transport", "disk", "control" };
        internal static bool Hold(bool channelTask, string phase)
        { return channelTask && !new[] { "activating", "pending", "accepted" }.Contains(phase ?? ""); }
        internal static bool Held(bool hold, string component) { return hold && HeldComponents.Contains(component); }
        internal static bool ChannelTaskExists()
        {
            try {
                var info = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "schtasks.exe"), "/Query /TN RemoteDiskChannel") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
                using (var process = Process.Start(info)) {
                    var output = process.StandardOutput.ReadToEndAsync(); var error = process.StandardError.ReadToEndAsync();
                    if (process.WaitForExit(15000)) return process.ExitCode == 0;
                    try { process.Kill(); } catch { }
                }
            } catch { }
            // Unknown: keep the old channel's ports free whenever its files are present.
            return File.Exists(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RemoteDisk", "channel", "config.json"));
        }
    }
    // Progress of a detached Migrate.ps1, read only from its state files.
    internal sealed class MigrationProgress
    {
        internal string Text = ""; internal bool Failed, Handover;
        internal static MigrationProgress Describe(string phase, DateTime? stateStarted, bool launcherTouched, string error, DateTime? errorAt, DateTime activation, DateTime now)
        {
            var slack = TimeSpan.FromSeconds(5);
            bool current = stateStarted.HasValue && stateStarted.Value >= activation - slack;
            bool failure = !string.IsNullOrEmpty(error) && (!errorAt.HasValue || errorAt.Value >= activation - slack);
            if (current && (phase == "activating" || phase == "pending" || phase == "accepted" || (phase == "preparing" && launcherTouched)))
                return new MigrationProgress { Handover = true, Text = "Переключаю на новую связь. Приложение перезапустится в трее; подтверждение — после 3 минут стабильной связи, иначе автоматический откат" };
            if (current && phase == "rolled-back")
                return new MigrationProgress { Failed = true, Text = "Переход откачен, прежняя связь восстановлена. " + (failure ? error : "Причина записана в logs\\migration.log") };
            if (failure) return new MigrationProgress { Failed = true, Text = error };
            if (current && phase == "rolling-back") return new MigrationProgress { Text = "Откатываю переход: возвращаю прежнюю связь…" };
            if (current) return new MigrationProgress { Text = "Проверяю новую связь на временных портах; прежняя связь работает. Независимый откат включён" };
            if ((now - activation).TotalSeconds > 90) return new MigrationProgress { Failed = true, Text = "Переход не начался. Проверьте logs\\migration.log и повторите" };
            return new MigrationProgress { Text = "Запускаю переход…" };
        }
        internal static MigrationProgress Read(string home, DateTime activation)
        {
            string phase = "", error = ""; DateTime? started = null, errorAt = null; bool touched = false;
            try {
                string state = Path.Combine(home, "state", "migration.json");
                if (File.Exists(state)) { var data = Json.Read(state); phase = Json.Str(data, "phase"); touched = Json.Bool(data, "launcherTouched"); started = Utc(Json.Str(data, "startedAt")); }
                string failure = Path.Combine(home, "state", "migration-error.json");
                if (File.Exists(failure)) { var data = Json.Read(failure); error = Json.Str(data, "message"); errorAt = Utc(Json.Str(data, "updatedAt")); }
            } catch (Exception) { return new MigrationProgress { Text = "Читаю состояние перехода…" }; }
            return Describe(phase, started, touched, error, errorAt, activation, DateTime.UtcNow);
        }
        static DateTime? Utc(string text)
        { DateTime value; return DateTime.TryParse(text, null, System.Globalization.DateTimeStyles.RoundtripKind | System.Globalization.DateTimeStyles.AdjustToUniversal, out value) ? (DateTime?)value.ToUniversalTime() : null; }
    }
    internal static class WizardStep
    {
        // First run: ready sections and the first unfinished one open; later ones wait. Settings: everything opens.
        internal static bool CanOpen(int section, int current, bool first, bool[] applied, int[] order)
        {
            if (!first || section == current) return true;
            if (section < applied.Length && applied[section]) return true;
            foreach (int i in order) { if (i == section) return true; if (i < applied.Length && !applied[i]) return false; }
            return false;
        }
        // A section waiting for a detached server install (⏳) does not block the sections after it.
        internal static bool[] Passable(bool[] applied, ICollection<int> waiting)
        { return applied.Select((ready, i) => ready || waiting.Contains(i)).ToArray(); }
        // Each budget covers the slowest child the action may run (child limits in Wizard.Common.ps1),
        // plus the observations around it. «Закрыть» cancels any step at once. Long server installs
        // (Happier, Syncthing) run detached on the server and are never inside these budgets.
        internal static int Timeout(string action)
        {
            switch (action) {
                case "Server": return 420 * 1000;    // key/password login ~100 s + helpers 60 s + start/catalog 120 s + 2 observations 120 s
                case "Account": case "ResumeAccount": return 420 * 1000; // helpers 60 s + status 60 s + Account.ps1 child 300 s
                case "Operation": return 60 * 1000;  // one short status call
                case "Disk": return 2100 * 1000;     // old disk detach 120 s + install 900 s + apply 900 s
                case "Connection": return 900 * 1000; // catalog/helpers/initialize ~400 s + preflight ~75 s + proof 120 s
                case "Bridge": return 900 * 1000;    // two bridge children 300 s each + live probes
                case "Vpn": return 600 * 1000;       // TUN child 420 s (may wait for UAC)
                case "Skip": return 300 * 1000;      // old disk detach 120 s
                case "Inspect": return 300 * 1000;   // server, account and bridge probes ~210 s
                case "Activate": return 180 * 1000;  // migration itself runs detached
                case "DiskTree": case "AccountList": return 180 * 1000; // helper upload 60 s + listing 60 s
                case "Proxy": return 420 * 1000;     // root probe 20 s + apply 180 s + confirm in a new SSH 120 s
                case "Lan": return 480 * 1000;       // root probe 20 s + add (may install OpenVPN) 300 s + test/confirm 120 s
                case "LanRemove": return 240 * 1000; // root probe 20 s + remove 180 s
                default: return 120 * 1000;          // Catalog, NetStatus, AdminProbe
            }
        }
        // Shared by real external steps and the portable process tests. NativeJob owns the process tree.
        internal static int Wait(Process process, string output, int timeoutMs, long maxBytes, CancellationToken token)
        {
            var watch = Stopwatch.StartNew();
            while (!process.WaitForExit(100)) {
                token.ThrowIfCancellationRequested();
                if (watch.ElapsedMilliseconds >= timeoutMs)
                    throw new TimeoutException("Превышено время ожидания (" + (timeoutMs / 1000) + " с). Проверьте связь и повторите шаг.");
                if (output != null && new FileInfo(output).Length > maxBytes) throw new IOException("Вывод команды слишком велик");
            }
            token.ThrowIfCancellationRequested();
            if (output != null && new FileInfo(output).Length > maxBytes) throw new IOException("Вывод команды слишком велик");
            return process.ExitCode;
        }
    }
    // A new Happier secret key in the form the apps accept for «Restore with Secret Key»:
    // RFC 4648 base32 of 32 random bytes, groups of five (accounts/server-account.mjs normalizeKey).
    internal static class HappierKey
    {
        const string Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
        internal static string Create()
        { var bytes = new byte[32]; using (var rng = RandomNumberGenerator.Create()) rng.GetBytes(bytes); return Format(bytes); }
        internal static string Format(byte[] bytes)
        {
            var text = new StringBuilder(); int buffer = 0, bits = 0;
            foreach (byte b in bytes) { buffer = (buffer << 8) | b; bits += 8; while (bits >= 5) { bits -= 5; text.Append(Alphabet[(buffer >> bits) & 31]); } }
            if (bits > 0) text.Append(Alphabet[(buffer << (5 - bits)) & 31]);
            var groups = new List<string>();
            for (int i = 0; i < text.Length; i += 5) groups.Add(text.ToString(i, Math.Min(5, text.Length - i)));
            return string.Join("-", groups);
        }
    }
}
