using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;

namespace RemoteAgents.Launcher
{
    // One long server install (server-wizard.sh start/run), observed with short status calls.
    internal sealed class ServerOperation
    {
        internal string Name = "", Title = "", State = "none", Step = "", Reason = "";
        internal int Stage, Stages, ElapsedSec;
    }
    // Shared by the wizard's «Установка» list item and the tray (tooltip, «Готово» balloon, resume after
    // the window was closed). The installs run detached on the server: closing the window or the PC
    // never stops them. Only public status is stored here — never a key.
    internal static class ServerOperations
    {
        internal const string Account = "account";
        static readonly Dictionary<string, string> titles = new Dictionary<string, string> {
            { "happier", "Установка Happier" }, { "disk", "Сервер диска (Syncthing)" }, { Account, "Подключение аккаунта Happier" } };
        internal static string Title(string name) { string t; return titles.TryGetValue(name, out t) ? t : name; }
        internal static string StatePath(string home) { return Path.Combine(home, "state", "server-operations.json"); }
        internal static List<ServerOperation> Parse(Dictionary<string, object> operations, IEnumerable<string> tracked, bool pendingAccount)
        {
            var list = new List<ServerOperation>();
            foreach (string name in tracked.Where(n => n != Account).Distinct()) {
                var m = Json.Map(Json.Get(operations, name));
                list.Add(new ServerOperation { Name = name, Title = Title(name), State = Json.Text(m, "state", "none"), Step = Json.Str(m, "step"), Reason = Json.Str(m, "reason"),
                    Stage = Json.Int(m, "stage", 0), Stages = Json.Int(m, "stages", 0), ElapsedSec = Json.Int(m, "elapsedSec", 0) });
            }
            if (pendingAccount) {
                // The key is already saved; the connection waits for Happier and then runs by itself.
                string happier = Json.Text(Json.Map(Json.Get(operations, "happier")), "state", "none");
                list.Add(new ServerOperation { Name = Account, Title = Title(Account), State = happier == "running" || happier == "failed" ? "waiting" : "running", Step = "подключаю ключ к Happier на сервере" });
            }
            return list;
        }
        static string Elapsed(int seconds) { return seconds < 60 ? "меньше минуты" : (seconds / 60) + " мин"; }
        // Observed facts only: stage k of n, current step and elapsed time; never an estimate.
        internal static string Line(ServerOperation o)
        {
            switch (o.State) {
                case "running":
                    if (o.Name == Account) return "⏳ " + o.Step;
                    return "⏳ " + (o.Stages > 0 ? "этап " + o.Stage + " из " + o.Stages + ": " : "") + (o.Step.Length > 0 ? o.Step : "выполняется") + ", прошло " + Elapsed(o.ElapsedSec);
                case "waiting": return "ожидает: установка Happier";
                case "finished": return "✓ готово";
                case "failed": return "✗ ошибка: " + (o.Reason.Length > 0 ? o.Reason : "причина в журнале сервера");
                default: return "ожидает запуска";
            }
        }
        internal static bool Active(IEnumerable<ServerOperation> list) { return list.Any(o => o.State != "finished" && o.State != "failed"); }
        // «Установка» is listed only while something runs/waits, or a failure still offers «Повторить».
        internal static bool Visible(IEnumerable<ServerOperation> list) { return list.Any(o => o.State != "finished"); }
        internal static string Tooltip(ICollection<ServerOperation> list)
        { return "Идёт установка: " + list.Count(o => o.State == "finished") + " из " + list.Count; }
        internal static void Save(string home, IEnumerable<string> tracked, Dictionary<string, object> operations, bool pendingAccount)
        {
            Json.Write(StatePath(home), new Dictionary<string, object> { { "schema", 1 }, { "updatedUtc", DateTime.UtcNow.ToString("o") },
                { "tracked", tracked.Distinct().ToArray() }, { "operations", operations ?? new Dictionary<string, object>() }, { "pendingAccount", pendingAccount } });
        }
        internal static Dictionary<string, object> Load(string home)
        { try { string p = StatePath(home); return File.Exists(p) ? Json.Read(p) : new Dictionary<string, object>(); } catch (Exception) { return new Dictionary<string, object>(); } }
        internal static List<ServerOperation> FromState(Dictionary<string, object> state)
        { return Parse(Json.Map(Json.Get(state, "operations")), Json.Strings(Json.Get(state, "tracked")), Json.Bool(state, "pendingAccount")); }
        internal static DateTime Updated(Dictionary<string, object> state)
        { DateTime t; return DateTime.TryParse(Json.Str(state, "updatedUtc"), null, System.Globalization.DateTimeStyles.RoundtripKind, out t) ? t.ToUniversalTime() : DateTime.MinValue; }
        // One wizard action without UI (tray): «Operation» is a single short status call, «ResumeAccount»
        // connects a saved key once Happier is installed. Budgets: WizardStep.Timeout.
        internal static Dictionary<string, object> Invoke(string home, string bundle, string action, object request, CancellationToken token)
        {
            string requestFile = Path.Combine(home, "state", "wizard-request-" + Guid.NewGuid().ToString("N") + ".json"), output = requestFile + ".out";
            try {
                Json.Write(requestFile, request);
                var args = new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", Path.Combine(bundle, "build", "Wizard.ps1"), "-Home", home, "-Action", action, "-RequestFile", requestFile };
                int code = External.Run(Files.Executable("powershell.exe"), args, bundle, output, WizardStep.Timeout(action), 4 * 1024 * 1024, token);
                var response = Json.Map(Json.Parse(Files.LF(External.ReadPowerShellOutput(output))));
                if (code != 0 || !Json.Bool(response, "ok")) throw new IOException(Json.Text(response, "reason", "Шаг не подтверждён"));
                return Json.Map(Json.Get(response, "result"));
            } finally { if (File.Exists(requestFile)) File.Delete(requestFile); if (File.Exists(output)) File.Delete(output); }
        }
    }
}
