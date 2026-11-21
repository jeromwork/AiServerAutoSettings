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

        // Возраст статуса: от более позднего из «файл записан» и «процесс запущен» (зависший до первой записи тоже стареет).
        public static double AgeMs(DateTime fileModifiedUtc, DateTime nowUtc, DateTime startedUtc)
        {
            DateTime from = fileModifiedUtc > startedUtc ? fileModifiedUtc : startedUtc;
            return (nowUtc - from).TotalMilliseconds;
        }

        public static bool IsStale(DateTime fileModifiedUtc, DateTime nowUtc, int maxAgeSec, DateTime startedUtc)
        {
            return AgeMs(fileModifiedUtc, nowUtc, startedUtc) > FuseMs(maxAgeSec);
        }

        // Сон/пауза: если с прошлой проверки прошло больше половины предохранителя, настенные часы скакнули (выход из сна,
        // подвисший UI-поток) — возраст файла недостоверен; только обновить точку отсчёта (lastCheckUtc), не убивать.
        public static bool ClockJumped(DateTime lastCheckUtc, DateTime nowUtc, int maxAgeSec)
        {
            if (lastCheckUtc == DateTime.MinValue) return false;
            return (nowUtc - lastCheckUtc).TotalMilliseconds > FuseMs(maxAgeSec) / 2;
        }

        public static SupervisorDecision Decide(DateTime fileModifiedUtc, DateTime nowUtc, int maxAgeSec, DateTime startedUtc)
        {
            return IsStale(fileModifiedUtc, nowUtc, maxAgeSec, startedUtc)
                ? SupervisorDecision.KillAndRestart
                : SupervisorDecision.None;
        }

        public static SupervisorDecision Decide(DateTime fileModifiedUtc, DateTime nowUtc, int maxAgeSec, DateTime startedUtc, DateTime lastCheckUtc)
        {
            if (ClockJumped(lastCheckUtc, nowUtc, maxAgeSec)) return SupervisorDecision.None;
            return Decide(fileModifiedUtc, nowUtc, maxAgeSec, startedUtc);
        }
    }
}
