using System;
using System.Diagnostics;
using System.Threading;

namespace RemoteAgents.Launcher
{
    // A blocked status-file read or Windows API must not block fail-open.
    // This thread does no I/O: it only closes the core's Job when the host stops advancing.
    internal sealed class VpnLease : IDisposable
    {
        internal const int DeadlineMs = 2500;
        readonly ManualResetEvent stop = new ManualResetEvent(false);
        readonly Thread thread;
        readonly Stopwatch clock = Stopwatch.StartNew();
        long pulse;
        int expired;
        internal bool Expired { get { return Interlocked.CompareExchange(ref expired, 0, 0) != 0; } }
        internal VpnLease(Action close, int deadlineMs = DeadlineMs)
        {
            thread = new Thread(() => {
                while (!stop.WaitOne(VpnWatchdog.PollMs)) {
                    if (clock.ElapsedMilliseconds - Interlocked.Read(ref pulse) <= deadlineMs) continue;
                    Interlocked.Exchange(ref expired, 1); close(); break;
                }
            }) { IsBackground = true, Name = "VPN fail-open lease" };
            thread.Start();
        }
        internal void Pulse() { Interlocked.Exchange(ref pulse, clock.ElapsedMilliseconds); }
        public void Dispose() { stop.Set(); thread.Join(); stop.Dispose(); }
    }
}
