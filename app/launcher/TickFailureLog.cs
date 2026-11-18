using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Text.RegularExpressions;

namespace RemoteAgents.Launcher
{
    internal sealed class TickFailureLog
    {
        readonly Func<long> milliseconds;
        readonly Dictionary<string, long> reasons = new Dictionary<string, long>();
        internal TickFailureLog(Func<long> milliseconds = null)
        {
            var clock = Stopwatch.StartNew();
            this.milliseconds = milliseconds ?? (() => clock.ElapsedMilliseconds);
        }
        // One failed tick step must not cancel the others; the step name tells which one.
        internal bool Run(Journal journal, string step, Action action)
        {
            try { action(); return true; }
            catch (Exception error) { Write(journal, error, step); return false; }
        }
        internal void Write(Journal journal, Exception error, string step = null)
        {
            string detail = Describe(error);
            string reason = step + "|" + detail;
            long now = milliseconds();
            long previous;
            if (reasons.TryGetValue(reason, out previous) && now - previous < 60000) return;
            foreach (string key in reasons.Where(r => now - r.Value >= 60000).Select(r => r.Key).ToArray()) reasons.Remove(key);
            // Bound memory even if each tick produces a different failure.
            if (reasons.Count >= 128) return;
            reasons[reason] = now;
            journal.Write("supervisor.tick.failed " + (step == null ? "" : "step=" + step + " ") + detail);
        }
        internal static string Describe(Exception error)
        {
            // Never format StackTrace.ToString(): it includes source paths. Only method identity is needed.
            var frame = new StackTrace(error, false).GetFrame(0);
            var method = frame == null ? null : frame.GetMethod();
            string at = method == null ? "unknown" : (method.DeclaringType == null ? "" : method.DeclaringType.Name + ".") + method.Name;
            string message = MainScreenModel.CleanSecrets(error.Message);
            // Paths/URLs may contain unlabelled tokens; omit them in their entirety, including quoted paths.
            message = Regex.Replace(message, @"[""'][^""'\r\n]*[""']", "[скрыто]");
            message = Regex.Replace(message, @"[a-z][a-z0-9+.-]*://[^\r\n]*|(?:[a-z]:[\\/]|\\\\|/)[^\r\n]*", "[путь скрыт]", RegexOptions.IgnoreCase);
            message = Regex.Replace(message, @"\b[A-Za-z0-9_+=-]{24,}\b", "[скрыто]");
            message = Regex.Replace(message, @"[\p{Cc}\p{Cf}]+", " ");
            // Leave room for both type and top frame even when the message is long.
            return TrayMenuModel.Short(error.GetType().Name, 48) + " at " + TrayMenuModel.Short(at, 72) + ": " + TrayMenuModel.Short(message, 110);
        }
    }
}
