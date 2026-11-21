using System;
using System.Collections.Generic;
using System.IO;

namespace RemoteAgents.Launcher
{
    // Общий вердикт наблюдателя: адаптер ждёт хэндлы Windows, микро-тесты подают события вручную.
    internal static class UpdateObservation
    {
        // Временная ошибка замены квитанции не является отказом обновления.
        internal static Dictionary<string, object> TryRead(Func<Dictionary<string, object>> read)
        {
            try { return read(); }
            catch (IOException) { return null; }
            catch (UnauthorizedAccessException) { return null; }
        }
        internal static bool SameProcess(Dictionary<string, object> record, int pid, string started)
        { return Json.Int(record, "pid", 0) == pid && Json.Str(record, "processStarted") == started; }

        // null — ждать следующее событие; пустая строка — квитанция удалена при приёмке.
        internal static string Decide(bool pending, bool failed, bool processExited, bool fuse, bool cleanExit = false)
        {
            if (!pending) return "";
            if (failed) return "UpdateFailed";
            if (cleanExit) return ""; // приёмка отложена до следующего запуска, квитанция остаётся
            if (processExited) return "process-exited";
            if (fuse) return "no-progress-fuse";
            return null;
        }
    }
}
