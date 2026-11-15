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
        internal bool IsVpnProduct;                                                        // Product.IsVpn (RemoteVPN build)
        internal Dictionary<string, object> Transport = new Dictionary<string, object>();  // status/transport.json (maxAge 15 s)
        internal Dictionary<string, object> Vpn = new Dictionary<string, object>();        // status/vpn.json (maxAge 15 s)
        internal Dictionary<string, object> Control = new Dictionary<string, object>();    // status/control.json (maxAge 30 s), the bridge
        internal Dictionary<string, object> Health = new Dictionary<string, object>();     // ServerHealthView.Read(home)
        internal bool VpnInstalled;          // a "vpn" component exists in the definition
        internal bool VpnWanted;             // profile.vpn.enabled / the user's intent
        internal bool VpnBusy;               // enable/disable is in progress (actionBusy around CheckVpn/DisableVpn)
        internal bool VpnDisableFailed;       // the last failed request was to disable, never offer to enable it
        internal string VpnError = "";       // last enable/disable failure in plain words, "" when none
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
    }

    internal sealed class VpnCardView
    {
        internal string Title = "VPN", State = "", Detail = "";
        internal Tone Tone;
        internal bool Visible = true;
        internal bool On;                    // switch position
        internal bool SwitchEnabled = true;  // false while busy or another operation runs
        internal string SwitchText = "";     // "Вкл" / "Выкл" / "Включается…" / "Выключается…"
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
            view.Overall = facts.IsVpnProduct
                ? (Json.Bool(vpn, "ok") && Json.Str(vpn, "state") == "on" ? Tone.Ok : Tone.Warning)
                : (transport.Count == 0 ? Tone.Warning : Json.Bool(transport, "ok") ? Tone.Ok : Tone.Error);
            BuildVpn(view.Vpn, facts, transport, vpn);
            BuildDisk(view.Disk, facts);
            view.Happier.Visible = facts.HappierVisible && !facts.IsVpnProduct;
            view.Happier.State = facts.HappierConfirmed ? "аккаунт подключён"
                : facts.HappierHasKey || facts.HappierVisible ? "аккаунт не подтверждён" : "не настроен";
            view.Happier.Detail = OneLine(facts.HappierLabel);
            view.Happier.Tone = facts.HappierConfirmed ? Tone.Ok : facts.HappierVisible ? Tone.Warning : Tone.Off;
            view.Helper.Visible = !facts.IsVpnProduct;
            view.Helper.Tone = Json.Bool(control, "ok") ? Tone.Ok : Tone.Warning;
            string helperReason = HelperReason(control, transport);
            view.Helper.State = "Помощник может управлять компьютером: " +
                (Json.Bool(control, "ok") ? "подключён" : "нет связи — " + helperReason);

            string vpnError = VpnProblem(facts, vpn);
            if (vpnError.Length > 0)
                view.Banner = DisableFailed(facts, vpn)
                    ? Banner(Tone.Error, vpnError, "Подробнее", "details")
                    : Banner(Tone.Error, vpnError.StartsWith("VPN выключен", StringComparison.Ordinal) ? vpnError : "Не удалось включить VPN. " + vpnError, "Включить снова", "vpn-on");
            else if (transport.Count == 0)
                view.Banner = Banner(Tone.Warning, "Проверяем связь с сервером…", "", "");
            else if (!Json.Bool(transport, "ok"))
                view.Banner = Banner(Tone.Error, "Нет связи с сервером. Проверьте подключение к интернету или повторите проверку.", "Повторить", "retry");
            else if (view.Disk.Visible && view.Disk.Tone == Tone.Error)
                view.Banner = Banner(Tone.Error, "Диск: " + view.Disk.State + ". Проверьте синхронизацию.", "Открыть синхронизацию", "open-sync");
            else if (view.Helper.Visible && !Json.Bool(control, "ok"))
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
            card.Visible = facts.IsVpnProduct || facts.VpnInstalled;
            card.On = facts.VpnBusy ? facts.VpnWanted : state == "on" || Json.Bool(vpn, "enabled") && state != "stopping";
            bool starting = state == "starting" || state == "awaiting-uac";
            card.SwitchEnabled = !facts.VpnBusy && !starting && string.IsNullOrEmpty(facts.Operation);
            card.SwitchText = starting ? "Включается…" : facts.VpnBusy ? (facts.VpnWanted ? "Включается…" : "Выключается…") : card.On ? "Вкл" : "Выкл";
            card.Tone = Tone.Warning;
            if (facts.VpnBusy) card.State = card.SwitchText;
            else if (VpnProblem(facts, vpn).Length > 0) { card.State = DisableFailed(facts, vpn) ? "Выключение VPN не подтверждено" : VpnWatchdog.FailureSummary(state).Length > 0 ? VpnWatchdog.FailureSummary(state) : "VPN не включён"; card.Tone = Tone.Error; }
            else if (state == "stopping") card.State = "Выключается…";
            else if (state == "starting" || state == "awaiting-uac")
                card.State = state == "awaiting-uac" ? "Ожидается разрешение на включение" : "Включается…";
            else if (state == "off") { card.State = "VPN выключен"; card.Tone = Tone.Off; }
            else if (vpn.Count == 0 || transport.Count == 0) card.State = "Ожидается проверка";
            else if (!Json.Bool(transport, "ok")) { card.State = "Нет связи с сервером"; card.Tone = Tone.Error; }
            else if (Json.Bool(vpn, "ok") && state == "on") { card.State = "Защита включена"; card.Tone = Tone.Ok; }
            else card.State = card.On ? "Защита ещё не подтверждена" : "Ожидается проверка";

            var candidates = StatusView.Candidates(transport);
            var active = candidates.FirstOrDefault(c => Json.Str(c, "tag") == Json.Str(transport, "active")) ?? Json.Map(null);
            string metric = Latency(active);
            if (metric.Length == 0) metric = Latency(transport);
            if (metric.Length == 0) metric = StatusView.Speed(transport);
            bool hasPath = Json.Str(transport, "active").Length > 0 || Json.Str(transport, "title").Length > 0;
            card.Detail = hasPath ? "через «" + OneLine(TrayMenuModel.ActiveTitle(transport)) + "», " + metric : metric;
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
            // Current probes publish speed; accept explicit millisecond measurements when available.
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
            card.Visible = !facts.IsVpnProduct;
            string state = OneLine(facts.DiskSummary);
            if (state.StartsWith("Диск: ", StringComparison.OrdinalIgnoreCase)) state = state.Substring(6);
            // Rates belong to the tray's live summary; the card keeps just one state and folder counts.
            int rates = state.IndexOf(" · ↓", StringComparison.Ordinal);
            if (rates >= 0) state = state.Substring(0, rates);
            card.Tone = Tone.Warning;
            if (!facts.DiskEnabled) { state = "отключён"; card.Tone = Tone.Off; }
            else if (state.Length == 0) state = "ожидается проверка";
            else if (state.IndexOf("ошиб", StringComparison.OrdinalIgnoreCase) >= 0 || state == "локальный Syncthing недоступен") {
                if (state == "локальный Syncthing недоступен") state = "служба синхронизации недоступна";
                card.Tone = Tone.Error;
            }
            else if (state == "синхронизирован") { state = "всё синхронизировано"; card.Tone = Tone.Ok; }
            else if (state.StartsWith("синхронизация", StringComparison.Ordinal)) state = "идёт " + state;
            else if (state == "сервер не подключён") state = "нет связи с сервером";
            else if (state == "проверка файлов") state = "проверяются файлы";
            else if (state == "состояние не получено" || state == "состояние уточняется") state = "ожидается проверка";
            else if (state == "отключён") card.Tone = Tone.Off;
            card.State = state;
            if (facts.DiskFolders >= 0 && facts.DiskServerOnly >= 0)
                card.Detail = facts.DiskFolders.ToString(CultureInfo.InvariantCulture) + " " + FolderWord(facts.DiskFolders)
                    + " · " + facts.DiskServerOnly.ToString(CultureInfo.InvariantCulture) + " только на сервере";
        }

        static string FolderWord(int count)
        {
            int last = count % 10, lastTwo = count % 100;
            return lastTwo >= 11 && lastTwo <= 14 ? "папок" : last == 1 ? "папка" : last >= 2 && last <= 4 ? "папки" : "папок";
        }

        static string HelperReason(Dictionary<string, object> control, Dictionary<string, object> transport)
        {
            if (control.Count == 0) return "ожидается проверка";
            if (transport.Count > 0 && !Json.Bool(transport, "ok")) return "нет связи с сервером";
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
            string reason = VpnWatchdog.FailureSummary(Json.Str(vpn, "state"));
            if (reason.Length > 0) return reason;
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
            AppendCard(report, view.Disk.Title, view.Disk.State, view.Disk.Detail, view.Disk.Visible);
            AppendCard(report, view.Happier.Title, view.Happier.State, view.Happier.Detail, view.Happier.Visible);
            if (view.Helper.Visible) report.AppendLine(view.Helper.State);
            report.AppendLine("Сообщение: " + (view.Banner.Visible ? view.Banner.Text : "нет проблем"));
            report.AppendLine("Пути:");
            foreach (var candidate in StatusView.Candidates(transport))
                report.AppendLine("  " + TrayMenuModel.CandidateLine(candidate, transport));
            report.AppendLine(ServerHealthView.Detail(facts.Health ?? Json.Map(null)));
            // Clean the complete result: labels, path names and server errors are also untrusted text.
            return CleanSecrets(report.ToString());
        }

        static void AppendCard(StringBuilder report, string title, string state, string detail, bool visible)
        {
            if (visible) report.AppendLine(title + ": " + state + (detail.Length > 0 ? " · " + detail : ""));
        }

        static readonly Regex SecretField = new Regex(
            @"(?<name>[""']?[\w.-]*(?:key|token|password|passwd|secret|uuid|authorization)[\w.-]*[""']?\s*[:=]\s*)",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

        // Handles JSON fields, log-style key=value pairs, URL query credentials and multiline key material.
        // Redact entire structured values rather than exposing children of a secret object/array.
        internal static string CleanSecrets(string value)
        {
            value = (value ?? "").Replace("\r\n", "\n").Replace('\r', '\n');
            value = Regex.Replace(value, @"-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?(?:-----END [^-]*PRIVATE KEY-----|$)",
                "[скрыто]", RegexOptions.IgnoreCase);
            // Mask URLs first: a user name such as "token" must not be mistaken for a log field,
            // which could otherwise leave part of its password after a semicolon.
            value = Regex.Replace(value, @"\b[a-z][a-z0-9+.-]*://[^\s<>""']+", CleanUrl, RegexOptions.IgnoreCase);
            var clean = new StringBuilder();
            int position = 0;
            for (Match field = SecretField.Match(value); field.Success; field = SecretField.Match(value, position)) {
                clean.Append(value, position, field.Index - position);
                clean.Append(field.Groups["name"].Value).Append("\"[скрыто]\"");
                position = SecretValueEnd(value, field.Index + field.Length);
            }
            clean.Append(value, position, value.Length - position);
            return clean.ToString();
        }

        static string CleanUrl(Match match)
        {
            string url = match.Value;
            int authority = url.IndexOf("://", StringComparison.Ordinal) + 3;
            int end = url.IndexOfAny(new[] { '/', '?', '#' }, authority);
            if (end < 0) end = url.Length;
            if (end > authority) {
                int at = url.LastIndexOf('@', end - 1, end - authority);
                if (at >= authority) url = url.Substring(0, authority) + "[скрыто]@" + url.Substring(at + 1);
            }
            int query = url.IndexOf('?'), fragment = url.IndexOf('#');
            if (query < 0 || fragment >= 0 && fragment < query) return url;
            int queryEnd = fragment < 0 ? url.Length : fragment;
            string[] pairs = url.Substring(query + 1, queryEnd - query - 1).Split('&');
            for (int i = 0; i < pairs.Length; i++) {
                int equals = pairs[i].IndexOf('=');
                if (equals < 0) continue;
                string name = pairs[i].Substring(0, equals);
                // Encoded parameter names are just as sensitive as plain ones.
                try { name = Uri.UnescapeDataString(name); } catch (UriFormatException) { pairs[i] = "[скрыто]"; continue; }
                if (Regex.IsMatch(name, @"key|token|password|passwd|secret|uuid|authorization", RegexOptions.IgnoreCase))
                    pairs[i] = pairs[i].Substring(0, equals + 1) + "[скрыто]";
            }
            return url.Substring(0, query + 1) + string.Join("&", pairs) + url.Substring(queryEnd);
        }

        static int SecretValueEnd(string value, int start)
        {
            // An unquoted log value has no reliable punctuation delimiter: passwords can contain
            // commas, semicolons and brackets. Hide the rest of that line rather than guessing.
            if (start < value.Length && value[start] != '"' && value[start] != '\'' && value[start] != '{' && value[start] != '[') {
                int newline = value.IndexOf('\n', start);
                return newline < 0 ? value.Length : newline;
            }
            var closers = new Stack<char>();
            char quote = '\0';
            for (int i = start; i < value.Length; i++) {
                char ch = value[i];
                if (quote != '\0') {
                    if (ch == '\\') { i++; continue; }
                    if (ch == quote) { quote = '\0'; if (closers.Count == 0) return i + 1; }
                } else if (ch == '\"' || ch == '\'') quote = ch;
                else if (ch == '{' || ch == '[') closers.Push(ch == '{' ? '}' : ']');
                else if (closers.Count > 0 && ch == closers.Peek()) { closers.Pop(); if (closers.Count == 0) return i + 1; }
                else if (closers.Count == 0 && (ch == '\n' || ch == ',' || ch == ';' || ch == '&' || ch == '}' || ch == ']')) return i;
            }
            return value.Length;
        }
    }
}
