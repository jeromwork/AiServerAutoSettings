using System;
using System.Collections.Generic;

namespace RemoteAgents.Launcher
{
    // Manual observations and a fake monotonic clock: no waits, processes, network or timers.
    internal static class SearchQuieterTests
    {
        static int checks;
        static void Check(bool ok, string what)
        { if (!ok) throw new Exception("Search quieter: " + what); checks++; }
        static Dictionary<string, object> Data(string json) { return Json.Map(Json.Parse(json)); }
        sealed class Rig
        {
            internal long Now;
            internal readonly SearchQuieter Quiet = new SearchQuieter();
            internal SearchTransition Observe(bool searching, long now)
            { Now = now; return Quiet.Observe(searching, Now); }
        }
        static int Main()
        {
            ShortDips(); LongDip(); RepeatedDips(); Presentations(); Priorities();
            Console.WriteLine("PASS: " + checks + " SearchQuieter checks (fake clock)");
            return 0;
        }
        static void ShortDips()
        {
            foreach (long duration in new long[] { 2000, 29000 }) {
                var r = new Rig();
                Check(r.Observe(false, 0) == SearchTransition.None, "healthy startup is silent");
                Check(r.Observe(true, 1000) == SearchTransition.Started, "one start transition");
                Check(r.Observe(true, 1000 + duration) == SearchTransition.None && !r.Quiet.ShowSearching,
                    duration + " ms dip is hidden");
                Check(r.Observe(false, 1000 + duration) == SearchTransition.Ended && !r.Quiet.ShowSearching &&
                    r.Quiet.DurationMs == duration, "recovery resets immediately and records duration");
                Check(r.Observe(false, 1000 + duration) == SearchTransition.None, "no repeated end log");
            }
        }
        static void LongDip()
        {
            var r = new Rig();
            Check(r.Observe(true, 0) == SearchTransition.Started && !r.Quiet.ShowSearching, "zero is a valid start time");
            Check(r.Observe(true, 29999) == SearchTransition.None && !r.Quiet.ShowSearching, "hidden before boundary");
            Check(r.Observe(true, 30000) == SearchTransition.Shown && r.Quiet.ShowSearching &&
                r.Quiet.DurationMs == 30000, "shown exactly at boundary");
            Check(r.Observe(true, 31000) == SearchTransition.None && r.Quiet.ShowSearching, "31 seconds shown without another log");
            Check(r.Observe(true, 90000) == SearchTransition.None, "no repeated shown log");
            Check(r.Observe(false, 90000) == SearchTransition.Ended && !r.Quiet.ShowSearching &&
                r.Quiet.DurationMs == 90000, "shown search ends immediately");
            Check(r.Observe(true, 90000) == SearchTransition.Started && !r.Quiet.ShowSearching &&
                r.Quiet.DurationMs == 0, "new dip resets age at the same clock value");
            r = new Rig(); r.Observe(true, 0);
            Check(r.Observe(true, 31000) == SearchTransition.Shown, "late tick crosses threshold once");
        }
        static void RepeatedDips()
        {
            var r = new Rig();
            for (int i = 0; i < 20; i++) {
                long start = i * 30000L;
                Check(r.Observe(true, start) == SearchTransition.Started, "new independent dip");
                Check(r.Observe(true, start + 29000) == SearchTransition.None && !r.Quiet.ShowSearching, "short dips never accumulate");
                Check(r.Observe(false, start + 29000) == SearchTransition.Ended, "every recovery ends the interval");
            }
        }
        static MainScreenFacts Facts(Dictionary<string, object> transport, Dictionary<string, object> vpn, SearchPresentation link = null)
        {
            return new MainScreenFacts { Transport = transport, Vpn = vpn, SearchView = link, VpnInstalled = true,
                Control = Data("{\"ok\":true}"), DiskEnabled = true, DiskSummary = "Диск: синхронизирован" };
        }
        static void SameView(MainScreenView actual, MainScreenView expected, string what)
        {
            Check(actual.Overall == expected.Overall && actual.Banner.Visible == expected.Banner.Visible &&
                actual.Banner.Text == expected.Banner.Text && actual.Banner.Tone == expected.Banner.Tone &&
                actual.Banner.ActionId == expected.Banner.ActionId && actual.Vpn.State == expected.Vpn.State &&
                actual.Vpn.Detail == expected.Vpn.Detail && actual.Vpn.Tone == expected.Vpn.Tone &&
                actual.Vpn.On == expected.Vpn.On && actual.Vpn.SwitchEnabled == expected.Vpn.SwitchEnabled, what);
        }
        static void Presentations()
        {
            var ok = Data("{\"ok\":true,\"phase\":\"ok\",\"active\":\"primary\",\"title\":\"Основной\",\"kbps\":128}");
            var on = Data("{\"ok\":true,\"enabled\":true,\"state\":\"on\"}");
            var connected = new SearchPresentation(ok, on);
            var healthy = MainScreenModel.Build(Facts(ok, on));
            var empty = Data("{}");
            var epoch = new DateTime(2026, 11, 21, 0, 0, 0, DateTimeKind.Utc);
            // Both writers, either writer alone, and localNet=down all share the same threshold.
            for (int source = 0; source < 4; source++) {
                var transport = source == 1 ? ok : Data("{\"ok\":false,\"phase\":\"searching\",\"reason\":{\"text\":\"Нет живого пути к серверу\"}}");
                if (source == 3) transport["localNet"] = "down";
                var vpn = source == 0 || source == 3 ? on : Data("{\"state\":\"searching\",\"enabled\":true,\"ok\":false,\"reason\":{\"text\":\"Нет живого пути к серверу\"}}");
                string raw = Json.Encode(new { transport, vpn });
                var r = new Rig(); var notices = new TrayStatusNotifications();
                Check(notices.Observe(ok, on, epoch) == null, "healthy presentation has no balloon");
                foreach (long now in new long[] { 0, 2000, 29000 }) {
                    r.Observe(TrayMenuModel.Searching(transport, vpn), now);
                    var link = SearchPresentation.Build(transport, vpn, r.Quiet.ShowSearching, connected);
                    SameView(MainScreenModel.Build(Facts(transport, vpn, link)), healthy, "hidden search keeps banner/card/icon state and text");
                    Check(TrayMenuModel.Connection(link.Transport) == TrayMenuModel.Connection(ok) &&
                        TrayMenuModel.Tooltip(link.Transport, empty, link.Vpn) == TrayMenuModel.Tooltip(ok, empty, on), "menu/tooltip stay connected");
                    Check(notices.Observe(link.Transport, link.Vpn, epoch.AddMilliseconds(now)) == null, "hidden dip cannot notify");
                }
                Check(r.Observe(true, 31000) == SearchTransition.Shown, "31 second interval becomes visible");
                var shown = SearchPresentation.Build(transport, vpn, r.Quiet.ShowSearching, connected);
                Check(object.ReferenceEquals(shown.Transport, transport) && object.ReferenceEquals(shown.Vpn, vpn), "shown search uses original facts");
                SameView(MainScreenModel.Build(Facts(transport, vpn, shown)), MainScreenModel.Build(Facts(transport, vpn)), "shown banner/card/icon keep existing texts");
                Check(TrayMenuModel.Connection(shown.Transport) == TrayMenuModel.Connection(transport) &&
                    TrayMenuModel.Tooltip(shown.Transport, empty, shown.Vpn) == TrayMenuModel.Tooltip(transport, empty, vpn), "shown menu/tooltip keep existing texts");
                Check(notices.Observe(shown.Transport, shown.Vpn, epoch.AddMilliseconds(31000)) != null, "long search can notify");
                r.Observe(false, 31000);
                var recovered = SearchPresentation.Build(ok, on, r.Quiet.ShowSearching, connected);
                SameView(MainScreenModel.Build(Facts(ok, on, recovered)), healthy, "recovery restores all views immediately");
                Check(Json.Encode(new { transport, vpn }) == raw, "raw diagnostic facts remain unchanged");
            }
            // Startup has no saved connected snapshot, but the same calm presentation applies.
            var startup = SearchPresentation.Build(Data("{\"phase\":\"searching\"}"), Data("{\"state\":\"searching\"}"), false);
            var startupView = MainScreenModel.Build(Facts(startup.Transport, startup.Vpn));
            Check(startupView.Overall == Tone.Ok && startupView.Vpn.Tone == Tone.Ok && !startupView.Banner.Visible, "startup search waits for threshold too");
        }
        static void Priorities()
        {
            var search = Data("{\"phase\":\"searching\"}");
            foreach (string state in new[] { "off", "starting", "stopping", "conflict", "error", "rollback-error" }) {
                var vpn = Data(Json.Encode(new { state }));
                var link = SearchPresentation.Build(search, vpn, false);
                Check(object.ReferenceEquals(link.Vpn, vpn), "preserve explicit VPN state: " + state);
            }
            var failed = Data("{\"phase\":\"failed\"}");
            Check(object.ReferenceEquals(SearchPresentation.Build(failed, Data("{\"state\":\"searching\"}"), false).Transport, failed),
                "explicit transport failure remains visible");
        }
    }
}
