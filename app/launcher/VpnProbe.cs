using System;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;

namespace RemoteAgents.Launcher
{
    // A fixed synthetic IPv4 target avoids uncancellable system DNS waits.
    // sing-box rewrites it to the check host through the selected VPN outbound.
    // SNI and certificate validation still use the configured HTTPS host.
    // This executable is deliberately NOT in the VPN process bypass list.
    internal sealed class VpnProbe : IDisposable
    {
        readonly TcpClient client = new TcpClient(AddressFamily.InterNetwork);
        readonly System.Threading.Timer deadline;
        internal readonly Task<bool> Result;
        internal VpnProbe(Uri url, IPAddress address, int tunIndex, int timeoutMs = VpnWatchdog.ProbeTimeoutMs)
        {
            deadline = new System.Threading.Timer(_ => client.Close(), null, timeoutMs, System.Threading.Timeout.Infinite);
            Result = Check(url, address, tunIndex);
        }
        async Task<bool> Check(Uri url, IPAddress address, int tunIndex)
        {
            try {
                uint index;
                if (GetBestInterface(BitConverter.ToUInt32(address.GetAddressBytes(), 0), out index) != 0 || index != tunIndex) return false;
                await client.ConnectAsync(address, url.Port).ConfigureAwait(false);
                using (var tls = new SslStream(client.GetStream(), false)) {
                    await tls.AuthenticateAsClientAsync(url.DnsSafeHost).ConfigureAwait(false);
                    byte[] request = Encoding.ASCII.GetBytes("GET " + url.PathAndQuery + " HTTP/1.1\r\nHost: " + url.Authority + "\r\nConnection: close\r\n\r\n");
                    await tls.WriteAsync(request, 0, request.Length).ConfigureAwait(false);
                    // Read only the bounded status line. No body, speed test or redirects.
                    var line = new MemoryStream(); var one = new byte[1];
                    while (line.Length < 256 && await tls.ReadAsync(one, 0, 1).ConfigureAwait(false) == 1) {
                        if (one[0] == 10) break; line.WriteByte(one[0]);
                    }
                    string text = Encoding.ASCII.GetString(line.ToArray());
                    return text.StartsWith("HTTP/1.", StringComparison.Ordinal) && text.Length > 11 && text[9] == '2' && char.IsDigit(text[10]) && char.IsDigit(text[11]);
                }
            } catch { return false; }
            finally { deadline.Dispose(); }
        }
        public void Dispose() { client.Close(); deadline.Dispose(); }
        [DllImport("iphlpapi.dll")] static extern uint GetBestInterface(uint destination, out uint index);
    }
}
