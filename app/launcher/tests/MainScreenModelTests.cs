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
            Colours(); Banners(); VpnCard(); DiskCard(); AccountsAndHelper(); Reports(); LinkPhases(); RenderGate();
            Console.WriteLine("PASS: " + count + " main screen checks");
        }
        static void LinkPhases()
        {
            string now = DateTime.UtcNow.AddSeconds(-5).ToString("o"), old = DateTime.UtcNow.AddSeconds(-600).ToString("o");
            var facts = Healthy();
            facts.Transport = Data("{\"ok\":false,\"phase\":\"checking\",\"checkingSince\":\"" + now + "\",\"error\":\"Запуск\"}");
            facts.Vpn = Data("{\"ok\":false,\"enabled\":false}");
            facts.Control = Data("{\"ok\":false}");
            facts.DiskSummary = "Диск: сервер не подключён";
            var view = MainScreenModel.Build(facts);
            Check(view.Overall == Tone.Warning, "initial connection check is yellow");
            Check(view.Banner.Tone == Tone.Warning && view.Banner.Text == "Проверяем связь с сервером…" && view.Banner.ActionId == "", "checking banner waits without retry");
            Check(view.Vpn.State == "Ожидается проверка" && view.Vpn.Tone != Tone.Error, "VPN waits for connection proof");
            Check(!view.Helper.State.Contains("нет связи с сервером") && view.Helper.State.Contains("проверяем связь с сервером"), "helper does not report a failure before the check");
            Check(view.Disk.State == "ожидается проверка связи" && view.Disk.Tone == Tone.Warning, "Disk waits for connection proof");
            Check(StatusView.Line("Связь", facts.Transport, true).StartsWith("⏳"), "transport diagnostics wait during first check");
            facts.Transport = Data("{\"ok\":false,\"phase\":\"checking\",\"checkingSince\":\"" + old + "\"}");
            view = MainScreenModel.Build(facts);
            Check(view.Overall == Tone.Error && view.Banner.ActionId == "retry", "hung connection check is red with retry");
            Check(StatusView.Line("Связь", facts.Transport, true).StartsWith("❌"), "hung check is a diagnostic failure");
            facts.Transport = Data("{\"ok\":false,\"phase\":\"failed\"}");
            view = MainScreenModel.Build(facts);
            Check(view.Overall == Tone.Error && view.Banner.ActionId == "retry" && view.Disk.State == "нет связи с сервером", "fresh failed check stays red and reaches Disk");
            Check(view.Vpn.Tone == Tone.Error && view.Helper.State.Contains("нет связи с сервером"), "fresh failure reaches VPN and helper");
            facts.Transport = Data("{\"ok\":false,\"phase\":\"stopped\"}");
            Check(MainScreenModel.Build(facts).Overall == Tone.Warning, "stopped transport waits neutrally");
            Check(StatusView.Line("Связь", facts.Transport, true).StartsWith("⏳"), "stopped diagnostics wait neutrally");
            facts.Transport = Data("{\"ok\":false}");
            Check(MainScreenModel.Build(facts).Overall == Tone.Warning, "legacy status without phase waits for proof");
            facts.Transport = Data("{\"ok\":true,\"phase\":\"ok\"}");
            Check(MainScreenModel.Build(facts).Overall == Tone.Ok, "confirmed connection stays green");
            Check(StatusView.Phase(Data("{}")) == LinkPhase.Checking && StatusView.Phase(null) == LinkPhase.Checking, "missing status waits for a check");
            Check(StatusView.Phase(Data("{\"ok\":false,\"phase\":\"checking\"}")) == LinkPhase.Checking, "check with missing timestamp waits");
            Check(StatusView.Phase(Data("{\"ok\":false,\"phase\":\"checking\",\"checkingSince\":\"invalid\"}")) == LinkPhase.Checking, "check with invalid timestamp waits");
            var since = DateTime.Parse(now, System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.RoundtripKind);
            var checking = Data("{\"ok\":false,\"phase\":\"checking\",\"checkingSince\":\"" + now + "\"}");
            Check(StatusView.Phase(checking, since.AddSeconds(StatusView.CheckingLimitSec)) == LinkPhase.Checking &&
                StatusView.Phase(checking, since.AddSeconds(StatusView.CheckingLimitSec + 1)) == LinkPhase.Failed, "checking timeout boundary");
            foreach (bool ok in new[] { false, true }) {
                foreach (string phase in new[] { "degraded", "future-phase" }) {
                    facts.Transport = Data(Json.Encode(new { ok = ok, phase = phase, checkingSince = now }));
                    view = MainScreenModel.Build(facts);
                    Check(view.Overall == Tone.Warning, phase + " is yellow even with a retained active path");
                    Check(StatusView.Line("Связь", facts.Transport, true).StartsWith("⏳"), phase + " diagnostics wait even with retained ok flag");
                    Check(view.Banner.Tone == Tone.Warning && view.Banner.ActionId == "" &&
                        view.Banner.Text == (phase == "degraded" ? "Связь нестабильна, ищу другой путь…" : "Проверяем связь с сервером…"), phase + " has a warning banner without retry");
                }
            }
            var degraded = Data(Json.Encode(new { ok = true, phase = "degraded", checkingSince = now }));
            Check(StatusView.Phase(degraded, since.AddSeconds(StatusView.CheckingLimitSec)) == LinkPhase.Checking &&
                StatusView.Phase(degraded, since.AddSeconds(StatusView.CheckingLimitSec + 1)) == LinkPhase.Failed, "degraded timeout boundary even when ok is retained");
            foreach (string stamp in new[] { "", "invalid" })
                Check(StatusView.Phase(Data(Json.Encode(new { phase = "degraded", checkingSince = stamp }))) == LinkPhase.Checking, "degraded tolerates absent or invalid timestamp");
            Check(StatusView.Phase(Data("{\"ok\":true,\"phase\":\"failed\"}")) == LinkPhase.Failed, "explicit failure wins over retained ok flag");
        }
        static void Colours()
        {
            // The expectations reproduce TrayContext.Tick, including inconsistent/partially known status files.
                foreach (string transport in new[] { "{}", "{\"ok\":true}", "{\"ok\":false}", "{\"state\":\"starting\"}" })
                    foreach (string vpn in new[] { "{}", "{\"ok\":true,\"state\":\"on\"}", "{\"ok\":false,\"state\":\"on\"}", "{\"ok\":true,\"state\":\"off\"}" }) {
                        var facts = Healthy(); facts.Transport = Data(transport); facts.Vpn = Data(vpn);
                        Tone expected = Json.Bool(facts.Transport, "ok") ? Tone.Ok : Tone.Warning;
                        Check(MainScreenModel.Build(facts).Overall == expected, "overall matches tray");
                    }
            Check(MainScreenModel.Build(null).Overall == Tone.Warning, "absent facts wait for proof");
        }
        static void Banners()
        {
            var facts = Healthy();
            Check(!MainScreenModel.Build(facts).Banner.Visible, "healthy screen has no banner");
            facts.Transport = Data("{\"ok\":false,\"phase\":\"failed\"}"); facts.Control = Data("{\"ok\":false}");
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
            facts.VpnDisableFailed = true; facts.VpnError = "Выключение ещё не подтверждено.";
            var failedDisable = MainScreenModel.Build(facts);
            Check(failedDisable.Banner.ActionId == "details" && !failedDisable.Banner.Text.Contains("включить"), "failed disable never offers to enable VPN");
            Check(failedDisable.Vpn.State == "Выключение VPN не подтверждено", "failed disable keeps its own card state");
            facts.VpnDisableFailed = false; facts.VpnError = "";
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
            facts.VpnError = "transport tag sing-box REST JSON";
            Check(!MainScreenModel.Build(facts).Banner.Text.Contains("transport"), "technical failure becomes a plain explanation");
            facts = Healthy(); facts.VpnInstalled = false; facts.Transport = Data("{\"ok\":false,\"phase\":\"failed\"}");
            var view = MainScreenModel.Build(facts);
            Check(!view.Vpn.Visible && view.Banner.ActionId == "retry" && view.Overall == Tone.Error, "no installed VPN does not hide server loss");
            foreach (string state in new[] { "conflict", "error", "rolled-back" }) {
                facts = Healthy(); facts.Vpn = Data("{\"ok\":false,\"state\":\"" + state + "\"}");
                Check(MainScreenModel.Build(facts).Banner.ActionId == "vpn-on", "saved VPN failure produces an actionable banner: " + state);
            }
            facts = Healthy(); facts.Vpn = Data("{\"ok\":false,\"state\":\"rollback-error\"}");
            var rollback = MainScreenModel.Build(facts);
            Check(rollback.Banner.ActionId == "details" && rollback.Vpn.State == "Выключение VPN не подтверждено", "failed rollback never offers to enable VPN");
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
            var active = StatusView.Candidates(facts.Transport)[0]; active["latencyMs"] = 25; active["rttMs"] = 17;
            Check(MainScreenModel.Build(facts).Vpn.Detail.EndsWith("25 мс"), "active latencyMs wins over other and transport measurements");
            active.Remove("latencyMs");
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
            facts.DiskSummary = "Диск работает; ошибка в папке Альфа: folder path missing";
            var folderError = MainScreenModel.Build(facts);
            Check(folderError.Disk.State == "работает; ошибка в папке Альфа: folder path missing" && folderError.Disk.Tone == Tone.Warning && !folderError.Banner.Visible, "an error of one folder is a warning on the card, not an error of the Disk and not a banner");
            facts.DiskSummary = "Диск: синхронизирован · удалена на сервере: Бета · ↓1 ↑2 КБ/с";
            var removedCard = MainScreenModel.Build(facts).Disk;
            Check(removedCard.State == "всё синхронизировано" && removedCard.Tone == Tone.Ok && removedCard.Detail == "удалена на сервере: Бета, локальная копия сохранена", "a folder removed on the server is a note, not an error");
            facts.DiskSummary = "Диск: папки удалены на сервере, локальные копии сохранены";
            Check(MainScreenModel.Build(facts).Disk.Tone != Tone.Error && !MainScreenModel.Build(facts).Banner.Visible, "all folders removed on the server is not an error");
            facts.DiskSummary = "Диск: локальный Syncthing недоступен";
            Check(MainScreenModel.Build(facts).Disk.Tone == Tone.Error, "an unreachable Syncthing is still an error of the whole Disk");
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
            string before = Json.Encode(facts.Transport); MainScreenModel.Build(facts); MainScreenModel.Report(facts, "");
            Check(Json.Encode(facts.Transport) == before, "presentation does not mutate input facts");
        }
        static void RenderGate()
        {
            var gate = new MainScreenRenderGate();
            var first = gate.Next(MainScreenModel.Build(Healthy()), true, "");
            Check(first.Render && first.Layout, "first frame renders and lays out");
            var same = gate.Next(MainScreenModel.Build(Healthy()), true, "");
            Check(!same.Render && !same.Layout, "identical facts once a second touch neither controls nor layout");

            // Every rendered field reaches the key; text-only changes do not re-fit the page.
            var textOnly = new List<KeyValuePair<string, Action<MainScreenView>>> {
                Edit("banner tone", v => v.Banner.Tone = v.Banner.Tone == Tone.Error ? Tone.Ok : Tone.Error),
                Edit("banner text", v => v.Banner.Text += "!"), Edit("banner action", v => v.Banner.ActionText += "!"),
                Edit("banner action id", v => v.Banner.ActionId += "x"),
                Edit("vpn title", v => v.Vpn.Title += "!"), Edit("vpn state", v => v.Vpn.State += "!"),
                Edit("vpn tone", v => v.Vpn.Tone = v.Vpn.Tone == Tone.Error ? Tone.Ok : Tone.Error),
                Edit("vpn detail (speed)", v => v.Vpn.Detail += "1"), Edit("vpn on", v => v.Vpn.On = !v.Vpn.On),
                Edit("vpn switch enabled", v => v.Vpn.SwitchEnabled = !v.Vpn.SwitchEnabled),
                Edit("vpn switch text", v => v.Vpn.SwitchText += "!"), Edit("vpn path link", v => v.Vpn.PathLink += "!"),
                Edit("lan state", v => v.Lan.State += "!"), Edit("lan detail", v => v.Lan.Detail += "!"),
                Edit("lan tone", v => v.Lan.Tone = v.Lan.Tone == Tone.Error ? Tone.Ok : Tone.Error),
                Edit("disk state", v => v.Disk.State += "!"), Edit("disk detail", v => v.Disk.Detail += "!"),
                Edit("disk tone", v => v.Disk.Tone = v.Disk.Tone == Tone.Error ? Tone.Ok : Tone.Error),
                Edit("happier title", v => v.Happier.Title += "!"), Edit("happier state", v => v.Happier.State += "!"),
                Edit("happier detail", v => v.Happier.Detail += "!"),
                Edit("helper state", v => v.Helper.State += "!"),
                Edit("helper tone", v => v.Helper.Tone = v.Helper.Tone == Tone.Error ? Tone.Ok : Tone.Error),
            };
            foreach (var edit in textOnly) {
                var g = new MainScreenRenderGate(); g.Next(MainScreenModel.Build(Healthy()), true, "");
                var view = MainScreenModel.Build(Healthy()); edit.Value(view);
                var step = g.Next(view, true, "");
                Check(step.Render && !step.Layout, "text change re-renders without re-fit: " + edit.Key);
            }
            var shape = new List<KeyValuePair<string, Action<MainScreenView>>> {
                Edit("banner shown", v => v.Banner.Visible = !v.Banner.Visible), Edit("vpn card", v => v.Vpn.Visible = !v.Vpn.Visible),
                Edit("lan card", v => v.Lan.Visible = !v.Lan.Visible), Edit("disk card", v => v.Disk.Visible = !v.Disk.Visible),
                Edit("happier card", v => v.Happier.Visible = !v.Happier.Visible), Edit("helper card", v => v.Helper.Visible = !v.Helper.Visible),
                Edit("disk detail gone", v => v.Disk.Detail = ""), Edit("happier detail gone", v => v.Happier.Detail = ""),
                Edit("helper detail appears", v => v.Helper.Detail = "x"),
            };
            foreach (var edit in shape) {
                var g = new MainScreenRenderGate(); g.Next(MainScreenModel.Build(Healthy()), true, "");
                var view = MainScreenModel.Build(Healthy()); edit.Value(view);
                var step = g.Next(view, true, "");
                Check(step.Render && step.Layout, "appearing/disappearing part re-fits the page: " + edit.Key);
            }
            var path = gate.Next(MainScreenModel.Build(Healthy()), false, "");
            Check(path.Render && !path.Layout, "path link enabled state is rendered");
            var dns = gate.Next(MainScreenModel.Build(Healthy()), false, "DNS: проверка");
            Check(dns.Render && dns.Layout, "DNS details line appears");
            gate.Reset();
            Check(gate.Next(MainScreenModel.Build(Healthy()), false, "DNS: проверка").Render, "reset renders again");
        }
        static KeyValuePair<string, Action<MainScreenView>> Edit(string name, Action<MainScreenView> change)
        { return new KeyValuePair<string, Action<MainScreenView>>(name, change); }
    }
}
