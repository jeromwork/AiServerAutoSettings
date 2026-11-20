using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace RemoteAgents.Launcher
{
    // Same colour language as the tray icon: grey = off, green = ok, yellow = partial, red = no connection.
    internal enum Tone { Off, Ok, Warning, Error }

    // Raw facts for the main screen, gathered by the tray from the same fresh status/*.json files as the menu and tooltip.
    // No WinForms here: the model is covered by PortableTests.
    internal sealed class MainScreenFacts
    {
        internal Dictionary<string, object> Transport = new Dictionary<string, object>();  // status/transport.json (maxAge 15 s)
        internal Dictionary<string, object> Vpn = new Dictionary<string, object>();        // status/vpn.json (maxAge 15 s)
        internal Dictionary<string, object> Control = new Dictionary<string, object>();    // status/control.json (maxAge 30 s), the bridge
        internal Dictionary<string, object> Health = new Dictionary<string, object>();     // ServerHealthView.Read(home)
        internal Dictionary<string, object> Lan = new Dictionary<string, object>();
        internal bool VpnInstalled;          // a "vpn" component exists in the definition
        internal bool VpnWanted;             // profile.vpn.enabled / the user's intent
        internal bool VpnBusy;               // enable/disable is in progress (actionBusy around CheckVpn/DisableVpn)
        internal bool VpnDisableFailed;       // the last failed request was to disable, never offer to enable it
        internal string VpnError = "";       // last enable/disable failure in plain words, "" when none
        internal bool BridgeEnabled = true; // config bridge.enabled, independent of a stale heartbeat
        internal bool BridgeBusy;            // the Bridge wizard action is running
        internal string BridgeError = "";
        internal bool DiskEnabled;           // the "disk" component is enabled
        internal string DiskSummary = "";    // TrayContext disk summary, e.g. "Диск: синхронизирован" (DiskTraySession.Summary texts)
        internal int DiskFolders = -1;       // number of server folders, -1 = unknown
        internal int DiskServerOnly = -1;    // folders kept only on the server, -1 = unknown
        internal bool HappierVisible;        // HappierAccountModel.Visible
        internal bool HappierHasKey;         // HappierAccountModel.HasKey
        internal string HappierLabel = "";   // HappierAccountModel.Label
        internal bool HappierConfirmed;      // state/happier-account.json ok
        internal string HappierUrl = "";     // usable web address, "" when not configured
        internal string Operation = "";      // MutationConflict() text, "" when idle
    }

    internal sealed class CardView
    {
        internal string Title = "", State = "", Detail = "";
        internal Tone Tone;
        internal bool Visible = true;
        internal bool On, SwitchEnabled;
        internal string SwitchText = "";
    }

    internal sealed class VpnCardView
    {
        internal string Title = "VPN", State = "", Detail = "";
        internal Tone Tone;
        internal bool Visible = true;
        internal bool On;                    // switch position
        internal bool SwitchEnabled = true;  // false while busy or another operation runs
        internal string SwitchText = "";     // action text, or progress while a command runs
        internal string PathLink = "Авто ▾"; // the path chooser link text ("Авто ▾" or the pinned path title + " ▾")
    }

    internal sealed class BannerView
    {
        internal bool Visible;
        internal Tone Tone;
        internal string Text = "";           // plain words, no technical terms
        internal string ActionText = "";     // one button, "" when none
        internal string ActionId = "";       // "retry" | "vpn-on" | "open-disk" | "open-sync" | "details" | ""
    }

    internal sealed class MainScreenView
    {
        internal Tone Overall;               // must match the tray icon colour for the same facts
        internal BannerView Banner = new BannerView();
        internal VpnCardView Vpn = new VpnCardView();
        internal CardView Lan = new CardView { Title = "Локальные сети" };
        internal CardView Disk = new CardView { Title = "Диск" };
        internal CardView Happier = new CardView { Title = "Happier" };
        internal CardView Helper = new CardView { Title = "Помощник" };
    }

    internal static class MainScreenModel
    {
        internal static MainScreenView Build(MainScreenFacts facts)
        {
            facts = facts ?? new MainScreenFacts();
            var transport = facts.Transport ?? Json.Map(null);
            var vpn = facts.Vpn ?? Json.Map(null);
            var control = facts.Control ?? Json.Map(null);
            var view = new MainScreenView();
            // Keep this identical to TrayContext.Tick; a deliberately off VPN is grey in its card only.
            var phase = StatusView.Phase(transport);
            view.Overall = phase == LinkPhase.Ok ? Tone.Ok : phase == LinkPhase.Failed ? Tone.Error : Tone.Warning;
            if (TrayMenuModel.Searching(transport, vpn) || Json.Str(vpn, "state") == "conflict") view.Overall = Tone.Warning;
            BuildVpn(view.Vpn, facts, transport, vpn);
            BuildDisk(view.Disk, facts);
            var lan = facts.Lan ?? Json.Map(null);
            view.Lan.Visible = Json.Bool(lan, "enabled");
            var lanNetworks = Json.Array(Json.Get(lan, "networks")).Select(Json.Map).ToArray();
            view.Lan.State = string.Join("\r\n", lanNetworks.Select(n => Json.Str(n, "name") + ": " + Json.Str(n, "reason")));
            view.Lan.Detail = LanDetails(lan);
            view.Lan.Tone = LanTone(lanNetworks);
            view.Happier.Visible = facts.HappierVisible;
            view.Happier.State = facts.HappierConfirmed ? "аккаунт подключён"
                : facts.HappierHasKey || facts.HappierVisible ? "аккаунт не подтверждён" : "не настроен";
            view.Happier.Detail = OneLine(facts.HappierLabel);
            view.Happier.Tone = facts.HappierConfirmed ? Tone.Ok : facts.HappierVisible ? Tone.Warning : Tone.Off;
            view.Helper.Visible = true;
            view.Helper.On = facts.BridgeEnabled;
            view.Helper.SwitchEnabled = !facts.BridgeBusy && string.IsNullOrEmpty(facts.Operation);
            view.Helper.SwitchText = facts.BridgeBusy ? (facts.BridgeEnabled ? "Включается…" : "Выключается…")
                : "Удалённое управление: " + (facts.BridgeEnabled ? "вкл" : "выкл");
            view.Helper.Tone = !facts.BridgeEnabled ? Tone.Off : Json.Bool(control, "ok") ? Tone.Ok : Tone.Warning;
            string helperReason = HelperReason(control, transport);
            view.Helper.State = facts.BridgeBusy ? view.Helper.SwitchText
                : !facts.BridgeEnabled ? "Удалённое управление выключено"
                : "Помощник может управлять компьютером: " + (Json.Bool(control, "ok") ? "подключён" : "нет связи — " + helperReason);
            if (facts.BridgeBusy) view.Helper.Tone = Tone.Warning;
            else if (!string.IsNullOrEmpty(facts.BridgeError)) {
                view.Helper.Detail = facts.BridgeError;
                view.Helper.Tone = Tone.Error;
            }

            string vpnError = VpnProblem(facts, vpn);
            if (vpnError.Length > 0)
                view.Banner = Json.Str(vpn, "state") == "conflict" && view.Vpn.On
                    ? Banner(Tone.Warning, vpnError, "Подробнее", "details")
                    : DisableFailed(facts, vpn)
                    ? Banner(Tone.Error, vpnError, "Подробнее", "details")
                    : Banner(Json.Str(vpn, "state") == "conflict" ? Tone.Warning : Tone.Error, vpnError.StartsWith("VPN выключен", StringComparison.Ordinal) ? vpnError : "Не удалось включить VPN. " + vpnError, "Включить снова", "vpn-on");
            else if (TrayMenuModel.Searching(transport, vpn))
                view.Banner = Banner(Tone.Warning, TrayMenuModel.SearchingText(transport, vpn), "", "");
            else if (phase == LinkPhase.Checking)
                view.Banner = Banner(Tone.Warning, Json.Str(transport, "phase") == "degraded"
                    ? "Связь нестабильна, ищу другой путь…" : "Проверяем связь с сервером…", "", "");
            else if (phase == LinkPhase.Failed)
                view.Banner = Banner(Tone.Error, "Нет связи с сервером. Проверьте подключение к интернету или повторите проверку.", "Повторить", "retry");
            else if (view.Disk.Visible && view.Disk.Tone == Tone.Error)
                view.Banner = Banner(Tone.Error, "Диск: " + view.Disk.State + ". Проверьте синхронизацию.", "Открыть синхронизацию", "open-sync");
            else if (!facts.BridgeBusy && !string.IsNullOrEmpty(facts.BridgeError))
                view.Banner = Banner(Tone.Error, facts.BridgeError, "Подробнее", "details");
            else if (view.Helper.Visible && facts.BridgeEnabled && !facts.BridgeBusy && !Json.Bool(control, "ok"))
                view.Banner = Banner(Tone.Warning, "Помощник не на связи: " + helperReason + ".", "Подробнее", "details");
            else if (view.Happier.Visible && !facts.HappierConfirmed)
                view.Banner = Banner(Tone.Warning, "Аккаунт Happier не подтверждён. Проверьте подключение аккаунта в настройках.", "Подробнее", "details");
            return view;
        }

        static BannerView Banner(Tone tone, string text, string actionText, string actionId)
        { return new BannerView { Visible = true, Tone = tone, Text = text, ActionText = actionText, ActionId = actionId }; }

        static void BuildVpn(VpnCardView card, MainScreenFacts facts, Dictionary<string, object> transport, Dictionary<string, object> vpn)
        {
            string state = Json.Str(vpn, "state");
            card.Visible = facts.VpnInstalled;
            card.On = facts.VpnBusy ? facts.VpnWanted : state == "on" || state == "searching" || Json.Bool(vpn, "enabled") && state != "stopping";
            bool starting = state == "starting" || state == "awaiting-uac";
            card.SwitchEnabled = !facts.VpnBusy && !starting && string.IsNullOrEmpty(facts.Operation);
            card.SwitchText = starting ? "Включается…" : facts.VpnBusy ? (facts.VpnWanted ? "Включается…" : "Выключается…") : card.On ? "Выключить VPN" : "Включить VPN";
            card.Tone = Tone.Warning;
            if (facts.VpnBusy) card.State = card.SwitchText;
            else if (VpnProblem(facts, vpn).Length > 0) { card.State = DisableFailed(facts, vpn) ? "Выключение VPN не подтверждено" : VpnProblem(facts, vpn); card.Tone = state == "conflict" ? Tone.Warning : Tone.Error; }
            else if (state == "stopping") card.State = "Выключается…";
            else if (state == "starting" || state == "awaiting-uac")
                card.State = state == "awaiting-uac" ? "Ожидается разрешение на включение" : "Включается…";
            else if (state == "off") { card.State = "VPN выключен"; card.Tone = Tone.Off; }
            else if (card.On && TrayMenuModel.Searching(transport, vpn))
                card.State = "VPN включён · " + (Json.Str(transport, "localNet") == "down" ? "нет интернета у вас (сеть)" : "нет связи, ищу путь");
            else if (vpn.Count == 0 || StatusView.Phase(transport) == LinkPhase.Checking) card.State = "Ожидается проверка";
            else if (StatusView.Phase(transport) == LinkPhase.Failed) { card.State = "Нет связи с сервером"; card.Tone = Tone.Error; }
            else if (Json.Bool(vpn, "ok") && state == "on") { card.State = "Защита включена"; card.Tone = Tone.Ok; }
            else card.State = card.On ? "Защита ещё не подтверждена" : "Ожидается проверка";

            var candidates = StatusView.Candidates(transport);
            var active = candidates.FirstOrDefault(c => Json.Str(c, "tag") == Json.Str(transport, "active")) ?? Json.Map(null);
            string metric = Latency(active);
            if (metric.Length == 0) metric = Latency(transport);
            if (metric.Length == 0) metric = StatusView.Speed(transport);
            bool hasPath = Json.Str(transport, "active").Length > 0 || Json.Str(transport, "title").Length > 0;
            card.Detail = hasPath ? "через «" + OneLine(TrayMenuModel.ActiveTitle(transport)) + "», " + metric : metric;
            if (card.On && TrayMenuModel.Searching(transport, vpn)) card.Detail = TrayMenuModel.SearchingText(transport, vpn);
            string dns = VpnStatus.DnsSummary(vpn);
            if (dns.Length > 0) {
                card.Detail += " · " + OneLine(dns);
                if (state == "on" && card.Tone == Tone.Ok) card.Tone = Tone.Warning;
            }
            string pinned = Json.Str(transport, "pinnedTag");
            if (pinned.Length > 0 && Json.Str(transport, "mode") != "auto") {
                var path = candidates.FirstOrDefault(c => Json.Str(c, "tag") == pinned)
                    ?? new Dictionary<string, object> { { "tag", pinned } };
                card.PathLink = OneLine(TrayMenuModel.PathTitle(path)) + " ▾";
            }
        }

        static string Latency(Dictionary<string, object> data)
        {
            // Prefer the active candidate's first-byte latency; tolerate older status files and missing measurements.
            foreach (string key in new[] { "latencyMs", "rttMs", "pingMs", "delayMs", "latency" }) {
                double value;
                if (double.TryParse(Json.Str(data, key), NumberStyles.Float, CultureInfo.InvariantCulture, out value)
                    && !double.IsNaN(value) && !double.IsInfinity(value) && value >= 0)
                    return value.ToString("0.#", CultureInfo.CurrentCulture) + " мс";
            }
            return "";
        }

        static void BuildDisk(CardView card, MainScreenFacts facts)
        {
            card.Visible = true;
            string state = OneLine(facts.DiskSummary);
            if (state.StartsWith("Диск: ", StringComparison.OrdinalIgnoreCase)) state = state.Substring(6);
            // Rates belong to the tray's live summary; the card keeps just one state and folder counts.
            int rates = state.IndexOf(" · ↓", StringComparison.Ordinal);
            if (rates >= 0) state = state.Substring(0, rates);
            // Папки, снятые сервером, не ошибка: состояние остаётся прежним, а карточка говорит о них в подписи.
            string removed = "";
            int note = state.IndexOf(" · удал", StringComparison.Ordinal);
            if (note >= 0) { removed = state.Substring(note + 3); state = state.Substring(0, note); }
            card.Tone = Tone.Warning;
            if (!facts.DiskEnabled) { state = "отключён"; card.Tone = Tone.Off; }
            else if (state.Length == 0) state = "ожидается проверка";
            // Ошибка одной папки не делает весь Диск ошибкой: карточка предупреждает, баннер не показывается.
            else if (state.StartsWith("Диск работает; ", StringComparison.Ordinal)) state = state.Substring(5);
            else if (state.IndexOf("ошиб", StringComparison.OrdinalIgnoreCase) >= 0 || state == "локальный Syncthing недоступен") {
                if (state == "локальный Syncthing недоступен") state = "служба синхронизации недоступна";
                card.Tone = Tone.Error;
            }
            else if (state == "синхронизирован") { state = "всё синхронизировано"; card.Tone = Tone.Ok; }
            else if (state.StartsWith("синхронизация", StringComparison.Ordinal)) state = "идёт " + state;
            else if (state == "сервер не подключён") state = StatusView.Phase(facts.Transport ?? Json.Map(null)) == LinkPhase.Checking ? "ожидается проверка связи" : "нет связи с сервером";
            else if (state == "проверка файлов") state = "проверяются файлы";
            else if (state == "состояние не получено" || state == "состояние уточняется") state = "ожидается проверка";
            else if (state == "отключён") card.Tone = Tone.Off;
            card.State = state;
            if (facts.DiskFolders >= 0 && facts.DiskServerOnly >= 0)
                card.Detail = facts.DiskFolders.ToString(CultureInfo.InvariantCulture) + " " + FolderWord(facts.DiskFolders)
                    + " · " + facts.DiskServerOnly.ToString(CultureInfo.InvariantCulture) + " только на сервере";
            if (removed.Length > 0) card.Detail = (card.Detail.Length > 0 ? card.Detail + " · " : "") + removed + ", локальная копия сохранена";
        }

        static string FolderWord(int count)
        {
            int last = count % 10, lastTwo = count % 100;
            return lastTwo >= 11 && lastTwo <= 14 ? "папок" : last == 1 ? "папка" : last >= 2 && last <= 4 ? "папки" : "папок";
        }

        internal static Tone LanTone(Dictionary<string, object>[] networks)
        {
            if (networks.Length > 0 && networks.All(n => Json.Str(n, "state") == "ok" && Json.Str(n, "stage").Length == 0)) return Tone.Ok;
            // A fresh failure or an unreachable host is red; starting, link checks and conflicts are yellow.
            if (networks.Any(n => Json.Str(n, "state") == "failed" || Json.Str(n, "state") == "host-down")) return Tone.Error;
            return Tone.Warning;
        }

        internal static string LanDetails(Dictionary<string, object> lan)
        {
            return CleanSecrets(string.Join("\r\n\r\n", Json.Array(Json.Get(lan, "networks")).Select(Json.Map).Select(n =>
                Json.Str(n, "name") + "\r\nПодсети: " + string.Join(", ", Json.Strings(Json.Get(n, "connectedSubnets") ?? Json.Get(n, "subnets"))) +
                "\r\nИсключены: " + string.Join("; ", Json.Array(Json.Get(n, "excludedSubnets")).Select(Json.Map).Select(s => Json.Str(s, "subnet") + " — " + Json.Str(s, "adapter"))) +
                "\r\nDNS: " + string.Join(", ", Json.Strings(Json.Get(n, "dnsServers"))) + "\r\nДомены: " + string.Join(", ", Json.Strings(Json.Get(n, "domains"))) +
                "\r\nИмена: " + (Json.Bool(n, "nrptOk") ? "настроены" : "не настроены") + "\r\nПоследняя ошибка: " + LanStages.Text(Json.Str(n, "stage")))));
        }
        static string HelperReason(Dictionary<string, object> control, Dictionary<string, object> transport)
        {
            if (control.Count == 0) return "ожидается проверка";
            if (StatusView.Phase(transport) == LinkPhase.Failed) return "нет связи с сервером";
            if (transport.Count > 0 && StatusView.Phase(transport) == LinkPhase.Checking) return "проверяем связь с сервером";
            string summary = Json.Str(control, "summary");
            if (summary == "Управление выключено") return "управление выключено";
            if (summary == "Управление: нет данных") return "ожидается проверка управления";
            string reason = Json.Text(control, "error", Json.Str(control, "reason"));
            if (reason.Length > 0) return PlainReason(reason, "не удалось подключиться, проверьте настройки помощника");
            return Json.Bool(control, "processAlive") ? "сервер ещё не подтвердил подключение" : "помощник не запущен";
        }

        static bool DisableFailed(MainScreenFacts facts, Dictionary<string, object> vpn)
        { return facts.VpnDisableFailed || Json.Str(vpn, "state") == "rollback-error"; }

        static string VpnProblem(MainScreenFacts facts, Dictionary<string, object> vpn)
        {
            if (!string.IsNullOrWhiteSpace(facts.VpnError))
                return PlainReason(facts.VpnError, "Проверьте настройки и разрешение на включение.");
            string reason = Json.Str(vpn, "owner") == "net-helper" ? Json.Str(vpn, "summary") : "";
            if (reason.Length == 0) reason = VpnWatchdog.FailureSummary(Json.Str(vpn, "state"), Json.Str(vpn, "stage"));
            if (Json.Str(vpn, "state") == "searching" || Json.Str(vpn, "state") == "on" || Json.Str(vpn, "state") == "off" || Json.Str(vpn, "state") == "starting") reason = "";
            if (reason.Length > 0) return StatusView.DisplayText(reason);
            switch (Json.Str(vpn, "state")) {
                case "conflict": return "Работает другой VPN. Отключите его перед включением этого VPN.";
                case "error": return "Проверьте настройки и разрешение на включение.";
                case "rollback-error": return "Не удалось подтвердить выключение. Проверьте состояние подключения.";
                case "rolled-back": return "Защита автоматически выключена: проверка подключения не прошла.";
                default: return "";
            }
        }

        static string PlainReason(string value, string fallback)
        {
            value = OneLine(CleanSecrets(value));
            return Regex.IsMatch(value, @"transport|\btag\b|sing-box|\bREST\b|\bJSON\b|\bTUN\b|\bUAC\b", RegexOptions.IgnoreCase) ? fallback : value;
        }

        static string OneLine(string value)
        { return Regex.Replace(value ?? "", @"[\r\n]+", " ").Trim(); }

        // Plain-text diagnostics for «Скопировать отчёт»: statuses, paths, versions — never keys, passwords or tokens.
        internal static string Report(MainScreenFacts facts, string technical)
        {
            facts = facts ?? new MainScreenFacts();
            var view = Build(facts);
            var transport = facts.Transport ?? Json.Map(null);
            var report = new StringBuilder();
            if (!string.IsNullOrWhiteSpace(technical)) report.AppendLine(technical);
            report.AppendLine(TrayMenuModel.Connection(transport));
            AppendCard(report, view.Vpn.Title, view.Vpn.State, view.Vpn.Detail, view.Vpn.Visible);
            string dns = VpnStatus.DnsDetail(facts.Vpn ?? Json.Map(null));
            if (view.Vpn.Visible && dns.Length > 0) report.AppendLine(dns);
            AppendCard(report, view.Lan.Title, view.Lan.State, view.Lan.Detail, view.Lan.Visible);
            AppendCard(report, view.Disk.Title, view.Disk.State, view.Disk.Detail, view.Disk.Visible);
            AppendCard(report, view.Happier.Title, view.Happier.State, view.Happier.Detail, view.Happier.Visible);
            if (view.Helper.Visible) report.AppendLine(view.Helper.State);
            report.AppendLine("Сообщение: " + (view.Banner.Visible ? view.Banner.Text : "нет проблем"));
            report.AppendLine("Пути:");
            foreach (var candidate in StatusView.Candidates(transport))
                report.AppendLine("  " + TrayMenuModel.CandidateLine(candidate, transport));
            var switches = TrayMenuModel.SwitchLines(transport);
            if (switches.Length > 0) {
                report.AppendLine("Последние переключения:");
                foreach (string change in switches) report.AppendLine("  " + change);
            }
            report.AppendLine(ServerHealthView.Detail(facts.Health ?? Json.Map(null)));
            // Clean the complete result: labels, path names and server errors are also untrusted text.
            return CleanSecrets(report.ToString());
        }

        static void AppendCard(StringBuilder report, string title, string state, string detail, bool visible)
        {
            if (visible) report.AppendLine(title + ": " + state + (detail.Length > 0 ? " · " + detail : ""));
        }

        internal static string CleanSecrets(string value)
        { return StatusText.CleanSecrets(value); }
    }
}
