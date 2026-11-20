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
        internal bool Enabled;
        internal TrayMenuEntry(string id, string text, bool enabled = true) { Id = id; Text = text; Enabled = enabled; }
    }
    // Pure presentation model: the same facts feed the menu, tooltip and window.
    internal static class TrayMenuModel
    {
        internal static TrayMenuEntry BridgeEntry(CardView helper)
        {
            string text = string.IsNullOrEmpty(helper.SwitchText) ? "Удалённое управление" : helper.SwitchText;
            return new TrayMenuEntry("bridge", text, !string.IsNullOrEmpty(helper.SwitchText) && helper.SwitchEnabled) { Hint = helper.State ?? "" };
        }
        // «Открыть» and the left click lead to Happier; without a usable address the click opens the program window.
        internal static string LeftClickAction(Dictionary<string, object> config, Dictionary<string, object> account)
        { return HappierWebResolver.CanOpen(config, account) ? "happier" : "settings"; }
        internal static bool AcceptLeftClick(int clicks, long elapsedMilliseconds, int doubleClickMilliseconds)
        {
            // NotifyIcon.MouseClick reports Clicks=0; ordinary controls can report 1.
            return (clicks == 0 || clicks == 1) && elapsedMilliseconds > doubleClickMilliseconds;
        }
        internal static System.Threading.Tasks.Task<string> HappierUrl(Dictionary<string, object> config, Dictionary<string, object> account, string home = null)
        { return HappierWebResolver.ResolveAsync(config, account, home); }
        // One application icon; synchronization UI is an independent window.
        internal static TrayMenuEntry[] Build(Dictionary<string, object> config, Dictionary<string, object> account, Dictionary<string, object> transport, Dictionary<string, object> health, string diskStatus = "Диск: ожидается проверка")
        {
            bool canOpen = HappierWebResolver.CanOpen(config, account);
            return new[] {
                new TrayMenuEntry("open", "Открыть", canOpen) { Hint = canOpen ? "Открыть веб-приложение Happier" : "Адрес Happier не задан: укажите happier.webappUrl в настройках" },
                new TrayMenuEntry("settings", "Настройки") { Hint = "Окно программы: конфиг, подробные настройки и сервис" },
                new TrayMenuEntry("disk", "Диск") { Hint = "Папка Disk в Проводнике" },
                new TrayMenuEntry("synchronization", "Синхронизация (Syncthing)…") { Hint = "Окно синхронизации; его закрытие не останавливает Диск" },
                new TrayMenuEntry("diskStatus", Short(diskStatus, 100), false),
                new TrayMenuEntry("separator", "", false),
                new TrayMenuEntry("connection", Connection(transport), false),
                new TrayMenuEntry("server", ServerHealthView.Summary(health), false),
                new TrayMenuEntry("separator", "", false),
                new TrayMenuEntry("exit", "Выход")
            };
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
            var phase = StatusView.Phase(transport);
            if (phase == LinkPhase.Searching) return StatusView.SearchingText(transport);
            return phase == LinkPhase.Ok ? "Связь: " + ActiveTitle(transport) + " · " + StatusView.Speed(transport) : phase == LinkPhase.Checking ? "Связь: проверяется" : "Связь: не подтверждена";
        }
        internal static string CandidateLine(Dictionary<string, object> candidate, Dictionary<string, object> transport)
        {
            string state;
            if (!Json.Bool(candidate, "enabled", true)) state = "отключён";
            else if (Json.Bool(candidate, "suspect")) state = "проверяется";
            else switch (Json.Str(candidate, "state")) {
                case "ok": state = "работает"; break;
                case "fail": case "failed": state = StatusView.StaleCandidate(candidate, transport) ? "ранее не работал; ожидается проверка" : "не работает"; break;
                case "checking": case "pending": state = "проверяется"; break;
                case "slow": state = "медленный"; break;
                case "frozen": state = "завис"; break;
                case "remembered": state = "ранее работал; ожидается проверка"; break;
                case "disabled": state = "отключён"; break;
                default: state = "не проверен"; break;
            }
            var phase = StatusView.Phase(transport);
            bool active = Json.Str(candidate, "tag") == Json.Str(transport, "active") &&
                (phase == LinkPhase.Ok || phase == LinkPhase.Checking && Json.Str(transport, "phase") == "degraded");
            int order;
            string prefix = int.TryParse(Json.Str(candidate, "order"), NumberStyles.Integer, CultureInfo.InvariantCulture, out order) && order >= 0
                ? "№" + order.ToString(CultureInfo.CurrentCulture) + " · " : "";
            double latency;
            string delay = Measurement(candidate, "latencyMs", out latency) ? " · " + latency.ToString("0.#", CultureInfo.CurrentCulture) + " мс" : "";
            return prefix + PathTitle(candidate) + " — " + state + (active ? " · используется" : "") + " · " + CandidateSpeed(candidate) + delay + Penalty(candidate);
        }
        static string Penalty(Dictionary<string, object> candidate)
        {
            int step = Json.Int(candidate, "penaltyStep", 0); DateTime until;
            if (step < 1 || step > 5 || !DateTime.TryParse(Json.Str(candidate, "penaltyUntil"), CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind, out until) || until.ToUniversalTime() <= DateTime.UtcNow) return "";
            return " · пауза до " + until.ToLocalTime().ToString("HH:mm:ss", CultureInfo.CurrentCulture) + " (ступень " + step + ")";
        }
        // The contract may be read before the VPN writer has caught up with the transport (and vice versa).
        internal static bool Searching(Dictionary<string, object> transport, Dictionary<string, object> vpn)
        { return StatusView.Phase(transport) == LinkPhase.Searching || Json.Str(vpn, "state") == "searching"; }
        internal static string SearchingText(Dictionary<string, object> transport, Dictionary<string, object> vpn)
        { return StatusView.SearchingText(StatusView.Phase(transport) == LinkPhase.Searching ? transport : vpn); }
        internal static string ConflictText(Dictionary<string, object> vpn)
        { return StatusView.DisplayText(Json.Text(vpn, "summary", "Работает другой VPN. Отключите его перед включением этого VPN.")); }
        internal static string[] SwitchLines(Dictionary<string, object> transport)
        {
            var changes = Json.Array(Json.Get(transport, "switches")).Select(Json.Map).Where(c => c.Count > 0).ToArray();
            return changes.Skip(Math.Max(0, changes.Length - 10)).Select(c => {
                object why = Json.Get(c, "why");
                string reason = why is string ? (string)why : Json.Str(Json.Map(why), "text");
                return StatusView.DisplayText(SwitchTime(c) + " · " + SwitchPath(transport, Json.Str(c, "from")) +
                    " → " + SwitchPath(transport, Json.Str(c, "to")) + (reason.Length == 0 ? "" : " · " + reason));
            }).ToArray();
        }
        static string SwitchTime(Dictionary<string, object> change)
        {
            string value = Json.Str(change, "at"); DateTime stamp; long milliseconds;
            if (long.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out milliseconds) && milliseconds >= 0 && milliseconds <= 253402300799999L)
                stamp = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddMilliseconds(milliseconds);
            else if (!DateTime.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out stamp)) return value;
            return stamp.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.CurrentCulture);
        }
        static string SwitchPath(Dictionary<string, object> transport, string tag)
        {
            var candidate = StatusView.Candidates(transport).FirstOrDefault(c => Json.Str(c, "tag") == tag);
            return PathTitle(candidate ?? new Dictionary<string, object> { { "tag", tag } });
        }
        static bool Measurement(Dictionary<string, object> data, string key, out double value)
        {
            return double.TryParse(Json.Str(data, key), NumberStyles.Float, CultureInfo.InvariantCulture, out value)
                && !double.IsNaN(value) && !double.IsInfinity(value) && value >= 0;
        }
        static string CandidateSpeed(Dictionary<string, object> candidate)
        {
            double kbps;
            if (!Measurement(candidate, "kbps", out kbps)) return "скорость: нет данных";
            // The daemon's historical kbps field is bytes / 1KB / second (KiB/s); show decimal bit rates.
            double mbps = kbps * (8192.0 / 1000000);
            return mbps >= 1 ? mbps.ToString("0.#", CultureInfo.CurrentCulture) + " Мбит/с"
                : (mbps * 1000).ToString("0.#", CultureInfo.CurrentCulture) + " Кбит/с";
        }
        internal static string Tooltip(Dictionary<string, object> transport, Dictionary<string, object> health, Dictionary<string, object> vpn = null)
        {
            if (Json.Str(vpn, "state") == "conflict") return Short(ConflictText(vpn), 63);
            // Reason takes priority over speed and server metrics in the 63-character Windows tooltip.
            if (Searching(transport, vpn)) {
                var source = StatusView.Phase(transport) == LinkPhase.Searching ? transport : vpn;
                string reason = StatusView.Reason(source);
                return Short(Json.Str(source, "localNet") == "down" || reason.Length == 0 ? StatusView.SearchingText(source) : reason, 63);
            }
            string connection = StatusView.Phase(transport) == LinkPhase.Ok ? Short(ActiveTitle(transport), 14) + " · " + StatusView.Speed(transport) : StatusView.Phase(transport) == LinkPhase.Checking ? "связь проверяется" : "связь не подтверждена";
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
    internal sealed class TrayStatusNotice
    {
        internal string Text;
        internal bool Recovered;
    }
    // One notice per transition; keep the latest transition pending during the 60-second quiet period.
    // Missing/stale heartbeats do not create a new transition or deliver an outdated pending notice.
    internal sealed class TrayStatusNotifications
    {
        string observed, pending;
        DateTime next = DateTime.MinValue;
        internal TrayStatusNotice Observe(Dictionary<string, object> transport, Dictionary<string, object> vpn, DateTime now)
        {
            string current = Json.Str(vpn, "state") == "conflict" ? "conflict" : TrayMenuModel.Searching(transport, vpn)
                ? "searching" : StatusView.Phase(transport) == LinkPhase.Ok ? "ok" : null;
            if (current == null) return null;
            if (current != observed) {
                bool notify = current == "conflict" || observed == "ok" && current == "searching" || observed == "searching" && current == "ok";
                pending = notify ? current : null;
                observed = current;
            }
            if (pending == null || now < next) return null;
            pending = null; next = now.AddSeconds(60);
            return new TrayStatusNotice { Recovered = current == "ok", Text = current == "ok" ? "Связь восстановлена"
                : current == "conflict" ? TrayMenuModel.ConflictText(vpn) : TrayMenuModel.SearchingText(transport, vpn) };
        }
    }
    // Local REST only. The API key stays in memory and never enters arguments/logs.
    internal sealed class DiskTraySession
    {
        internal readonly string Root, Identity;
        internal readonly Uri Address;
        readonly string apiKey;
        long since;
        string engineStart;
        double previousUptime;
        Dictionary<string, object>[] folders, states, remoteStates;
        ICollection<string> confirmed;
        internal bool ServerConnected { get; private set; }
        internal int FolderCount { get { return folders == null ? -1 : folders.Length; } }
        string folderPeer;
        double previousIn, previousOut;
        readonly System.Diagnostics.Stopwatch clock = System.Diagnostics.Stopwatch.StartNew();
        double previousTime = -1;
        internal DiskTraySession(string root)
        {
            Root = root;
            var xml = new System.Xml.XmlDocument { XmlResolver = null };
            using (var reader = System.Xml.XmlReader.Create(Path.Combine(root, "state", "config.xml"), new System.Xml.XmlReaderSettings {
                DtdProcessing = System.Xml.DtdProcessing.Prohibit, XmlResolver = null })) xml.Load(reader);
            Address = LocalAddress(xml.SelectSingleNode("/configuration/gui/address").InnerText.Trim());
            apiKey = xml.SelectSingleNode("/configuration/gui/apikey").InnerText.Trim();
            if (apiKey.Length == 0) throw new InvalidDataException();
            Identity = Address.AbsoluteUri + "\n" + apiKey;
        }
        internal static string Home(Dictionary<string, object> config)
        {
            string value = Json.Str(Json.Map(Json.Get(config, "disk")), "home");
            return value.Length > 0 ? Environment.ExpandEnvironmentVariables(value) : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RemoteDisk");
        }
        internal static Uri LocalAddress(string value)
        {
            Uri uri;
            if (!Uri.TryCreate("http://" + value, UriKind.Absolute, out uri) || uri.Host != "127.0.0.1" || uri.UserInfo.Length != 0 ||
                uri.Query.Length != 0 || uri.Fragment.Length != 0 || uri.AbsolutePath != "/") throw new InvalidDataException("REST Syncthing должен слушать 127.0.0.1");
            return uri;
        }
        object Get(string route, System.Threading.CancellationToken token)
        {
            var request = (System.Net.HttpWebRequest)System.Net.WebRequest.Create(new Uri(Address, "rest/" + route));
            request.Proxy = null; request.AllowAutoRedirect = false; request.Timeout = 3500; request.ReadWriteTimeout = 3500;
            request.Headers["X-API-Key"] = apiKey;
            using (token.Register(request.Abort)) {
                token.ThrowIfCancellationRequested();
                using (var response = (System.Net.HttpWebResponse)request.GetResponse()) {
                    if (response.StatusCode != System.Net.HttpStatusCode.OK) throw new InvalidDataException();
                    using (var reader = new StreamReader(response.GetResponseStream(), System.Text.Encoding.UTF8)) return Json.Parse(reader.ReadToEnd().Replace("\r", ""));
                }
            }
        }
        internal string Read(System.Threading.CancellationToken token)
        {
            var system = Json.Map(Get("system/status", token));
            string start = Json.Str(system, "startTime"); double uptime = Number(system, "uptime");
            if (Json.Str(system, "myID").Length == 0 || start.Length == 0) throw new InvalidDataException();
            if (engineStart != null && (engineStart != start || uptime < previousUptime)) Reset();
            engineStart = start; previousUptime = uptime;
            // Events long-poll gates state refresh; connections counters supply the speed.
            // First snapshot also establishes a cursor, so changes during that snapshot are replayed.
            var events = Json.Array(Get("events?since=" + since.ToString(CultureInfo.InvariantCulture) + "&timeout=" + (previousTime < 0 ? "0&limit=1" : "2") +
                "&events=StateChanged,FolderSummary,FolderErrors,ConfigSaved,DeviceConnected,DeviceDisconnected,FolderCompletion,ClusterConfigReceived,LocalIndexUpdated,RemoteIndexUpdated", token));
            foreach (var item in events) since = Math.Max(since, (long)Number(Json.Map(item), "id"));
            var connections = Json.Map(Get("system/connections", token));
            var total = Json.Map(Json.Get(connections, "total")); double now = clock.Elapsed.TotalSeconds;
            double input = Number(total, "inBytesTotal"), output = Number(total, "outBytesTotal");
            if (previousTime >= 0 && (input < previousIn || output < previousOut)) Reset();
            string peer = File.ReadAllText(Path.Combine(Root, "server.txt")).Trim('\uFEFF', ' ', '\r', '\n', '\t');
            if (folderPeer != peer) { folders = states = remoteStates = null; folderPeer = peer; }
            // db/status is expensive: refresh folder state only initially or after an event.
            if (folders == null || events.Length > 0) {
                folders = Json.Array(Get("config/folders", token)).Select(Json.Map)
                    .Where(f => Json.Array(Json.Get(f, "devices")).Any(d => Json.Str(Json.Map(d), "deviceID") == peer)).ToArray();
                var updated = new List<Dictionary<string, object>>(); var completions = new List<Dictionary<string, object>>();
                foreach (var folder in folders) {
                    token.ThrowIfCancellationRequested();
                    bool paused = Json.Bool(folder, "paused"); string id = Uri.EscapeDataString(Json.Str(folder, "id"));
                    updated.Add(paused ? Json.Map(null) : Json.Map(Get("db/status?folder=" + id, token)));
                    completions.Add(paused ? Json.Map(null) : Json.Map(Get("db/completion?folder=" + id + "&device=" + Uri.EscapeDataString(peer), token)));
                }
                states = updated.ToArray(); remoteStates = completions.ToArray();
                // Память «сервер эту папку уже подтверждал»: по ней папка, которую сервер снял, отличается от новой, ещё не принятой.
                confirmed = DiskConfirmedFolders.Update(Root, peer, folders.Select(f => Json.Str(f, "id")),
                    folders.Where((f, i) => DiskSnapshot.ConfirmedByServer(remoteStates[i])).Select(f => Json.Str(f, "id")));
            }
            bool connected = Json.Bool(Json.Map(Json.Get(Json.Map(Json.Get(connections, "connections")), peer)), "connected");
            ServerConnected = connected;
            string speed = Rates(previousIn, previousOut, input, output, previousTime < 0 ? 0 : now - previousTime);
            previousIn = input; previousOut = output; previousTime = now;
            return Summary(folders, states, connected, remoteStates, confirmed) + speed;
        }
        void Reset() { since = 0; folders = states = remoteStates = null; previousTime = -1; }
        internal static double Number(Dictionary<string, object> data, string key)
        {
            double value;
            return double.TryParse(Json.Str(data, key), NumberStyles.Float, CultureInfo.InvariantCulture, out value) && !double.IsNaN(value) && !double.IsInfinity(value) ? value : 0;
        }
        internal static string Rates(double oldIn, double oldOut, double input, double output, double seconds)
        {
            if (seconds <= 0 || input < oldIn || output < oldOut) return "";
            return " · ↓" + ((input - oldIn) / seconds / 1024).ToString("0.#", CultureInfo.InvariantCulture) + " ↑" +
                ((output - oldOut) / seconds / 1024).ToString("0.#", CultureInfo.InvariantCulture) + " КБ/с";
        }
        // Папка с ошибкой: текст причины для сводки (пусто, если ошибки нет).
        static string FolderFailure(Dictionary<string, object> state)
        {
            string error = Json.Str(state, "error").Trim();
            if (error.Length > 0) return error;
            if (Number(state, "pullErrors") > 0) return "не удалось получить файлов: " + Number(state, "pullErrors").ToString("0", CultureInfo.InvariantCulture);
            if (Number(state, "errors") > 0) return "ошибок: " + Number(state, "errors").ToString("0", CultureInfo.InvariantCulture);
            return Json.Str(state, "state") == "error" ? "сбой" : "";
        }
        static string FolderName(Dictionary<string, object> folder) { return folder == null ? "?" : Json.Text(folder, "label", Json.Str(folder, "id")); }
        static string Names(List<string> names) { return string.Join(", ", names.Take(3)) + (names.Count > 3 ? ", …" : ""); }
        // Ошибка или снятие одной папки не делает ошибкой весь Диск: такие папки выделяются в отдельную строку, остальные считаются как раньше.
        // Общая ошибка остаётся для случаев, когда не работает весь Диск (сервер не подключён; локальный Syncthing, см. CheckDisk).
        internal static string Summary(Dictionary<string, object>[] folders, Dictionary<string, object>[] states, bool connected, Dictionary<string, object>[] remoteStates = null, ICollection<string> confirmed = null)
        {
            var failed = new List<string>(); var reasons = new List<string>(); var removed = new List<string>();
            var keptFolders = new List<Dictionary<string, object>>(); var keptStates = new List<Dictionary<string, object>>(); var keptRemote = new List<Dictionary<string, object>>();
            bool remoteAligned = remoteStates != null && remoteStates.Length == folders.Length && states.Length == folders.Length;
            for (int i = 0; i < states.Length; i++) {
                var folder = i < folders.Length ? folders[i] : null;
                if (folder != null && remoteAligned && confirmed != null && confirmed.Contains(Json.Str(folder, "id")) && DiskSnapshot.RemovedByServer(remoteStates[i], connected, true)) { removed.Add(FolderName(folder)); continue; }
                string reason = FolderFailure(states[i]);
                if (reason.Length > 0) { failed.Add(FolderName(folder)); reasons.Add(reason); continue; }
                keptStates.Add(states[i]); if (folder != null) keptFolders.Add(folder); if (remoteAligned) keptRemote.Add(remoteStates[i]);
            }
            for (int i = states.Length; i < folders.Length; i++) keptFolders.Add(folders[i]);
            string core = FolderSummary(keptFolders.ToArray(), keptStates.ToArray(), connected, remoteAligned ? keptRemote.ToArray() : null);
            string note = removed.Count == 0 ? "" : (removed.Count == 1 ? " · удалена на сервере: " : " · удалены на сервере: ") + Names(removed);
            if (failed.Count == 0 && removed.Count == 0) return core;
            if (failed.Count > 0 && !connected) return keptFolders.Count > 0 ? core : "Диск: сервер не подключён";
            if (failed.Count > 0)
                return "Диск работает; " + (failed.Count == 1 ? "ошибка в папке " + failed[0] + ": " + reasons[0]
                    : "ошибки в " + failed.Count.ToString(CultureInfo.InvariantCulture) + (failed.Count % 10 == 1 && failed.Count % 100 != 11 ? " папке: " : " папках: ") + Names(failed)) + note;
            return keptFolders.Count == 0 ? "Диск: папки удалены на сервере, локальные копии сохранены" : core + note;
        }
        static string FolderSummary(Dictionary<string, object>[] folders, Dictionary<string, object>[] states, bool connected, Dictionary<string, object>[] remoteStates)
        {
            if (folders.Length == 0) return "Диск: нет выбранных папок";
            if (folders.Any(f => Json.Bool(f, "paused"))) return "Диск: есть папки на паузе";
            if (!connected) return "Диск: сервер не подключён";
            if (states.Any(s => Number(s, "receiveOnlyTotalItems") > 0 || Number(s, "receiveOnlyChangedBytes") > 0)) return "Диск: есть локальные изменения";
            if (states.Any(s => Json.Str(s, "state").StartsWith("scan", StringComparison.Ordinal))) return "Диск: проверка файлов";
            double needed = states.Sum(s => Number(s, "needBytes")), total = states.Sum(s => Number(s, "globalBytes"));
            if (needed > 0 || states.Any(s => Number(s, "needTotalItems") > 0 || Json.Str(s, "state").StartsWith("sync", StringComparison.Ordinal)))
                return "Диск: синхронизация" + (total > 0 ? " " + Math.Min(100, Math.Max(0, (total - needed) * 100 / total)).ToString("0", CultureInfo.InvariantCulture) + "%" : "");
            // Explorer and tray use exactly the same local/remote readiness decision.
            if (states.Length != folders.Length || remoteStates == null || remoteStates.Length != folders.Length) return "Диск: состояние уточняется";
            var rows = folders.Select((f, i) => DiskSnapshot.Status(new DiskFolderState { Paused = Json.Bool(f, "paused") }, states[i], remoteStates[i], connected)).ToArray();
            if (rows.Any(r => r.Kind == DiskExplorerKind.Paused)) return "Диск: есть папки на паузе";
            if (rows.All(r => r.Kind == DiskExplorerKind.Synced)) return "Диск: синхронизирован";
            if (rows.Any(r => r.Kind == DiskExplorerKind.Syncing)) return "Диск: синхронизация " + rows.Min(r => r.Percent).ToString(CultureInfo.InvariantCulture) + "%";
            return "Диск: состояние уточняется";
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
