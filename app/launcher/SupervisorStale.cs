using System;

namespace RemoteAgents.Launcher
{
    public enum SupervisorDecision
    {
        None,
        KillAndRestart
    }

    public static class SupervisorStale
    {
        // Предохранитель (конституция 4а): свежий статус компонента недоступен, если процесс завис; при срабатывании — убить процесс и перезапустить, успех не объявляет.
        public const int StaleRestartFuseMs = 30000;

        public static int FuseMs(int maxAgeSec)
        {
            return Math.Max(StaleRestartFuseMs, 3 * maxAgeSec * 1000);
        }

        public static bool IsStale(DateTime fileModifiedUtc, DateTime nowUtc, int maxAgeSec, DateTime startedUtc)
        {
            if (fileModifiedUtc < startedUtc) return false;
            double ageMs = (nowUtc - fileModifiedUtc).TotalMilliseconds;
            return ageMs > FuseMs(maxAgeSec);
        }

        public static SupervisorDecision Decide(DateTime fileModifiedUtc, DateTime nowUtc, int maxAgeSec, DateTime startedUtc)
        {
            return IsStale(fileModifiedUtc, nowUtc, maxAgeSec, startedUtc)
                ? SupervisorDecision.KillAndRestart
                : SupervisorDecision.None;
        }
    }
}
