using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading.Tasks;
using System.Diagnostics;

namespace RemoteAgents.Launcher
{
    internal static class LanProxyTests
    {
        static void Check(bool ok, string label) { if (!ok) throw new Exception("LAN: " + label); }
        sealed class Browser : ILanBrowser {
            public string Pac { get; set; } = "";
            public bool HasPac { get; set; }
            public bool ProxyEnabled { get; set; }
            public string Proxy { get; set; } = "";
            public void SetPac(string value) { Pac = value ?? ""; HasPac = value != null; }
        }
        static void Probe(string response, bool expected)
        {
            var listener = new TcpListener(IPAddress.Loopback, 0); listener.Start();
            try {
                int port = ((IPEndPoint)listener.LocalEndpoint).Port;
                var server = Task.Run(() => { using (var client = listener.AcceptTcpClient()) using (var stream = client.GetStream()) {
                    client.ReceiveTimeout = 500;
                    var bytes = new byte[1024]; int n = stream.Read(bytes, 0, bytes.Length);
                    Check(Encoding.ASCII.GetString(bytes, 0, n).StartsWith("CONNECT 10.123.0.1:443 HTTP/1.1\r\n"), "CONNECT destination");
                    bytes = Encoding.ASCII.GetBytes(response); stream.Write(bytes, 0, bytes.Length);
                } });
                Check(LanProxy.Connect(port, "10.123.0.1", 443, 500) == expected, "remote CONNECT response determines probe");
                Check(server.Wait(1000), "loopback fixture finishes");
            } finally { listener.Stop(); }
        }
        static int Main(string[] args)
        {
            string home = Path.Combine(Path.GetTempPath(), "lan-csharp-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(home);
            try {
                var old = ConfigBundle.Parse("{\r\n\"kind\":\"remoteagents-config\",\r\n\"schema\":1\r\n}");
                Check(!LanAccess.Read(old.Profile).Enabled, "old profile disabled");
                string text = "{\r\n\"kind\":\"remoteagents-config\",\r\n\"schema\":1,\r\n\"lan\":[{\"name\":\"office\",\"kind\":\"openvpn\",\"ovpn\":{\"secret\":\"office-ovpn\"},\"testHost\":\"10.123.0.1\",\"testPort\":443,\"share\":{\"subnets\":[\"10.123.0.0/24\"],\"domains\":[\"*.example.org\",\"exact.example.net\"],\"forwards\":[{\"name\":\"db\",\"host\":\"db.example.net\",\"port\":5432,\"localPort\":15432}]}}]}";
                var parsed = ConfigBundle.Parse(text); var access = LanAccess.Read(parsed.Profile);
                Check(access.Enabled && access.ProbeHost == "10.123.0.1" && access.ProbePort == 443, "CRLF share and probe");
                ConfigBundle.Store(home, parsed, new[]{"lan"});
                var exported = ConfigBundle.Parse(ConfigBundle.Export(home, null));
                Check(Json.Encode(exported.Profile["lan"]) == Json.Encode(parsed.Profile["lan"]), "store/export preserves share");
                bool rejected = false; try { ConfigBundle.Parse(text.Replace("10.123.0.0/24", "0.0.0.0/0")); } catch (InvalidDataException) { rejected = true; }
                Check(rejected, "invalid subnet rejected");
                string pacFile = Path.Combine(home, "proxy.pac"); File.WriteAllText(pacFile, access.Pac(17880));
                using (var node = Process.Start(new ProcessStartInfo("node", "\"" + Path.Combine(args[0], "app/launcher/tests/test-lan-proxy-pac.cjs") + "\" \"" + pacFile + "\"") { UseShellExecute = false })) {
                    Check(node.WaitForExit(1500) && node.ExitCode == 0, "PAC executes correctly");
                }
                using (var server = new LanPacServer(access.Pac(17880))) {
                    var request = (HttpWebRequest)WebRequest.Create(server.Url); request.Proxy = null; request.Timeout = 1000;
                    using (var response = request.GetResponse()) using (var reader = new StreamReader(response.GetResponseStream()))
                        Check(reader.ReadToEnd() == access.Pac(17880), "PAC served by loopback TcpListener");
                    var browser = new Browser();
                    using (var owner = new LanPacOwnership(home, browser)) { Check(owner.Ensure(server.Url) == "" && browser.Pac == server.Url, "PAC installed"); }
                    Check(!browser.HasPac, "absence restored on exit");
                    browser.Pac = "http://foreign.example.org/pac"; browser.HasPac = true;
                    using (var owner = new LanPacOwnership(home, browser)) Check(owner.Ensure(server.Url).Length > 0 && browser.Pac.Contains("foreign"), "foreign PAC preserved");
                    browser.Pac = ""; browser.ProxyEnabled = true; browser.Proxy = "127.0.0.1:1080";
                    using (var owner = new LanPacOwnership(home, browser)) Check(owner.Ensure(server.Url).Contains("1080") && browser.Pac == "", "foreign system proxy preserved");
                    browser.ProxyEnabled = false;
                    var crashed = new LanPacOwnership(home, browser); crashed.Ensure(server.Url);
                    LanPacOwnership.Recover(home, browser); Check(browser.Pac == "", "crash/uninstall recovers previous empty value");
                    crashed.Dispose();
                    using (var owner = new LanPacOwnership(home, browser)) { owner.Ensure(server.Url); browser.Pac = "http://other.example.org/pac"; }
                    Check(browser.Pac.Contains("other"), "foreign changes win on exit");
                }
                Probe("HTTP/1.1 200 Connection established\r\n\r\n", true);
                Probe("HTTP/1.1 502 Bad Gateway\r\n\r\n", false);
                Console.WriteLine("PASS: LAN schema, migration/export, PAC, ownership/recovery, proxy probe"); return 0;
            } finally { Directory.Delete(home, true); }
        }
    }
}
