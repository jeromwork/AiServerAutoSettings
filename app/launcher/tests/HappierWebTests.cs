using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading.Tasks;

namespace RemoteAgents.Launcher
{
    internal static class HappierWebTests
    {
        static int count;
        static void Check(bool ok, string text) { if (!ok) throw new Exception("Happier web: " + text); count++; }
        static Dictionary<string, object> Config(int port)
        { return ConfigBundle.D("happier", ConfigBundle.D("webappUrl", "https://cloud.example.invalid/", "localWeb", ConfigBundle.D("enabled", true, "port", port, "serverPort", 47832))); }
        static async Task Reply(string body, bool healthy, string status = "200 OK", bool stallBody = false, bool localOnly = false)
        {
            var listener = new TcpListener(IPAddress.Loopback, 0); listener.Start();
            int port = ((IPEndPoint)listener.LocalEndpoint).Port;
            var config = Config(port);
            if (localOnly) Json.Map(config["happier"]).Remove("webappUrl");
            string before = Json.Encode(config);
            var server = Task.Run(async () => {
                using (var client = await listener.AcceptTcpClientAsync())
                using (var stream = client.GetStream()) {
                    var reader = new StreamReader(stream, Encoding.ASCII, false, 1024, true);
                    string line = await reader.ReadLineAsync();
                    Check(line == "GET /_remoteagents/health HTTP/1.1", "GET health path");
                    while (!string.IsNullOrEmpty(await reader.ReadLineAsync())) { }
                    byte[] bytes = Encoding.UTF8.GetBytes(body);
                    string header = "HTTP/1.1 " + status + "\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: " + bytes.Length + "\r\nLocation: https://external.example.invalid/\r\n\r\n";
                    byte[] prefix = Encoding.ASCII.GetBytes(header);
                    await stream.WriteAsync(prefix, 0, prefix.Length);
                    if (stallBody) { await Task.Delay(1800); return; }
                    await stream.WriteAsync(bytes, 0, bytes.Length);
                }
            });
            try {
                var watch = Stopwatch.StartNew();
                Task<string> task = TrayMenuModel.HappierUrl(config, ConfigBundle.D());
                Check(watch.ElapsedMilliseconds < 500, "resolver returns without blocking caller");
                string result = await task;
                Check(result == (healthy ? "http://127.0.0.1:" + port + "/" : "https://cloud.example.invalid/"), "health selects expected browser URL");
                if (stallBody) Check(watch.ElapsedMilliseconds < 2500, "body timeout is bounded");
                Check(Json.Encode(config) == before, "navigation never replaces configured/account origins");
                await server;
            } finally { listener.Stop(); }
        }
        static async Task Tests()
        {
            var empty = ConfigBundle.D(); var cloud = ConfigBundle.D("webappUrl", "https://account.example.invalid/");
            Check(await HappierWebResolver.ResolveAsync(empty, cloud) == "https://account.example.invalid/", "old account fallback without localWeb");
            Check(HappierWebResolver.LocalUrl(empty) == "", "missing field stays disabled");
            var config = Config(47831);
            Check(TrayMenuModel.LeftClickAction(config, empty) == "happier" && TrayMenuModel.Build(config, empty, empty, empty)[0].Enabled, "local-only click/menu attempts health");
            Json.Map(config["happier"]).Remove("webappUrl");
            Check(TrayMenuModel.LeftClickAction(config, empty) == "happier", "left click can open local-only page");
            var profileLocal = ConfigBundle.D("enabled", false, "port", 47831, "serverPort", 47832);
            config["profile"] = ConfigBundle.D("happier", ConfigBundle.D("localWeb", profileLocal));
            Check(HappierWebResolver.LocalUrl(config) == "", "explicit disabled profile overrides old settings");
            profileLocal["enabled"] = true;
            Check(HappierWebResolver.LocalUrl(config) == "http://127.0.0.1:47831/", "profile provides fixed local origin");
            profileLocal["enabled"] = false;
            Check(await HappierWebResolver.ResolveAsync(config, cloud) == "https://account.example.invalid/", "disabled local uses cloud");
            var listener = new TcpListener(IPAddress.Loopback, 0); listener.Start();
            int closedPort = ((IPEndPoint)listener.LocalEndpoint).Port; listener.Stop();
            Check(await HappierWebResolver.ResolveAsync(Config(closedPort), empty) == "https://cloud.example.invalid/", "connection refused falls back");
            await Reply("{\r\n\"ok\":true,\"schema\":1\r\n}", true);
            await Reply("{\"ok\":true}", true, localOnly: true);
            foreach (string bad in new[] { "{\"ok\":false}", "{\"ok\":\"true\"}", "{\"ok\":1}", "{}", "[]", "true", "null", "<html>other app</html>", new string('x', 5000) }) await Reply(bad, false);
            await Reply("{\"ok\":true}", false, "302 Found");
            await Reply("{\"ok\":true}", false, "500 Server Error");
            await Reply("{\"ok\":true}", false, stallBody: true);
        }
        internal static void Run() { Tests().GetAwaiter().GetResult(); Console.WriteLine("OK: " + count + " Happier browser resolver checks (real loopback HTTP)"); }
    }
}
