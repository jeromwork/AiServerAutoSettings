using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

namespace RemoteAgents.Launcher
{
    // Relay against local fake SOCKS5 / HTTP CONNECT proxies that echo-serve a banner after the handshake.
    internal static class ProxyRelayTests
    {
        static void Check(bool value, string name) { if (!value) throw new InvalidOperationException("ProxyRelay FAIL: " + name); }
        static byte[] Read(Stream s, int n) { var b = new byte[n]; int got = 0; while (got < n) { int r = s.Read(b, got, n - got); if (r <= 0) throw new IOException(); got += r; } return b; }
        // mode: ok, refuse (proxy says no), silent (accepts TCP, never answers)
        static TcpListener Serve(string kind, string mode, Action<string> seen)
        {
            var l = new TcpListener(IPAddress.Loopback, 0); l.Start();
            new Thread(() => {
                try {
                    using (var c = l.AcceptTcpClient()) {
                        var s = c.GetStream();
                        if (mode == "silent") { Thread.Sleep(15000); return; }
                        if (kind == "socks") {
                            Read(s, 3); s.Write(new byte[] { 5, 0 }, 0, 2);
                            var h = Read(s, 4); string host = h[3] == 3 ? Encoding.ASCII.GetString(Read(s, Read(s, 1)[0])) : new IPAddress(Read(s, h[3] == 1 ? 4 : 16)).ToString();
                            var p = Read(s, 2); seen(host + ":" + (p[0] * 256 + p[1]));
                            if (mode == "refuse") { s.Write(new byte[] { 5, 5, 0, 1, 0, 0, 0, 0, 0, 0 }, 0, 10); return; }
                            s.Write(new byte[] { 5, 0, 0, 1, 0, 0, 0, 0, 0, 0 }, 0, 10);
                        } else {
                            var sb = new StringBuilder(); while (!sb.ToString().EndsWith("\r\n\r\n")) sb.Append((char)Read(s, 1)[0]);
                            seen(sb.ToString().Split(' ')[1]);
                            var reply = Encoding.ASCII.GetBytes(mode == "refuse" ? "HTTP/1.1 403 Forbidden\r\n\r\n" : "HTTP/1.1 200 Connection established\r\n\r\n");
                            s.Write(reply, 0, reply.Length); if (mode == "refuse") return;
                        }
                        var banner = Encoding.ASCII.GetBytes("SSH-2.0-fake\r\n"); s.Write(banner, 0, banner.Length);
                        var echo = new byte[64]; int n = s.Read(echo, 0, echo.Length); if (n > 0) s.Write(echo, 0, n);
                    }
                } catch { }
            }) { IsBackground = true }.Start();
            return l;
        }
        internal static void Run()
        {
            foreach (var kind in new[] { "socks", "http" }) {
                string seen = ""; var l = Serve(kind, "ok", x => seen = x); int port = ((IPEndPoint)l.LocalEndpoint).Port;
                using (var t = ProxyRelay.Connect(kind, "127.0.0.1", port, "server.example.invalid", 22, 3000)) {
                    var s = t.GetStream(); Check(Encoding.ASCII.GetString(Read(s, 14)) == "SSH-2.0-fake\r\n", kind + ": bytes after the handshake are not consumed");
                    s.Write(new byte[] { 1, 2, 3 }, 0, 3); Check(Read(s, 3)[2] == 3, kind + ": data flows both ways");
                }
                Check(seen == "server.example.invalid:22", kind + ": proxy asked for the requested destination (" + seen + ")");
                // Whole relay: stdin -> proxy -> stdout.
                l = Serve(kind, "ok", x => { }); port = ((IPEndPoint)l.LocalEndpoint).Port;
                var input = new MemoryStream(new byte[] { 9, 8, 7 }); var output = new MemoryStream();
                using (var t = ProxyRelay.Connect(kind, "127.0.0.1", port, "127.0.0.1", 22, 3000)) Check(ProxyRelay.Relay(t, input, output) == 0 && output.Length == 14 + 3, kind + ": relay copies banner and echo to stdout");
                l = Serve(kind, "refuse", x => { }); port = ((IPEndPoint)l.LocalEndpoint).Port; string error = "";
                try { ProxyRelay.Connect(kind, "127.0.0.1", port, "server.example.invalid", 22, 3000); } catch (IOException e) { error = e.Message; }
                Check(error.Contains("отказал"), kind + ": proxy refusal is a short error");
                l = Serve(kind, "silent", x => { }); port = ((IPEndPoint)l.LocalEndpoint).Port; error = "";
                var started = DateTime.UtcNow; try { ProxyRelay.Connect(kind, "127.0.0.1", port, "server.example.invalid", 22, 1000); } catch (IOException e) { error = e.Message; }
                Check(error.Length > 0 && (DateTime.UtcNow - started).TotalSeconds < 5, kind + ": silent proxy times out");
            }
            var dead = new TcpListener(IPAddress.Loopback, 0); dead.Start(); int closed = ((IPEndPoint)dead.LocalEndpoint).Port; dead.Stop(); string refused = "";
            try { ProxyRelay.Connect("socks", "127.0.0.1", closed, "h", 22, 2000); } catch (IOException e) { refused = e.Message; }
            Check(refused.Contains("не удалось подключиться"), "closed proxy port is reported");
            Console.WriteLine("OK: proxy relay self-test (fake SOCKS5 and HTTP CONNECT)");
        }
    }
}
