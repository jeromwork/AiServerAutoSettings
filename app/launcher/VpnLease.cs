using System;
using System.Diagnostics;
using System.Threading;

namespace RemoteAgents.Launcher
{
    // A blocked status-file read or Windows API must not block fail-open.
    // This thread does no I/O: it only closes the core's Job when the host stops advancing.
    internal sealed class VpnLease : IDisposable
    {
        internal const int DeadlineMs = 2500, HealthDeadlineMs = 4500;
        readonly ManualResetEvent stop = new ManualResetEvent(false);
        readonly Thread thread;
        readonly Stopwatch clock = Stopwatch.StartNew();
        long pulse, confirmed;
        int expired;
        internal bool Expired { get { return Interlocked.CompareExchange(ref expired, 0, 0) != 0; } }
        internal VpnLease(Action close, int deadlineMs = DeadlineMs, int healthDeadlineMs = HealthDeadlineMs)
        {
            thread = new Thread(() => {
                while (!stop.WaitOne(VpnWatchdog.PollMs)) {
                    long now = clock.ElapsedMilliseconds;
                    if (now - Interlocked.Read(ref pulse) <= deadlineMs && now - Interlocked.Read(ref confirmed) <= healthDeadlineMs) continue;
                    Interlocked.Exchange(ref expired, 1); close(); break;
                }
            }) { IsBackground = true, Name = "VPN fail-open lease" };
            thread.Start();
        }
        internal void Pulse() { Interlocked.Exchange(ref pulse, clock.ElapsedMilliseconds); }
        internal void Confirmed() { Interlocked.Exchange(ref confirmed, clock.ElapsedMilliseconds); }
        public void Dispose() { stop.Set(); thread.Join(); stop.Dispose(); }
    }
}
