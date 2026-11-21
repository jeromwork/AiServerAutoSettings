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
        // timer-ok: C — Предохранитель (конституция 4а): свежий статус компонента недоступен, если процесс завис; при срабатывании — убить процесс и перезапустить, успех не объявляет.
        public const int StaleRestartFuseMs = 30000;

        public static int FuseMs(int maxAgeSec)
        {
            return Math.Max(StaleRestartFuseMs, 3 * maxAgeSec * 1000);
        }

        // Возраст статуса: от самого позднего из «файл записан», «процесс запущен» и «проверки возобновились после сна» (resyncUtc);
        // зависший до первой записи тоже стареет, а после сна компонент снова получает полный предохранитель.
        public static double AgeMs(DateTime fileModifiedUtc, DateTime nowUtc, DateTime startedUtc)
        {
            return AgeMs(fileModifiedUtc, nowUtc, startedUtc, DateTime.MinValue);
        }

        public static double AgeMs(DateTime fileModifiedUtc, DateTime nowUtc, DateTime startedUtc, DateTime resyncUtc)
        {
            DateTime from = fileModifiedUtc > startedUtc ? fileModifiedUtc : startedUtc;
            if (resyncUtc > from) from = resyncUtc;
            return (nowUtc - from).TotalMilliseconds;
        }

        public static bool IsStale(DateTime fileModifiedUtc, DateTime nowUtc, int maxAgeSec, DateTime startedUtc)
        {
            return AgeMs(fileModifiedUtc, nowUtc, startedUtc) > FuseMs(maxAgeSec);
        }

        // Сон/пауза: если с прошлой проверки прошло больше половины предохранителя, настенные часы скакнули (выход из сна,
        // подвисший UI-поток) — возраст файла недостоверен; не убивать, а запомнить время возобновления (resyncUtc),
        // от которого дальше считается возраст.
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
    }

    // Состояние проверок одного компонента (чистая логика, без часов и файлов — тестируется на фальшивых часах).
    public sealed class StaleChecker
    {
        DateTime lastCheckUtc = DateTime.MinValue;
        DateTime resyncUtc = DateTime.MinValue;

        // null: ожидаемый файл ещё не появился — возраст от старта/resyncUtc. statusExpected=false:
        // компонент не проверяется (отключён, остановлен или не пишет периодический статус); тик всё равно учитывается.
        public SupervisorDecision Check(DateTime? fileModifiedUtc, DateTime nowUtc, int maxAgeSec, DateTime startedUtc, bool statusExpected = true)
        {
            bool jumped = SupervisorStale.ClockJumped(lastCheckUtc, nowUtc, maxAgeSec);
            lastCheckUtc = nowUtc;
            if (jumped) resyncUtc = nowUtc;
            if (jumped || !statusExpected) return SupervisorDecision.None;
            return AgeMs(fileModifiedUtc, nowUtc, startedUtc) > SupervisorStale.FuseMs(maxAgeSec)
                ? SupervisorDecision.KillAndRestart
                : SupervisorDecision.None;
        }

        public double AgeMs(DateTime? fileModifiedUtc, DateTime nowUtc, DateTime startedUtc)
        {
            return SupervisorStale.AgeMs(fileModifiedUtc ?? startedUtc, nowUtc, startedUtc, resyncUtc);
        }
    }
}
