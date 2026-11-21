using System;
using System.Collections.Generic;

namespace RemoteAgents.Launcher
{
    [Flags]
    internal enum SearchTransition { None = 0, Started = 1, Shown = 2, Ended = 4 }

    // Pure state machine: the tray supplies monotonic time on its existing tick.tray event.
    internal sealed class SearchQuieter
    {
        // §4а: порог только для отображения, не подтверждение связи; существующий tick.tray,
        // без нового таймера. Позже порог можно сделать адаптивным.
        internal const int SearchShowAfterMs = 30000;
        bool searching;
        long startedAt;
        internal bool ShowSearching { get; private set; }
        internal long DurationMs { get; private set; }

        internal SearchTransition Observe(bool isSearching, long nowMs)
        {
            if (!isSearching) {
                if (!searching) return SearchTransition.None;
                DurationMs = Math.Max(0, nowMs - startedAt);
                searching = ShowSearching = false;
                return SearchTransition.Ended;
            }
            var transition = SearchTransition.None;
            if (!searching) {
                searching = true; startedAt = nowMs;
                transition = SearchTransition.Started;
            }
            DurationMs = Math.Max(0, nowMs - startedAt);
            if (!ShowSearching && DurationMs >= SearchShowAfterMs) {
                ShowSearching = true;
                transition |= SearchTransition.Shown;
            }
            return transition;
        }
    }

    // Presentation facts only: raw heartbeat/diagnostics and VPN control decisions stay untouched.
    // Memory is bounded to one previous connected pair, owned by TrayContext.
    internal sealed class SearchPresentation
    {
        internal readonly Dictionary<string, object> Transport, Vpn;
        internal SearchPresentation(Dictionary<string, object> transport, Dictionary<string, object> vpn)
        { Transport = transport ?? Json.Map(null); Vpn = vpn ?? Json.Map(null); }

        // The tray uses this presentation for its tooltip as well as its colour and menu.
        internal string Tooltip(Dictionary<string, object> health)
        {
            string failure = VpnFailureText(Vpn);
            return failure.Length > 0 ? TrayMenuModel.Short(failure, 63) : TrayMenuModel.Tooltip(Transport, health, Vpn);
        }

        internal static string VpnFailureText(Dictionary<string, object> vpn)
        {
            string state = Json.Str(vpn, "state");
            if (state == "searching" || state == "conflict") return "";
            string reason = VpnWatchdog.FailureSummary(state, Json.Str(vpn, "stage"));
            if (state == "rolled-back") reason = "Защита автоматически выключена: проверка подключения не прошла.";
            if (reason.Length == 0) return "";
            return StatusView.DisplayText(Json.Str(vpn, "owner") == "net-helper" ? Json.Text(vpn, "summary", reason) : reason);
        }

        internal static SearchPresentation Build(Dictionary<string, object> transport, Dictionary<string, object> vpn,
            bool showSearching, SearchPresentation connected = null)
        {
            var view = new SearchPresentation(transport, vpn);
            if (showSearching || !TrayMenuModel.Searching(view.Transport, view.Vpn) ||
                VpnFailureText(view.Vpn).Length > 0 || Json.Str(view.Vpn, "state") == "conflict") return view;
            transport = view.Transport; vpn = view.Vpn;
            bool wasConnected = connected != null && StatusView.Phase(connected.Transport) == LinkPhase.Ok;
            bool wasProtected = wasConnected && Json.Str(connected.Vpn, "state") == "on" && Json.Bool(connected.Vpn, "ok");
            // A short dip may retain verified success, but cannot create it at startup.
            if (StatusView.Phase(transport) == LinkPhase.Searching ||
                Json.Str(vpn, "state") == "searching" && StatusView.Phase(transport) == LinkPhase.Checking) {
                transport = new Dictionary<string, object>(wasConnected ? connected.Transport : transport);
                transport["phase"] = wasConnected ? "ok" : "checking"; transport["ok"] = wasConnected;
                transport.Remove("localNet"); transport.Remove("reason");
                if (!wasConnected) transport.Remove("checkingSince");
            }
            if (Json.Str(vpn, "state") == "searching") {
                // Keep current DNS policy, ownership, enabled flag and diagnostic fields.
                // Only the search-specific presentation is replaced with the previous proof or waiting.
                vpn = new Dictionary<string, object>(vpn);
                vpn["state"] = wasProtected ? "on" : "checking"; vpn["ok"] = wasProtected;
                vpn["summary"] = wasProtected ? "VPN включён" : "Ожидается проверка"; vpn.Remove("reason");
            }
            return new SearchPresentation(transport, vpn);
        }
    }
}
