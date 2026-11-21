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
            ShortDips(); LongDip(); RepeatedDips(); Presentations(); Startup(); Priorities(); CurrentProtection();
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
        }
        static void Startup()
        {
            var search = Data("{\"phase\":\"searching\",\"ok\":false,\"localNet\":\"down\",\"checkingSince\":\"2000-01-01T00:00:00Z\"}");
            var vpn = Data("{\"state\":\"searching\",\"ok\":false,\"enabled\":true,\"reason\":{\"text\":\"Нет живого пути к серверу\"}}");
            var ok = Data("{\"phase\":\"ok\",\"ok\":true}");
            // No snapshot, an unconfirmed snapshot, and transport proof without VPN proof.
            foreach (var previous in new[] { null, new SearchPresentation(search, vpn),
                new SearchPresentation(ok, Data("{\"state\":\"on\",\"ok\":false}")) }) {
                foreach (var transport in new[] { search, ok }) {
                    string raw = Json.Encode(new { transport, vpn });
                    var link = SearchPresentation.Build(transport, vpn, false, previous);
                    var view = MainScreenModel.Build(Facts(transport, vpn, link));
                    Check(view.Overall == Tone.Warning && MainScreenModel.LinkTone(link.Transport, link.Vpn) == Tone.Warning &&
                        view.Vpn.Tone == Tone.Warning && view.Vpn.State != "Защита включена", "startup cannot claim successful protection");
                    Check(!Json.Bool(link.Vpn, "ok") && Json.Str(link.Vpn, "state") == "checking", "unconfirmed VPN waits neutrally");
                    if (previous == null || StatusView.Phase(previous.Transport) != LinkPhase.Ok) {
                        if (object.ReferenceEquals(transport, search))
                            Check(StatusView.Phase(link.Transport) == LinkPhase.Checking && !Json.Bool(link.Transport, "ok"), "startup transport cannot invent success");
                    }
                    Check(!TrayMenuModel.Searching(link.Transport, link.Vpn) && !view.Banner.Text.Contains("ищу путь") &&
                        !view.Vpn.State.Contains("ищу путь") && !link.Tooltip(Data("{}")).Contains("ищу путь") &&
                        !TrayMenuModel.Connection(link.Transport).Contains("ищу путь"), "startup delays only search wording across all surfaces");
                    Check(Json.Encode(new { transport, vpn }) == raw, "startup keeps raw facts unchanged");
                }
            }
            var on = Data("{\"state\":\"on\",\"ok\":true,\"enabled\":true}");
            var recovery = SearchPresentation.Build(ok, on, false);
            Check(MainScreenModel.Build(Facts(ok, on, recovery)).Vpn.Tone == Tone.Ok, "real success appears immediately");
            var shown = SearchPresentation.Build(search, vpn, true);
            Check(TrayMenuModel.Searching(shown.Transport, shown.Vpn) &&
                MainScreenModel.Build(Facts(search, vpn, shown)).Banner.Text == TrayMenuModel.SearchingText(search, vpn), "startup long search uses original wording");
        }
        static void Priorities()
        {
            var search = Data("{\"phase\":\"searching\",\"ok\":false}");
            var connected = new SearchPresentation(Data("{\"phase\":\"ok\",\"ok\":true}"),
                Data("{\"state\":\"on\",\"ok\":true,\"enabled\":true}"));
            foreach (string state in new[] { "off", "starting", "stopping", "conflict", "error", "core-exited", "rollback-error", "rolled-back",
                "server-unreachable", "network-changed", "resumed", "watchdog-stalled", "no-udp", "no-path", "uac-denied", "prepare-timeout" }) {
                foreach (bool show in new[] { false, true })
                foreach (var previous in new[] { null, connected }) {
                    var vpn = Data(Json.Encode(new { state, ok = false, enabled = true }));
                    string raw = Json.Encode(new { search, vpn });
                    var link = SearchPresentation.Build(search, vpn, show, previous);
                    Check(object.ReferenceEquals(link.Vpn, vpn), "preserve explicit VPN state: " + state);
                    var view = MainScreenModel.Build(Facts(search, vpn, link));
                    if (state == "conflict") {
                        Check(view.Overall == Tone.Warning && view.Vpn.Tone == Tone.Warning && view.Banner.Tone == Tone.Warning &&
                            link.Tooltip(Data("{}")) == TrayMenuModel.Short(TrayMenuModel.ConflictText(vpn), 63),
                            "conflict retains priority across surfaces");
                    } else if (state != "off" && state != "starting" && state != "stopping") {
                        Check(StatusView.Phase(link.Transport) == LinkPhase.Searching, "failure cannot turn transport into ok: " + state);
                        Check(view.Overall == Tone.Error && MainScreenModel.LinkTone(link.Transport, link.Vpn) == Tone.Error &&
                            view.Vpn.Tone == Tone.Error && view.Banner.Visible && view.Banner.Tone == Tone.Error, "failure is red on banner/card/window/tray: " + state);
                        SameView(view, MainScreenModel.Build(Facts(search, vpn)), "failure keeps original banner/card wording: " + state);
                        Check(link.Tooltip(Data("{}")) == TrayMenuModel.Short(SearchPresentation.VpnFailureText(vpn), 63) &&
                            !link.Tooltip(Data("{}")).Contains("ищу путь"), "failure outranks search in tooltip: " + state);
                        Check(TrayMenuModel.Connection(link.Transport) == TrayMenuModel.Connection(search), "failure keeps transport evidence in menu");
                    }
                    Check(Json.Encode(new { search, vpn }) == raw, "failure filtering keeps raw facts unchanged");
                }
            }
            var helperError = Data("{\"state\":\"error\",\"owner\":\"net-helper\",\"summary\":\"Ошибка маршрута. token=hidden-secret\"}");
            string tip = new SearchPresentation(search, helperError).Tooltip(Data("{}"));
            Check(tip.Contains("Ошибка маршрута") && !tip.Contains("hidden-secret"), "helper failure summary takes priority and masks secrets");
            var failed = Data("{\"phase\":\"failed\"}");
            Check(object.ReferenceEquals(SearchPresentation.Build(failed, Data("{\"state\":\"searching\"}"), false).Transport, failed),
                "explicit transport failure remains visible");
        }
        static void CurrentProtection()
        {
            var ok = Data("{\"phase\":\"ok\",\"ok\":true}");
            var on = Data("{\"state\":\"on\",\"enabled\":true,\"ok\":true,\"owner\":\"old-owner\",\"dnsPolicy\":{\"strictRoute\":true}}");
            var connected = new SearchPresentation(ok, on);
            foreach (bool strict in new[] { false, true }) {
                // Exercise both appearance and removal of a current protection warning.
                var vpn = Data(Json.Encode(new { state = "searching", enabled = true, ok = false, owner = "net-helper", stage = "current-stage",
                    error = "current-error", dnsPolicy = new { strictRoute = strict, networks = new[] { new { name = "Клиника" } } } }));
                string raw = Json.Encode(new { on, vpn });
                foreach (bool show in new[] { false, true }) {
                    var link = SearchPresentation.Build(Data("{\"phase\":\"searching\",\"ok\":false}"), vpn, show, connected);
                    var view = MainScreenModel.Build(Facts(link.Transport, vpn, link));
                    Check(object.ReferenceEquals(Json.Get(link.Vpn, "dnsPolicy"), Json.Get(vpn, "dnsPolicy")) &&
                        VpnStatus.DnsSummary(link.Vpn) == VpnStatus.DnsSummary(vpn) && VpnStatus.DnsDetail(link.Vpn) == VpnStatus.DnsDetail(vpn),
                        "short and long search retain current DNS policy");
                    Check(Json.Str(link.Vpn, "owner") == "net-helper" && Json.Str(link.Vpn, "stage") == "current-stage" &&
                        Json.Str(link.Vpn, "error") == "current-error" && Json.Bool(link.Vpn, "enabled"), "current ownership and diagnostics are retained");
                    Check(view.Vpn.Detail.Contains("DNS: защита частичная") == !strict &&
                        view.Vpn.Tone == (!strict || show ? Tone.Warning : Tone.Ok), "current DNS warning reaches card immediately");
                }
                Check(Json.Encode(new { on, vpn }) == raw, "DNS filtering leaves old and current diagnostic facts unchanged");
                on["dnsPolicy"] = Json.Get(vpn, "dnsPolicy");
            }
        }
    }
}
