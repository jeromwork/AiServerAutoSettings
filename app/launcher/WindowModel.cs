using System;
using System.Linq;
using System.Collections.Generic;

namespace RemoteAgents.Launcher
{
    internal enum WindowCommand { None, Show, Exit, Logs, Restart, Rollback, CheckUpdates, SetupCheck }
    internal enum WindowExit { Unload, ConfirmApplying }

    // Pure policy, shared by startup, IPC and the window; no WinForms or process state.
    internal sealed class WindowModel
    {
        internal bool Visible { get; private set; }
        internal bool HintShown { get; private set; }
        internal WindowModel(bool hintShown = false) { HintShown = hintShown; }
        internal static WindowCommand Route(string[] args)
        {
            if (args.Contains("--exit") || args.Contains("--uninstall")) return WindowCommand.Exit;
            if (args.Contains("--restart-components")) return WindowCommand.Restart;
            if (args.Contains("--rollback")) return WindowCommand.Rollback;
            if (args.Contains("--logs")) return WindowCommand.Logs;
            if (args.Contains("--check-updates")) return WindowCommand.CheckUpdates;
            if (ShouldShow(args)) return WindowCommand.Show;
            return args.Contains("--setup-check") ? WindowCommand.SetupCheck : WindowCommand.None;
        }
        internal static bool ShouldShow(string[] args)
        {
            if (args.Any(a => new[] { "--exit", "--uninstall", "--identify", "--install-stop", "--restart-components", "--rollback", "--logs", "--check-updates" }.Contains(a))) return false;
            if (args.Any(a => new[] { "--show", "--started", "--settings" }.Contains(a))) return true;
            return !args.Contains("--tray") && !args.Contains("--after-update") && !args.Contains("--setup-check");
        }
        internal static string[] ForwardArguments(string[] args)
        { return ShouldShow(args) && !args.Contains("--show") ? args.Concat(new[] { "--show" }).ToArray() : args; }
        internal void Show() { Visible = true; }
        internal bool CloseToTray()
        { Visible = false; bool notify = !HintShown; HintShown = true; return notify; }
        internal WindowExit Exit(bool applying) { return applying ? WindowExit.ConfirmApplying : WindowExit.Unload; }
        internal static bool CanOpen(string page, string operation)
        { return page == "Папки" || page == "Конфиг" || page == "Подробно" || page == "Сервис" || string.IsNullOrEmpty(operation); }
        internal const string SkippedFolders = "папки не выбраны — выберите в трее → Папки синхронизации";
        internal static List<string> SessionPlan(IEnumerable<string> plan, bool folderStepRequired, bool diskChosen)
        { return plan.Where(s => s != ConfigSections.Disk || !folderStepRequired && diskChosen).ToList(); }
        internal static bool CanFinish(bool running, IDictionary<string, SectionState> states)
        { return !running && states.Where(s => s.Key != ConfigSections.Disk).All(s => s.Value == SectionState.Done || s.Value == SectionState.Unchanged || s.Value == SectionState.Failed || s.Value == SectionState.Blocked); }
        internal static string Conflict(string operation)
        { return string.IsNullOrEmpty(operation) ? "" : "Идёт " + operation + ", подождите"; }
    }

    // Wait for two continuous minutes of fresh confirmed connectivity, then five minutes per attempt.
    internal sealed class ConfigSyncSchedule
    {
        DateTime? connectedSince; DateTime next = DateTime.MinValue;
        internal bool Due(bool connected, DateTime now, bool occupied)
        {
            if (!connected) { connectedSince = null; return false; }
            if (!connectedSince.HasValue) connectedSince = now;
            return !occupied && now >= connectedSince.Value.AddMinutes(2) && now >= next;
        }
        internal void Started(DateTime now) { next = now.AddMinutes(5); }
    }
}
