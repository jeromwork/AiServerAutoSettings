using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32;

namespace RemoteAgents.Launcher
{
    internal interface ILanBrowser
    {
        string Pac { get; }
        bool HasPac { get; }
        bool ProxyEnabled { get; }
        string Proxy { get; }
        void SetPac(string value); // null restores the absence of a value
    }
    internal sealed class LanWindowsBrowser : ILanBrowser
    {
        const string PathName = @"Software\Microsoft\Windows\CurrentVersion\Internet Settings";
        object Get(string name) { using (var k = Registry.CurrentUser.OpenSubKey(PathName)) return k == null ? null : k.GetValue(name); }
        public string Pac { get { return Convert.ToString(Get("AutoConfigURL")); } }
        public bool HasPac { get { return Get("AutoConfigURL") != null; } }
        public bool ProxyEnabled { get { return Convert.ToString(Get("ProxyEnable")) == "1"; } }
        public string Proxy { get { return Convert.ToString(Get("ProxyServer")); } }
        public void SetPac(string value)
        {
            using (var k = Registry.CurrentUser.CreateSubKey(PathName)) { if (value == null) k.DeleteValue("AutoConfigURL", false); else k.SetValue("AutoConfigURL", value, RegistryValueKind.String); }
            InternetSetOption(IntPtr.Zero, 39, IntPtr.Zero, 0); InternetSetOption(IntPtr.Zero, 37, IntPtr.Zero, 0);
        }
        [DllImport("wininet.dll", SetLastError = true)] static extern bool InternetSetOption(IntPtr handle, int option, IntPtr buffer, int length);
    }
    // A write-ahead ownership record makes startup/uninstall recover an interrupted launcher.
    // Foreign changes win: restore only if AutoConfigURL still equals our exact URL.
    internal sealed class LanPacOwnership : IDisposable
    {
        readonly string file; readonly ILanBrowser browser;
        string owned = "", previous; bool hadPrevious;
        internal LanPacOwnership(string home, ILanBrowser browser)
        {
            this.browser = browser; file = System.IO.Path.Combine(home, "state", "lan-pac.json");
            Recover(home, browser);
        }
        internal static void Recover(string home, ILanBrowser browser)
        {
            string path = System.IO.Path.Combine(home, "state", "lan-pac.json");
            if (!File.Exists(path)) return;
            var saved = Json.Read(path);
            string url = Json.Str(saved, "url");
            Uri parsed;
            if (!Uri.TryCreate(url, UriKind.Absolute, out parsed) || parsed.Scheme != "http" || parsed.Host != "127.0.0.1" || !parsed.AbsolutePath.EndsWith("/proxy.pac", StringComparison.Ordinal)) throw new InvalidDataException("Повреждён учёт PAC программы");
            if (browser.Pac == url) browser.SetPac(Json.Bool(saved, "hadPrevious") ? Json.Str(saved, "previous") : null);
            File.Delete(path);
        }
        internal static string Conflict(ILanBrowser b, string ours)
        {
            if (b.Pac.Length > 0 && b.Pac != ours) {
                Uri u; return Uri.TryCreate(b.Pac, UriKind.Absolute, out u) ? "PAC " + u.Host + (u.IsDefaultPort ? "" : ":" + u.Port) : "другой PAC";
            }
            if (b.ProxyEnabled) {
                string p = b.Proxy;
                return p.Length < 180 && System.Text.RegularExpressions.Regex.IsMatch(p, @"^[a-zA-Z0-9.\[\]:;= -]+$") ? p : "системный прокси";
            }
            return "";
        }
        internal string Ensure(string url)
        {
            string conflict = Conflict(browser, owned);
            if (conflict.Length > 0) { Dispose(); return conflict; }
            if (owned.Length > 0 && browser.Pac == owned) return "";
            // A user removed our PAC. Keep that explicit choice until a later reconfiguration.
            if (owned.Length > 0) return "настройки Windows изменены пользователем";
            hadPrevious = browser.HasPac; previous = browser.Pac;
            Files.Atomic(file, Json.Encode(new { url, hadPrevious, previous }));
            owned = url;
            try { browser.SetPac(url); } catch { Dispose(); throw; }
            return "";
        }
        public void Dispose()
        {
            if (owned.Length == 0) return;
            if (browser.Pac == owned) browser.SetPac(hadPrevious ? previous : null);
            owned = "";
            if (File.Exists(file)) File.Delete(file);
        }
    }
    // TcpListener avoids HttpListener URL ACLs/elevation. Only a small static PAC is served.
    internal sealed class LanPacServer : IDisposable
    {
        readonly TcpListener listener; readonly string path, body;
        readonly Task worker; volatile bool stopped;
        internal readonly string Url;
        internal LanPacServer(string pac)
        {
            body = pac; path = "/" + Guid.NewGuid().ToString("N") + "/proxy.pac";
            listener = new TcpListener(IPAddress.Loopback, 0); listener.ExclusiveAddressUse = true; listener.Start(8);
            Url = "http://127.0.0.1:" + ((IPEndPoint)listener.LocalEndpoint).Port + path;
            worker = Task.Run((Action)Serve);
        }
        void Serve()
        {
            while (!stopped) {
                try {
                    using (var client = listener.AcceptTcpClient()) {
                        client.ReceiveTimeout = client.SendTimeout = 1000;
                        using (var stream = client.GetStream()) {
                            var input = new MemoryStream(); int value;
                            while (input.Length < 4096 && (value = stream.ReadByte()) >= 0) { input.WriteByte((byte)value); if (value == 10) break; }
                            string line = Encoding.ASCII.GetString(input.ToArray()).TrimEnd('\r', '\n');
                            bool ok = line == "GET " + path + " HTTP/1.1" || line == "GET " + path + " HTTP/1.0";
                            byte[] payload = Encoding.UTF8.GetBytes(ok ? body : "Not found\n");
                            byte[] header = Encoding.ASCII.GetBytes("HTTP/1.1 " + (ok ? "200 OK" : "404 Not Found") + "\r\nContent-Type: application/x-ns-proxy-autoconfig\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: " + payload.Length + "\r\n\r\n");
                            stream.Write(header, 0, header.Length); stream.Write(payload, 0, payload.Length);
                        }
                    }
                } catch { if (stopped) break; }
            }
        }
        public void Dispose() { stopped = true; listener.Stop(); }
    }
    internal sealed class LanProxy : IDisposable
    {
        readonly string home; readonly ILanBrowser browser; readonly LanPacOwnership ownership;
        LanPacServer server; string pacKey = "", probeKey = ""; Task<bool> probe;
        DateTime nextProbe = DateTime.MinValue, checkedAt = DateTime.MinValue;
        bool connected, disposed;
        internal LanProxy(string home, ILanBrowser browser = null)
        { this.home = home; this.browser = browser ?? new LanWindowsBrowser(); ownership = new LanPacOwnership(home, this.browser); }
        internal static bool Connect(int proxyPort, string host, int port, int timeoutMs = 2500)
        {
            // A TCP accept on the local listener is insufficient; require the remote CONNECT response.
            using (var client = new TcpClient()) {
                try {
                    var connect = client.ConnectAsync(IPAddress.Loopback, proxyPort);
                    if (!connect.Wait(timeoutMs)) return false;
                    client.ReceiveTimeout = client.SendTimeout = timeoutMs;
                    using (var stream = client.GetStream()) {
                        byte[] request = Encoding.ASCII.GetBytes("CONNECT " + host + ":" + port + " HTTP/1.1\r\nHost: " + host + ":" + port + "\r\n\r\n");
                        stream.Write(request, 0, request.Length);
                        var bytes = new List<byte>(); int value;
                        var deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
                        while (bytes.Count < 1024 && DateTime.UtcNow < deadline && (value = stream.ReadByte()) >= 0) { bytes.Add((byte)value); if (value == 10) break; }
                        string line = Encoding.ASCII.GetString(bytes.ToArray()).Trim();
                        return line.StartsWith("HTTP/1.1 200 ", StringComparison.Ordinal) || line.StartsWith("HTTP/1.0 200 ", StringComparison.Ordinal) || line == "HTTP/1.1 200" || line == "HTTP/1.0 200";
                    }
                } catch { return false; }
            }
        }
        internal void Tick(Dictionary<string, object> config, Dictionary<string, object> transport)
        {
            if (disposed) return;
            try {
                var access = LanAccess.Read(Json.Map(Json.Get(config, "profile")));
                if (!access.Enabled) { StopPac(); Publish(false, "off", "не настроена", "", false); return; }
                var lan = Json.Map(Json.Get(transport, "lan")); int port = Json.Int(lan, "proxyPort", 0);
                bool ready = Json.Bool(transport, "ok") && Json.Bool(lan, "enabled") && port > 0 && Json.Str(transport, "configError").Length == 0;
                // Never apply PAC from a desired profile over a still-running older channel config.
                ready &= Same(access.Subnets, Json.Strings(Json.Get(lan, "subnets"))) && Same(access.Domains, Json.Strings(Json.Get(lan, "domains")));
                ready &= Json.Str(lan, "probeHost") == access.ProbeHost && Json.Int(lan, "probePort", 0) == access.ProbePort;
                var forwards = Json.Array(Json.Get(lan, "forwards")).Select(Json.Map).ToArray();
                ready &= access.Forwards.Count == forwards.Length && access.Forwards.All(f => forwards.Any(g => Json.Str(g, "name") == Json.Str(f, "name") && Json.Str(g, "host") == Json.Str(f, "host").ToLowerInvariant() && Json.Int(g, "port", 0) == Json.Int(f, "port", 0)));
                if (!ready) { StopPac(); probeKey = ""; connected = false; Publish(false, "channel-down", "канал не работает", "", true); return; }
                string desiredPac = access.Pac(port), key = Json.Str(transport, "configRevision") + ":" + desiredPac;
                if (key != pacKey) { StopPac(); server = new LanPacServer(desiredPac); pacKey = key; }
                string conflict = ownership.Ensure(server.Url);
                key += ":" + Json.Str(transport, "active");
                if (key != probeKey) { probeKey = key; probe = null; checkedAt = DateTime.MinValue; connected = false; nextProbe = DateTime.MinValue; }
                if (probe != null && probe.IsCompleted) { connected = probe.Status == TaskStatus.RanToCompletion && probe.Result; checkedAt = DateTime.UtcNow; probe = null; }
                if (probe == null && DateTime.UtcNow >= nextProbe) {
                    string target = access.ProbeHost; int targetPort = access.ProbePort;
                    probe = Task.Run(() => Connect(port, target, targetPort)); nextProbe = DateTime.UtcNow.AddSeconds(10);
                }
                if (checkedAt == DateTime.MinValue || (DateTime.UtcNow - checkedAt).TotalSeconds > 20) Publish(false, "checking", "проверяется", conflict, true);
                else if (!connected) Publish(false, "server-unreachable", "сервер не в ЛВС или хост не отвечает", conflict, true);
                else if (conflict.Length > 0) Publish(false, "browser-unconfigured", "браузер не настроен", conflict, true);
                else Publish(true, "working", "работает", "", true);
            } catch { try { StopPac(); Publish(false, "error", "браузер не настроен; ошибка настройки доступа", "", true); } catch { } }
        }
        static bool Same(IEnumerable<string> a, IEnumerable<string> b) { return a.Distinct().OrderBy(s => s).SequenceEqual(b.Distinct().OrderBy(s => s)); }
        void Publish(bool ok, string state, string summary, string conflict, bool enabled)
        {
            string detail = conflict.Length > 0 ? "Браузер использует прокси " + conflict + " — сеть клиники доступна через порты/ручную настройку" : "";
            Files.Atomic(Path.Combine(home, "status", "lan-proxy.json"), Json.Encode(new { ok, enabled, state, summary, detail, proxyChecked = connected && checkedAt != DateTime.MinValue && (DateTime.UtcNow - checkedAt).TotalSeconds <= 20, checkedAt = checkedAt == DateTime.MinValue ? null : checkedAt.ToString("o"), updatedAt = DateTime.UtcNow.ToString("o") }));
        }
        void StopPac() { ownership.Dispose(); if (server != null) server.Dispose(); server = null; pacKey = ""; }
        public void Dispose() { disposed = true; StopPac(); }
    }
}
