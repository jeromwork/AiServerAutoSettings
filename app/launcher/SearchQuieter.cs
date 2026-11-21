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

        internal static SearchPresentation Build(Dictionary<string, object> transport, Dictionary<string, object> vpn,
            bool showSearching, SearchPresentation connected = null)
        {
            var view = new SearchPresentation(transport, vpn);
            if (showSearching || !TrayMenuModel.Searching(view.Transport, view.Vpn)) return view;
            transport = view.Transport; vpn = view.Vpn;
            // During a short dip retain the last connected path/measurements. At startup there
            // is no previous sample: use a calm on/ok presentation until the threshold is met.
            if (StatusView.Phase(transport) == LinkPhase.Searching ||
                Json.Str(vpn, "state") == "searching" && StatusView.Phase(transport) == LinkPhase.Checking) {
                transport = new Dictionary<string, object>(connected == null ? transport : connected.Transport);
                transport["phase"] = "ok"; transport["ok"] = true;
                transport.Remove("localNet"); transport.Remove("reason");
            }
            if (Json.Str(vpn, "state") == "searching") {
                vpn = new Dictionary<string, object>(connected != null && Json.Str(connected.Vpn, "state") == "on" ? connected.Vpn : vpn);
                vpn["state"] = "on"; vpn["ok"] = true;
                vpn["summary"] = "VPN включён"; vpn.Remove("reason");
            }
            return new SearchPresentation(transport, vpn);
        }
    }
}
