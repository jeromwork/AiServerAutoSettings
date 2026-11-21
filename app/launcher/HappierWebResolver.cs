using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace RemoteAgents.Launcher
{
    // Only browser navigation uses this address. Account/API requests keep their cloud origins.
    internal static class HappierWebResolver
    {
        internal static Dictionary<string, object> LocalWeb(Dictionary<string, object> config)
        {
            var h = Json.Map(Json.Get(Json.Map(Json.Get(config, "profile")), "happier"));
            if (!h.ContainsKey("localWeb")) h = Json.Map(Json.Get(config, "happier"));
            return Json.Map(Json.Get(h, "localWeb"));
        }
        internal static string LocalUrl(Dictionary<string, object> config)
        {
            var local = LocalWeb(config);
            int port = Json.Int(local, "port", 0), serverPort = Json.Int(local, "serverPort", 0);
            return Json.Bool(local, "enabled") && port >= 1024 && port <= 65535 && serverPort >= 1024 && serverPort <= 65535
                ? "http://127.0.0.1:" + port + "/" : "";
        }
        internal static string CloudUrl(Dictionary<string, object> config, Dictionary<string, object> account)
        {
            var h = Json.Map(Json.Get(Json.Map(Json.Get(config, "profile")), "happier"));
            var saved = Json.Map(Json.Get(config, "happier"));
            string value = Json.Text(h, "webappUrl", Json.Text(saved, "webappUrl", Json.Str(account, "webappUrl"))).Trim();
            Uri uri;
            return Uri.TryCreate(value, UriKind.Absolute, out uri) && (uri.Scheme == "https" || uri.Scheme == "http") && uri.UserInfo.Length == 0 ? uri.AbsoluteUri : "";
        }
        internal static bool CanOpen(Dictionary<string, object> config, Dictionary<string, object> account)
        { return LocalUrl(config).Length > 0 || CloudUrl(config, account).Length > 0; }

        internal static Task<string> ResolveAsync(Dictionary<string, object> config, Dictionary<string, object> account, string home = null)
        {
            string local = LocalUrl(config), cloud = CloudUrl(config, account);
            if (local.Length == 0) return Task.FromResult(cloud);
            // WebRequest is available in net48. The worker and abort timer bound headers AND a slow response body.
            return Task.Run(() => Healthy(local) ? WithLogin(local, home) : cloud);
        }
        // Called only after our fixed loopback endpoint passes health. Never attach a key to a fallback.
        static string WithLogin(string local, string home)
        {
            if (string.IsNullOrEmpty(home)) return local;
            try {
                string file = Path.Combine(home, "secrets", "happier-account.key");
                if (!File.Exists(file) || new FileInfo(file).Length > 256) return local;
                string key = File.ReadAllText(file).Trim();
                // 32 bytes = 52 base32 characters; final character has only one data bit.
                return Regex.IsMatch(key, @"\A(?:[A-Z2-7]{5}-){10}[A-Z2-7][AQ]\z") ? local + "#ra-login=" + key : local;
            } catch (Exception) { return local; } // Missing/unreadable secret is an ordinary manual login.
        }
        static bool Healthy(string local)
        {
            var request = (HttpWebRequest)WebRequest.Create(local + "_remoteagents/health");
            request.Proxy = null; request.AllowAutoRedirect = false; request.Method = "GET";
            request.Timeout = request.ReadWriteTimeout = 1500;
            // timer-ok: D — Предохранитель (конституция 4а): ответ health недоступен при зависшем HTTP; Abort прерывает запрос, успех не объявляет.
            using (var timer = new Timer(_ => request.Abort(), null, 1500, Timeout.Infinite)) {
                try {
                    using (var response = (HttpWebResponse)request.GetResponse()) {
                        if (response.StatusCode != HttpStatusCode.OK) return false;
                        using (var reader = new StreamReader(response.GetResponseStream())) {
                            var buffer = new char[4097]; int length = 0, read;
                            while (length < buffer.Length && (read = reader.Read(buffer, length, buffer.Length - length)) > 0) length += read;
                            if (length == buffer.Length) return false;
                            var data = Json.Parse(new string(buffer, 0, length)) as Dictionary<string, object>;
                            return data != null && Json.Get(data, "ok") is bool && (bool)data["ok"];
                        }
                    }
                } catch (WebException error) { if (error.Response != null) error.Response.Dispose(); return false; }
                catch (Exception) { return false; }
            }
        }
    }
}
