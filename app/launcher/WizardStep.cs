using System;
using System.Diagnostics;
using System.IO;
using System.Threading;

namespace RemoteAgents.Launcher
{
    internal static class WizardStep
    {
        internal static int Timeout(string action) { return action == "DiskTree" ? 60000 : action == "Disk" ? 300000 : 120000; }
        // Shared by real external steps and the portable process tests. NativeJob owns the process tree.
        internal static int Wait(Process process, string output, int timeoutMs, long maxBytes, CancellationToken token)
        {
            var watch = Stopwatch.StartNew();
            while (!process.WaitForExit(100)) {
                token.ThrowIfCancellationRequested();
                if (watch.ElapsedMilliseconds >= timeoutMs)
                    throw new TimeoutException("Превышено время ожидания (" + (timeoutMs / 1000) + " с). Проверьте связь и повторите шаг.");
                if (output != null && new FileInfo(output).Length > maxBytes) throw new IOException("Вывод команды слишком велик");
            }
            token.ThrowIfCancellationRequested();
            if (output != null && new FileInfo(output).Length > maxBytes) throw new IOException("Вывод команды слишком велик");
            return process.ExitCode;
        }
    }
}
