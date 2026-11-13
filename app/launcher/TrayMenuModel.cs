using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;

namespace RemoteAgents.Launcher
{
    internal sealed class TrayMenuEntry
    {
        internal string Id, Text, Hint = "";
        internal bool Enabled, Warning;
        internal TrayMenuEntry(string id, string text, bool enabled = true) { Id = id; Text = text; Enabled = enabled; }
    }
    // Pure presentation model: the same facts feed the menu, tooltip and window.
    internal static class TrayMenuModel
    {
        internal static string LeftClickAction(Dictionary<string, object> config, Dictionary<string, object> account)
        { return HappierUrl(config, account).Length > 0 ? "happier" : "open"; }
        internal static bool AcceptLeftClick(int clicks, long elapsedMilliseconds, int doubleClickMilliseconds)
        {
            // NotifyIcon.MouseClick reports Clicks=0; ordinary controls can report 1.
            return (clicks == 0 || clicks == 1) && elapsedMilliseconds > doubleClickMilliseconds;
        }
        internal static string HappierUrl(Dictionary<string, object> config, Dictionary<string, object> account)
        {
            string value = Json.Text(Json.Map(Json.Get(config, "happier")), "webappUrl", Json.Str(account, "webappUrl")).Trim();
            Uri uri;
            return Uri.TryCreate(value, UriKind.Absolute, out uri) && (uri.Scheme == "https" || uri.Scheme == "http") && uri.UserInfo.Length == 0 ? uri.AbsoluteUri : "";
        }
        internal static TrayMenuEntry[] Build(Dictionary<string, object> config, Dictionary<string, object> account, Dictionary<string, object> transport, Dictionary<string, object> health)
        {
            string url = HappierUrl(config, account);
            return new[] {
                new TrayMenuEntry("open", "Открыть"),
                Folders(config),
                new TrayMenuEntry("happier", "Открыть Happier", url.Length > 0) { Hint = url.Length > 0 ? "Открыть веб-приложение Happier" : "Адрес Happier не задан: укажите happier.webappUrl в настройках" },
                new TrayMenuEntry("separator", "", false),
                new TrayMenuEntry("connection", Connection(transport), false),
                new TrayMenuEntry("server", ServerHealthView.Summary(health), false),
                new TrayMenuEntry("separator", "", false),
                new TrayMenuEntry("exit", "Выход")
            };
        }
        internal const string NoFolders = "⚠ Папки не выбраны — выберите папки для синхронизации";
        // No folders in the profile: nothing is synchronized. That is allowed, but the menu says so plainly.
        internal static bool FoldersMissing(Dictionary<string, object> config)
        {
            var profile = Json.Map(Json.Get(config, "profile"));
            if (!profile.ContainsKey("server")) return false;
            var choice = DiskChoice.FromProfile(profile);
            return !(choice.All || choice.Folders.Count > 0 || choice.External.Count > 0);
        }
        static TrayMenuEntry Folders(Dictionary<string, object> config)
        {
            if (!FoldersMissing(config)) return new TrayMenuEntry("folders", "Папки синхронизации");
            return new TrayMenuEntry("folders", NoFolders) { Warning = true, Hint = "Сейчас ни одна папка не синхронизируется с сервером. Откройте и отметьте нужные папки." };
        }
        internal static string PathTitle(Dictionary<string, object> candidate)
        {
            string tag = Json.Str(candidate, "tag");
            string title = Json.Str(candidate, "title");
            if (title.Length > 0) return title;
            if (tag == "vless-direct") return "VLESS напрямую";
            if (tag.StartsWith("vless-relay-", StringComparison.Ordinal)) return "VLESS через " + tag.Substring(12);
            if (tag.StartsWith("vless-sshhop-", StringComparison.Ordinal)) return "VLESS через SSH " + tag.Substring(13);
            if (tag == "openssh-direct" || tag == "singbox-ssh-direct") return "SSH напрямую";
            if (tag == "openssh-proxy") return "SSH через локальный прокси";
            return tag.Length > 0 ? tag : "путь не определён";
        }
        internal static string ActiveTitle(Dictionary<string, object> transport)
        {
            var candidate = StatusView.Candidates(transport).FirstOrDefault(c => Json.Str(c, "tag") == Json.Str(transport, "active"));
            return candidate != null ? PathTitle(candidate) : PathTitle(new Dictionary<string, object> { { "tag", Json.Str(transport, "active") }, { "title", Json.Str(transport, "title") } });
        }
        internal static string Connection(Dictionary<string, object> transport)
        {
            if (transport.Count == 0) return "Связь: ожидается проверка";
            return Json.Bool(transport, "ok") ? "Связь: " + ActiveTitle(transport) + " · " + StatusView.Speed(transport) : "Связь: не подтверждена";
        }
        internal static string CandidateLine(Dictionary<string, object> candidate, Dictionary<string, object> transport)
        {
            string state;
            if (!Json.Bool(candidate, "enabled", true)) state = "отключён";
            else switch (Json.Str(candidate, "state")) {
                case "ok": state = "работает"; break;
                case "fail": case "failed": state = "не работает"; break;
                case "checking": case "pending": state = "проверяется"; break;
                case "slow": state = "медленный"; break;
                case "frozen": state = "завис"; break;
                case "remembered": state = "ранее работал; ожидается проверка"; break;
                case "disabled": state = "отключён"; break;
                default: state = "не проверен"; break;
            }
            bool active = Json.Bool(transport, "ok") && Json.Str(candidate, "tag") == Json.Str(transport, "active");
            return PathTitle(candidate) + " — " + state + (active ? " · используется" : "") + " · " + StatusView.Speed(candidate);
        }
        internal static string Tooltip(Dictionary<string, object> transport, Dictionary<string, object> health)
        {
            string connection = Json.Bool(transport, "ok") ? Short(ActiveTitle(transport), 14) + " · " + StatusView.Speed(transport) : "связь не подтверждена";
            return Short(connection + "; " + ServerHealthView.Compact(health), 63);
        }
        internal static string Short(string value, int max)
        {
            value = value.Replace("\r", " ").Replace("\n", " ");
            if (value.Length <= max) return value;
            int length = max - 1; if (length > 0 && char.IsHighSurrogate(value[length - 1])) length--;
            return value.Substring(0, length) + "…";
        }
    }
    internal static class ServerHealthView
    {
        // Same address/SSH port/login tuple as the saved-route PowerShell probe.
        internal static string Identity(string home)
        {
            try {
                var config = Json.Read(Path.Combine(home, "config.json"));
                string path = Json.Text(Json.Map(Json.Get(config, "wizard")), "pendingProfile", Json.Str(Json.Map(Json.Get(config, "transport")), "profilePath"));
                if (path.Length == 0) {
                    string profiles = Path.Combine(home, "ssh-profiles");
                    var files = Directory.GetFiles(profiles, "ssh-transport.json", SearchOption.AllDirectories)
                        .Where(p => Path.GetFileName(Path.GetDirectoryName(Path.GetDirectoryName(p))) == "project-connections").ToArray();
                    if (files.Length != 1) return "";
                    path = files[0];
                }
                var profile = Json.Read(path); string address = Json.Str(profile, "serverAddress").Trim().ToLowerInvariant();
                if (address.Length == 0) return "";
                var args = Json.Strings(Json.Get(profile, "arguments")); int at = Array.IndexOf(args, "-p"), port = 22;
                if (at >= 0 && at + 1 < args.Length) port = int.Parse(args[at + 1], CultureInfo.InvariantCulture);
                return address + "\n" + port.ToString(CultureInfo.InvariantCulture) + "\n" + Json.Str(profile, "login");
            } catch { return ""; }
        }
        internal static Dictionary<string, object> Read(string home, DateTime? utcNow = null)
        {
            try {
                var data = Json.Read(Path.Combine(home, "state", "server-health.json"));
                string serverId = Identity(home);
                if (serverId.Length == 0 || Json.Str(data, "serverId") != serverId)
                    return new Dictionary<string, object> { { "summary", "ожидается проверка сервера" } };
                DateTime stamp; double age;
                if (!DateTime.TryParse(Json.Str(data, "updatedUtc"), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out stamp) ||
                    (age = ((utcNow ?? DateTime.UtcNow) - stamp.ToUniversalTime()).TotalSeconds) > 360 || age < -5)
                    return new Dictionary<string, object> { { "summary", "данные устарели; ожидается проверка" } };
                return data;
            } catch { return Json.Map(null); }
        }
        static double Number(Dictionary<string, object> data, string section, string key)
        {
            double value;
            return double.TryParse(Json.Str(Json.Map(Json.Get(data, section)), key), NumberStyles.Float, CultureInfo.InvariantCulture, out value) && !double.IsNaN(value) && !double.IsInfinity(value) && value >= 0 ? value : -1;
        }
        static double Percent(Dictionary<string, object> data, string section, string free)
        {
            double total = Number(data, section, "totalBytes"), available = Number(data, section, free);
            return total > 0 && available >= 0 && available <= total ? available / total * 100 : -1;
        }
        internal static bool Known(Dictionary<string, object> data)
        { return Json.Bool(data, "ok") && Percent(data, "disk", "freeBytes") >= 0 && Percent(data, "memory", "availableBytes") >= 0; }
        internal static bool Warning(Dictionary<string, object> data)
        { return Known(data) && (Percent(data, "disk", "freeBytes") < 10 || Percent(data, "memory", "availableBytes") < 10); }
        static string Size(double bytes)
        { return (bytes / (1024 * 1024 * 1024)).ToString("0.#", CultureInfo.CurrentCulture) + " ГиБ"; }
        internal static string Summary(Dictionary<string, object> data)
        {
            if (!Known(data)) return "Сервер: " + Json.Text(data, "summary", "ожидается проверка");
            return (Warning(data) ? "⚠ " : "") + "Сервер: диск " + Size(Number(data, "disk", "freeBytes")) + " из " + Size(Number(data, "disk", "totalBytes")) +
                " · память " + Size(Number(data, "memory", "usedBytes")) + "/" + Size(Number(data, "memory", "totalBytes")) +
                " · нагрузка " + Json.Str(Json.Map(Json.Get(data, "load")), "one");
        }
        internal static string Compact(Dictionary<string, object> data)
        {
            if (!Known(data)) return "сервер: нет свежих данных";
            return (Warning(data) ? "⚠ " : "") + "своб. диск " + Percent(data, "disk", "freeBytes").ToString("0.#", CultureInfo.CurrentCulture) + "% · ОЗУ " + Percent(data, "memory", "availableBytes").ToString("0.#", CultureInfo.CurrentCulture) + "%";
        }
        internal static string Detail(Dictionary<string, object> data)
        {
            if (!Known(data)) return Summary(data);
            var load = Json.Map(Json.Get(data, "load")); double uptime;
            string up = double.TryParse(Json.Str(data, "uptimeSec"), NumberStyles.Float, CultureInfo.InvariantCulture, out uptime) && uptime >= 0 && uptime <= TimeSpan.MaxValue.TotalSeconds
                ? Math.Floor(uptime / 86400) + " д " + Math.Floor(uptime % 86400 / 3600) + " ч " + Math.Floor(uptime % 3600 / 60) + " мин" : "нет данных";
            return Summary(data) + "\r\nДиск HOME: занято " + Size(Number(data, "disk", "usedBytes")) + "; свободно " + Percent(data, "disk", "freeBytes").ToString("0.#", CultureInfo.CurrentCulture) + "%" +
                "\r\nПамять: доступно " + Size(Number(data, "memory", "availableBytes")) + " (" + Percent(data, "memory", "availableBytes").ToString("0.#", CultureInfo.CurrentCulture) + "%)" +
                "\r\nНагрузка за 1 / 5 / 15 мин: " + Json.Str(load, "one") + " / " + Json.Str(load, "five") + " / " + Json.Str(load, "fifteen") + "; ядер: " + Json.Str(load, "cores") +
                "\r\nВремя работы: " + up + "\r\nПроверено (UTC): " + Json.Str(data, "updatedUtc");
        }
    }
    // Preserve an unsubmitted choice across speed updates; follow externally applied mode changes.
    internal sealed class PathSelection
    {
        string observed;
        internal string Selected { get; private set; }
        internal void Choose(string tag) { Selected = tag; }
        internal string Update(Dictionary<string, object> transport)
        {
            string mode = Json.Str(transport, "mode");
            if (mode != "auto" && mode != "pinned") return Selected ?? "";
            string current = mode == "pinned" ? Json.Text(transport, "pinnedTag", Json.Str(transport, "active")) : "";
            if (Selected == null || current != observed) Selected = current;
            observed = current;
            return Selected;
        }
    }
    internal sealed class ServerHealthSchedule
    {
        DateTime next = DateTime.MinValue;
        string observed;
        internal bool Due(DateTime now, bool connected, bool occupied, string serverId)
        {
            if (observed != serverId) { observed = serverId; next = DateTime.MinValue; }
            return serverId.Length > 0 && connected && !occupied && now >= next;
        }
        internal void Started(DateTime now) { next = now.AddMinutes(5); }
    }
}
