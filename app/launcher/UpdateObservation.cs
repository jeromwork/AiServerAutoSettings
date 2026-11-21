using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;

namespace RemoteAgents.Launcher
{
    // Общий вердикт наблюдателя: адаптер ждёт хэндлы Windows, микро-тесты подают события вручную.
    internal static class UpdateObservation
    {
        internal const int CleanExitLimit = 3;

        // Исключение отката не должно повторно вооружать сохранённый отказ при перезапуске трея.
        internal static bool TryRollback(Action rollback, Action<string> reportFailure)
        {
            try { rollback(); return true; }
            catch (Exception ex) { reportFailure("rollback-failed:" + ex.GetType().Name); return false; }
        }
        internal static void RecordRollbackFailure(string home, string reason)
        {
            var log = new Journal(home); log.Write("update.rollback.failed reason=" + reason);
            string path = Path.Combine(home, Product.BundleDirectory, "update-state.json");
            Dictionary<string, object> state;
            try { state = File.Exists(path) ? Json.Read(path) : Json.Map(null); }
            catch (Exception ex) { log.Write("update.state.read.failed kind=" + ex.GetType().Name); state = Json.Map(null); }
            state["pending"] = false; state["failureReason"] = reason; Json.Write(path, state);
        }
        internal static WaitHandle[] OutcomeHandles(WaitHandle failed, WaitHandle changed, WaitHandle exited)
        { return exited == null ? new[] { failed, changed } : new[] { failed, changed, exited }; }

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
        internal static string Decide(bool pending, bool failed, bool processExited, bool fuse, bool cleanExit = false, int cleanExitCount = 0)
        {
            if (!pending) return "";
            if (failed) return "UpdateFailed";
            if (cleanExit) return cleanExitCount >= CleanExitLimit ? "clean-exit-loop" : ""; // первые два выхода откладывают приёмку
            if (processExited) return "process-exited";
            if (fuse) return "no-progress-fuse";
            return null;
        }
    }
}
