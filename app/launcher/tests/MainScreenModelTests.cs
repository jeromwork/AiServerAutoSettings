using System;
using System.Collections.Generic;

namespace RemoteAgents.Launcher
{
    internal static class MainScreenModelTests
    {
        static int count;
        static void Check(bool condition, string name)
        { if (!condition) throw new Exception("Main screen: " + name); count++; }
        static Dictionary<string, object> Data(string json) { return Json.Map(Json.Parse(json)); }
        static MainScreenFacts Healthy()
        {
            return new MainScreenFacts {
                Transport = Data("{\"ok\":true,\"active\":\"primary\",\"mode\":\"auto\",\"kbps\":128,\"candidates\":[{\"tag\":\"primary\",\"title\":\"Основной\",\"state\":\"ok\",\"kbps\":128}]}"),
                Vpn = Data("{\"ok\":true,\"enabled\":true,\"state\":\"on\"}"),
                Control = Data("{\"ok\":true,\"processAlive\":true,\"summary\":\"Управление включено\"}"),
                VpnInstalled = true, VpnWanted = true, DiskEnabled = true, DiskSummary = "Диск: синхронизирован",
                DiskFolders = 12, DiskServerOnly = 3, HappierVisible = true, HappierHasKey = true,
                HappierConfirmed = true, HappierLabel = "Мой аккаунт", HappierUrl = "https://example.invalid"
            };
        }
        internal static void Run()
        {
            Colours(); Banners(); VpnCard(); DiskCard(); AccountsAndHelper(); Reports();
            Console.WriteLine("PASS: " + count + " main screen checks");
        }
        static void Colours()
        {
            // The expectations reproduce TrayContext.Tick, including inconsistent/partially known status files.
            foreach (bool vpnProduct in new[] { false, true })
                foreach (string transport in new[] { "{}", "{\"ok\":true}", "{\"ok\":false}", "{\"state\":\"starting\"}" })
                    foreach (string vpn in new[] { "{}", "{\"ok\":true,\"state\":\"on\"}", "{\"ok\":false,\"state\":\"on\"}", "{\"ok\":true,\"state\":\"off\"}" }) {
                        var facts = Healthy(); facts.IsVpnProduct = vpnProduct; facts.Transport = Data(transport); facts.Vpn = Data(vpn);
                        Tone expected = vpnProduct
                            ? (Json.Bool(facts.Vpn, "ok") && Json.Str(facts.Vpn, "state") == "on" ? Tone.Ok : Tone.Warning)
                            : (facts.Transport.Count == 0 ? Tone.Warning : Json.Bool(facts.Transport, "ok") ? Tone.Ok : Tone.Error);
                        Check(MainScreenModel.Build(facts).Overall == expected, "overall matches tray in both products");
                    }
            var off = Healthy(); off.IsVpnProduct = true; off.VpnWanted = false; off.Vpn = Data("{\"ok\":false,\"state\":\"off\"}");
            var view = MainScreenModel.Build(off);
            Check(view.Overall == Tone.Warning && view.Vpn.Tone == Tone.Off, "intentional off card is grey while RemoteVPN tray stays yellow");
            Check(!view.Disk.Visible && !view.Happier.Visible && !view.Helper.Visible && view.Vpn.Visible, "RemoteVPN hides other product cards");
            Check(MainScreenModel.Build(null).Overall == Tone.Warning, "absent facts wait for proof");
        }
        static void Banners()
        {
            var facts = Healthy();
            Check(!MainScreenModel.Build(facts).Banner.Visible, "healthy screen has no banner");
            facts.Transport = Data("{\"ok\":false}"); facts.Control = Data("{\"ok\":false}");
            var banner = MainScreenModel.Build(facts).Banner;
            Check(banner.Visible && banner.ActionId == "retry" && banner.Text.StartsWith("Нет связи с сервером"), "connection loss subsumes helper loss");
            Check(banner.Tone == Tone.Error && banner.ActionText == "Повторить", "connection error offers retry");
            facts.DiskSummary = "Диск: ошибка синхронизации"; facts.HappierConfirmed = false;
            Check(MainScreenModel.Build(facts).Banner.ActionId == "retry", "connection precedes disk, helper and account");
            facts.VpnError = "Не получено разрешение на включение";
            banner = MainScreenModel.Build(facts).Banner;
            Check(banner.ActionId == "vpn-on" && banner.ActionText == "Включить снова" && banner.Text.Contains(facts.VpnError), "VPN error has highest priority and includes plain reason");
            facts.Transport.Clear();
            Check(MainScreenModel.Build(facts).Banner.ActionId == "vpn-on", "VPN failure precedes pending connection too");
            facts.VpnError = "";
            banner = MainScreenModel.Build(facts).Banner;
            Check(banner.Tone == Tone.Warning && banner.Text == "Проверяем связь с сервером…" && banner.ActionId == "" && banner.ActionText == "", "empty or stale transport is a soft banner without a button");
            facts.Transport = Data("{\"ok\":true}");
            banner = MainScreenModel.Build(facts).Banner;
            Check(banner.ActionId == "open-sync" && banner.ActionText == "Открыть синхронизацию", "disk error precedes helper and account");
            facts.DiskSummary = "Диск: синхронизирован";
            banner = MainScreenModel.Build(facts).Banner;
            Check(banner.ActionId == "details" && banner.Text.StartsWith("Помощник"), "helper precedes account");
            facts.Control = Data("{\"ok\":true}");
            Check(MainScreenModel.Build(facts).Banner.Text.StartsWith("Аккаунт Happier"), "unconfirmed account is last priority");
            facts.IsVpnProduct = true;
            facts.DiskSummary = "Диск: ошибка синхронизации"; facts.Control = Data("{\"ok\":false}");
            Check(!MainScreenModel.Build(facts).Banner.Visible, "RemoteVPN does not show hidden feature warnings");
            facts.VpnError = "transport tag sing-box REST JSON";
            Check(!MainScreenModel.Build(facts).Banner.Text.Contains("transport"), "technical failure becomes a plain explanation");
            facts = Healthy(); facts.VpnInstalled = false; facts.Transport = Data("{\"ok\":false}");
            var view = MainScreenModel.Build(facts);
            Check(!view.Vpn.Visible && view.Banner.ActionId == "retry" && view.Overall == Tone.Error, "no installed VPN does not hide server loss");
            foreach (string state in new[] { "conflict", "error", "rollback-error", "rolled-back" }) {
                facts = Healthy(); facts.Vpn = Data("{\"ok\":false,\"state\":\"" + state + "\"}");
                Check(MainScreenModel.Build(facts).Banner.ActionId == "vpn-on", "saved VPN failure produces an actionable banner: " + state);
            }
        }
        static void VpnCard()
        {
            var facts = Healthy();
            var card = MainScreenModel.Build(facts).Vpn;
            Check(card.State == "Защита включена" && card.Tone == Tone.Ok && card.On, "confirmed protection is green and on");
            Check(card.Detail == "через «Основной», " + StatusView.Speed(facts.Transport), "speed from existing status model is the fallback");
            Check(card.PathLink == "Авто ▾", "automatic path link");
            facts.VpnBusy = true;
            card = MainScreenModel.Build(facts).Vpn;
            Check(!card.SwitchEnabled && card.SwitchText == "Включается…" && card.On, "busy enabling locks switch");
            facts.VpnWanted = false;
            card = MainScreenModel.Build(facts).Vpn;
            Check(!card.SwitchEnabled && card.SwitchText == "Выключается…" && !card.On, "busy disabling reflects intent before status catches up");
            facts.VpnBusy = false; facts.Operation = "применение настроек";
            Check(!MainScreenModel.Build(facts).Vpn.SwitchEnabled, "other mutation locks switch");
            facts.Operation = "";
            Check(MainScreenModel.Build(facts).Vpn.SwitchEnabled, "idle unlocks switch");
            facts.Vpn = Data("{\"ok\":false,\"enabled\":true,\"state\":\"starting\"}");
            Check(MainScreenModel.Build(facts).Vpn.On, "enabled status retains switch position when profile intent is catching up");
            facts.Vpn = Data("{\"ok\":true,\"enabled\":true,\"state\":\"on\"}");
            facts.Transport["pinnedTag"] = "primary"; facts.Transport["mode"] = "pinned";
            Check(MainScreenModel.Build(facts).Vpn.PathLink == "Основной ▾", "pinned link uses candidate title");
            facts.Transport["mode"] = "auto";
            Check(MainScreenModel.Build(facts).Vpn.PathLink == "Авто ▾", "auto mode wins over stale pin");
            facts.Transport["mode"] = "pinned"; facts.Transport["pinnedTag"] = "";
            Check(MainScreenModel.Build(facts).Vpn.PathLink == "Авто ▾", "empty pin means auto");
            facts.Transport["pinnedTag"] = "openssh-direct";
            Check(MainScreenModel.Build(facts).Vpn.PathLink == "SSH напрямую ▾", "missing pinned candidate uses existing path naming");
            facts.Transport["latencyMs"] = 42;
            Check(MainScreenModel.Build(facts).Vpn.Detail == "через «Основной», 42 мс", "explicit transport latency");
            var active = StatusView.Candidates(facts.Transport)[0]; active["rttMs"] = 17;
            Check(MainScreenModel.Build(facts).Vpn.Detail.EndsWith("17 мс"), "active candidate measurement wins");
            active["rttMs"] = -1; facts.Transport["latencyMs"] = "NaN";
            Check(MainScreenModel.Build(facts).Vpn.Detail.Contains("КБ/с"), "invalid latency falls back to speed");
            string longTitle = new string('Я', 300); active["title"] = longTitle; facts.Transport["pinnedTag"] = "primary";
            card = MainScreenModel.Build(facts).Vpn;
            Check(card.Detail.Contains(longTitle) && card.PathLink == longTitle + " ▾", "model preserves long Russian paths");
            facts.Vpn = Data("{\"ok\":false,\"state\":\"off\"}");
            Check(MainScreenModel.Build(facts).Vpn.State == "VPN выключен", "intentional off state");
            facts.Vpn.Clear();
            Check(MainScreenModel.Build(facts).Vpn.Tone == Tone.Warning && MainScreenModel.Build(facts).Vpn.State == "Ожидается проверка", "unknown VPN never claims success or intentional off");
            foreach (string state in new[] { "starting", "stopping", "awaiting-uac" }) {
                facts.Vpn = Data("{\"state\":\"" + state + "\"}");
                Check(MainScreenModel.Build(facts).Vpn.Tone == Tone.Warning, "VPN transition is pending: " + state);
            }
        }
        static void DiskCard()
        {
            var facts = Healthy();
            Check(MainScreenModel.Build(facts).Disk.Detail == "12 папок · 3 только на сервере", "folder and server-only counts");
            int[] numbers = { 0, 1, 2, 4, 5, 11, 12, 14, 21, 22, 25, 101, 111, 114 };
            string[] words = { "папок", "папка", "папки", "папки", "папок", "папок", "папок", "папок", "папка", "папки", "папок", "папка", "папок", "папок" };
            for (int i = 0; i < numbers.Length; i++) {
                facts.DiskFolders = numbers[i];
                Check(MainScreenModel.Build(facts).Disk.Detail.StartsWith(numbers[i] + " " + words[i] + " ·"), "Russian folder form " + numbers[i]);
            }
            facts.DiskFolders = -1;
            Check(MainScreenModel.Build(facts).Disk.Detail == "", "unknown folder count hides detail");
            facts.DiskFolders = 12; facts.DiskServerOnly = -1;
            Check(MainScreenModel.Build(facts).Disk.Detail == "", "unknown server-only count hides detail");
            string[] summaries = { "синхронизирован", "синхронизация 42%", "синхронизация", "ошибка синхронизации", "сервер не подключён",
                "нет выбранных папок", "есть папки на паузе", "есть локальные изменения", "проверка файлов", "состояние уточняется",
                "состояние не получено", "ожидается проверка", "локальный Syncthing недоступен", "отключён" };
            Tone[] tones = { Tone.Ok, Tone.Warning, Tone.Warning, Tone.Error, Tone.Warning, Tone.Warning, Tone.Warning, Tone.Warning,
                Tone.Warning, Tone.Warning, Tone.Warning, Tone.Warning, Tone.Error, Tone.Off };
            for (int i = 0; i < summaries.Length; i++) {
                facts.DiskSummary = "Диск: " + summaries[i] + " · ↓1 ↑2 КБ/с\r\n";
                var card = MainScreenModel.Build(facts).Disk;
                Check(card.Tone == tones[i] && !card.State.Contains("Диск:") && !card.State.Contains("КБ/с") && !card.State.Contains("\r"), "disk summary state and tone: " + summaries[i]);
            }
            facts.DiskSummary = "Диск: синхронизация 42%";
            Check(MainScreenModel.Build(facts).Disk.State == "идёт синхронизация 42%", "sync percent is preserved");
            facts.DiskEnabled = false; facts.DiskSummary = "Диск: синхронизирован";
            Check(MainScreenModel.Build(facts).Disk.State == "отключён" && MainScreenModel.Build(facts).Disk.Tone == Tone.Off, "disabled intent overrides old disk summary");
            facts.DiskEnabled = true;
            facts.DiskSummary = "Диск: ошибка " + new string('Я', 300) + " · попробуйте снова";
            Check(MainScreenModel.Build(facts).Disk.State == facts.DiskSummary.Substring(6), "long disk explanations are not truncated at punctuation");
            facts.DiskSummary = "";
            Check(MainScreenModel.Build(facts).Disk.State == "ожидается проверка", "empty disk waits for proof");
        }
        static void AccountsAndHelper()
        {
            var facts = Healthy(); var view = MainScreenModel.Build(facts);
            Check(view.Happier.State == "аккаунт подключён" && view.Happier.Detail == facts.HappierLabel && view.Happier.Tone == Tone.Ok, "confirmed Happier account");
            facts.HappierConfirmed = false;
            Check(MainScreenModel.Build(facts).Happier.State == "аккаунт не подтверждён", "key alone does not confirm account");
            facts.HappierHasKey = false;
            Check(MainScreenModel.Build(facts).Happier.State == "аккаунт не подтверждён", "shared account can be visible without recovery key");
            facts.HappierVisible = false;
            Check(MainScreenModel.Build(facts).Happier.State == "не настроен" && !MainScreenModel.Build(facts).Happier.Visible, "unconfigured Happier is hidden");
            Check(view.Helper.State == "Помощник может управлять компьютером: подключён", "verified control heartbeat means connected");
            facts.Control = Data("{\"ok\":false,\"processAlive\":true,\"summary\":\"Управление: нет связи\"}");
            Check(MainScreenModel.Build(facts).Helper.State.Contains("сервер ещё не подтвердил подключение"), "running process alone is not a connected helper");
            facts.Control = Data("{\"ok\":false,\"processAlive\":false,\"summary\":\"Управление выключено\"}");
            Check(MainScreenModel.Build(facts).Helper.State.Contains("управление выключено"), "monitor off summary is explained");
            facts.Control = Data("{\"ok\":false,\"summary\":\"Управление: нет данных\"}");
            Check(MainScreenModel.Build(facts).Helper.State.Contains("ожидается проверка управления"), "missing monitor data is pending");
            facts.Control.Clear();
            Check(MainScreenModel.Build(facts).Helper.State.Contains("ожидается проверка"), "empty control is pending");
            facts.Control = Data("{\"ok\":false,\"error\":\"Проверьте разрешение на управление компьютером\"}");
            Check(MainScreenModel.Build(facts).Helper.State.Contains("Проверьте разрешение"), "plain helper reason retained");
            facts.Control["error"] = "REST JSON transport";
            Check(!MainScreenModel.Build(facts).Helper.State.Contains("REST"), "technical helper reason translated");
        }
        static void Reports()
        {
            var facts = Healthy();
            string technical = "Продукт: RemoteAgents\r\nВерсия: 1.4.0\r\n" +
                "{\"key\":\"key-value\",\"token\":\"token-value\",\"password\":\"password-value\",\"secret\":\"secret-value\",\"apiKey\":\"api-value\",\"uuid\":\"uuid-value\",\"privateKey\":\"private-value\"}\r\n" +
                "TOKEN='single-quoted-value'\r\npassword=unquoted-value\r\n" +
                "{\"private_key\":{\"nested\":[\"nested-value\",{\"more\":\"nested-more\"}]},\"public\":\"retained\"}\r\n" +
                "https://login-name:login-pass@example.invalid/path?token=query-value&mode=auto\r\n" +
                "-----BEGIN OPENSSH PRIVATE KEY-----\r\npem-value\r\n-----END OPENSSH PRIVATE KEY-----\r\n";
            facts.Transport["candidates"] = new object[] { Data("{\"tag\":\"primary\",\"title\":\"Основной password=\\\"path-secret\\\"\",\"state\":\"ok\"}") };
            facts.HappierLabel = "apiKey=label-secret";
            facts.Health = Data("{\"summary\":\"token=health-secret\"}");
            string report = MainScreenModel.Report(facts, technical);
            foreach (string secret in new[] { "key-value", "token-value", "password-value", "secret-value", "api-value", "uuid-value", "private-value", "single-quoted-value", "unquoted-value", "nested-value", "nested-more", "login-name", "login-pass", "query-value", "pem-value", "path-secret", "label-secret", "health-secret" })
                Check(!report.Contains(secret), "report removes synthetic secret: " + secret);
            Check(report.Contains("Продукт: RemoteAgents\nВерсия: 1.4.0") && report.Contains("retained") && report.Contains("mode=auto"), "public diagnostics survive CRLF cleanup");
            Check(report.Contains("Защита включена") && report.Contains("всё синхронизировано") && report.Contains("аккаунт подключён") && report.Contains("Помощник может управлять компьютером"), "report includes card states");
            Check(report.Contains("Пути:") && report.Contains("работает · используется") && report.Contains("Сообщение: нет проблем"), "report includes candidate diagnostics and banner state");
            Check(report.Contains("Сервер:"), "report includes ServerHealthView.Detail");
            string cleaned = MainScreenModel.CleanSecrets("{\"apiKey\":\"escaped\\\"value\\\\tail\",\"public\":42}\r\nauthorization: Bearer auth-value\r\nvless://url-uuid@example.invalid:443");
            Check(!cleaned.Contains("escaped") && !cleaned.Contains("tail") && !cleaned.Contains("auth-value") && !cleaned.Contains("url-uuid") && cleaned.Contains("42"), "escaped values, authorization and other URL schemes are sanitized");
            Check(MainScreenModel.CleanSecrets("key=[\"array-value\",{\"child\":\"child-value\"}]\npublic=ok").EndsWith("public=ok"), "structured secret removed without eating following diagnostics");
            cleaned = MainScreenModel.CleanSecrets("https://token:part-one;part-two@example.invalid/path?%61piKey=query-one;query-two&mode=auto");
            Check(!cleaned.Contains("part-one") && !cleaned.Contains("part-two") && !cleaned.Contains("query-one") && !cleaned.Contains("query-two")
                && cleaned.Contains("example.invalid/path") && cleaned.Contains("mode=auto"), "URL is masked before field parsing, including encoded query names and semicolons");
            cleaned = MainScreenModel.CleanSecrets("password=first-part,second-part;third-part [fourth-part] & fifth-part\r\npublic=ok");
            Check(!cleaned.Contains("part") && cleaned.EndsWith("public=ok"), "unquoted credentials with punctuation are hidden through end of line");
            Check(MainScreenModel.CleanSecrets(null) == "", "null text is safe");
            Check(MainScreenModel.CleanSecrets("https:///path").Contains("path"), "URL without authority does not throw");
            facts = Healthy(); facts.VpnError = "Не получено разрешение";
            Check(MainScreenModel.Report(facts, "").Contains(MainScreenModel.Build(facts).Banner.Text), "active banner is included");
            facts.IsVpnProduct = true;
            report = MainScreenModel.Report(facts, "Продукт: RemoteVPN");
            Check(!report.Contains("Happier:") && !report.Contains("Помощник может") && !report.Contains("Диск:"), "RemoteVPN report follows visible product cards");
            string before = Json.Encode(facts.Transport); MainScreenModel.Build(facts); MainScreenModel.Report(facts, "");
            Check(Json.Encode(facts.Transport) == before, "presentation does not mutate input facts");
        }
    }
}
