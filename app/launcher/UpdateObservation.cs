namespace RemoteAgents.Launcher
{
    // Общий вердикт наблюдателя: адаптер ждёт хэндлы Windows, микро-тесты подают события вручную.
    internal static class UpdateObservation
    {
        // null — ждать следующее событие; пустая строка — квитанция удалена при приёмке.
        internal static string Decide(bool pending, bool failed, bool processExited, bool fuse)
        {
            if (!pending) return "";
            if (failed) return "UpdateFailed";
            if (processExited) return "process-exited";
            if (fuse) return "no-progress-fuse";
            return null;
        }
    }
}
