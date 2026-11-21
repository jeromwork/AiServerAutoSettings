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

        internal sealed class InvalidReceiptException : Exception
        { internal InvalidReceiptException(string message) : base(message) { } }
        internal static Dictionary<string, object> ReadReceipt(string path)
        {
            string text;
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (var reader = new StreamReader(stream)) text = reader.ReadToEnd();
            // Ошибки парсера отделены от временных IO: повреждение имеет конечный исход.
            try {
                var record = Json.Parse(text) as Dictionary<string, object>;
                if (record == null) throw new InvalidReceiptException("Receipt must be an object");
                return record;
            } catch (InvalidReceiptException) { throw; }
            catch (Exception ex) { throw new InvalidReceiptException("Receipt JSON: " + ex.GetType().Name); }
        }
        internal interface IImageProcess : IDisposable
        {
            WaitHandle Exited { get; }
            bool HasExited { get; }
            bool CleanExit { get; }
        }
        // Это сам производственный цикл, а не модель состава хэндлов. Тест меняет только
        // источник процесса, часы и доставку WaitAny; квитанция и события остаются настоящими.
        internal static string WaitForOutcome(Func<bool> pending, Func<Dictionary<string, object>> read,
            WaitHandle changed, WaitHandle failed, Func<int, string, IImageProcess> openProcess,
            Func<int, string, int> noteCleanExit, Func<DateTime> clock, Func<WaitHandle[], int, int> wait)
        {
            IImageProcess process = null; int pid = 0; string started = ""; bool exitSignaled = false;
            DateTime deadline = clock().AddMilliseconds(HealthBoard.UpdateNoProgressFuseMs);
            try {
                while (pending()) {
                    Dictionary<string, object> record;
                    try { record = TryRead(read); }
                    catch (InvalidReceiptException) { return "invalid-receipt"; }
                    if (!pending()) return "";
                    if (record != null && Json.Bool(record, "healthAccepted")) return "";
                    if (failed.WaitOne(0)) return "UpdateFailed";
                    if (record != null) {
                        if (Json.Bool(record, "cleanExit")) return Decide(true, false, false, false, true, Json.Int(record, "cleanExitCount", 0));
                        if (!SameProcess(record, pid, started)) {
                            exitSignaled = false;
                            if (process != null) { process.Dispose(); process = null; }
                            pid = Json.Int(record, "pid", 0); started = Json.Str(record, "processStarted");
                            if (pid > 0) try { process = openProcess(pid, started); }
                            catch (ArgumentException) { return "process-exited"; }
                            catch (InvalidOperationException) { return "process-exited"; }
                            catch (System.ComponentModel.Win32Exception) { return "process-unavailable"; }
                        }
                        if (process != null && (exitSignaled || process.HasExited)) {
                            bool clean = process.CleanExit;
                            int count; bool writeUnavailable = false;
                            try { count = clean ? noteCleanExit(pid, started) : 0; }
                            catch (InvalidReceiptException) { return "invalid-receipt"; }
                            catch (IOException) { count = -1; writeUnavailable = true; }
                            catch (UnauthorizedAccessException) { count = -1; writeUnavailable = true; }
                            if (count >= 0) return Decide(true, false, true, false, clean, count);
                            if (!writeUnavailable) continue; // B уже заменил A: перечитать без ожидания ещё одного changed
                            exitSignaled = true; // при IO не зацикливаться на сигнальном хэндле
                        }
                        DateTime progress;
                        if (!DateTime.TryParse(Json.Text(record, "lastHealthUtc", Json.Str(record, "startedUtc")), null,
                            System.Globalization.DateTimeStyles.RoundtripKind, out progress)) return "invalid-receipt";
                        deadline = progress.ToUniversalTime().AddMilliseconds(HealthBoard.UpdateNoProgressFuseMs);
                    }
                    DateTime now = clock();
                    if (now >= deadline) return record == null ? "receipt-unavailable" : "no-progress-fuse";
                    int remaining = (int)Math.Max(1, Math.Min(HealthBoard.UpdateNoProgressFuseMs, Math.Ceiling((deadline - now).TotalMilliseconds)));
                    int signal = wait(OutcomeHandles(failed, changed, exitSignaled || process == null ? null : process.Exited), remaining);
                    // timer-ok: C — при недоступной квитанции/зависшем EXE прежний дедлайн даёт только отказ.
                    // Уже доставленный exited запомнен; без changed повторяем чтение на границе предохранителя.
                    if (signal == 2) exitSignaled = true;
                }
                return "";
            } finally { if (process != null) process.Dispose(); }
        }

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
