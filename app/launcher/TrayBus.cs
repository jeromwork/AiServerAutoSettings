using System;
using System.Collections.Generic;
using System.IO;

namespace RemoteAgents.Launcher
{
    // Шина в лаунчере (шаг B2): логика без WinForms, чтобы проверять её микро-тестами с ручной шиной.

    // Файлы status/<блок>.json -> block.ready | block.degraded. Публикуется только смена состояния блока.
    internal sealed class BlockStatusTracker
    {
        readonly EventBus bus; readonly object gate = new object();
        readonly Dictionary<string, bool> ready = new Dictionary<string, bool>(StringComparer.Ordinal);
        internal BlockStatusTracker(EventBus bus) { this.bus = bus; }

        // Тот же смысл «готов», что у Supervisor для файлов статуса: ok, а для vpn ещё и state=on.
        internal static bool IsReady(string block, Dictionary<string, object> status)
        {
            if (!Json.Bool(status, "ok")) return false;
            string phase = Json.Str(status, "phase");
            if (phase.Length > 0 && phase != "ok") return false;
            return block != "vpn" || Json.Str(status, "state") == "on";
        }
        internal bool IsBlockReady(string block) { lock (gate) { bool v; return ready.TryGetValue(block, out v) && v; } }

        internal void Observe(string block, Dictionary<string, object> status)
        {
            if (string.IsNullOrEmpty(block)) return;
            bool now = IsReady(block, status);
            lock (gate) {
                bool was; bool known = ready.TryGetValue(block, out was);
                if (known && was == now) return;
                ready[block] = now;
                if (now) bus.Publish(BusTopics.BlockReady, BusTopics.Sources.Tray, "block", block);
                else if (known) bus.Publish(BusTopics.BlockDegraded, BusTopics.Sources.Tray, "block", block, "reason", Json.Text(status, "summary", "not-ok"));
                // Первое наблюдение «не готов» ничего не публикует: готовность блока — единственный факт, который ждут подписчики.
            }
        }

        // Файл мог быть пойман посреди записи — тогда следующее событие файла повторит разбор.
        internal void ScanFile(string path)
        {
            try {
                if (!File.Exists(path)) return;
                Observe(Path.GetFileNameWithoutExtension(path), Json.Read(path));
            } catch (Exception) { } // файл пойман посреди записи или недоступен: ждём следующего события
        }
        internal void ScanAll(string dir)
        {
            try { foreach (var f in Directory.GetFiles(dir, "*.json")) ScanFile(f); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }

    // FileSystemWatcher на status/*.json; события файловой системы идут в трекер, таймеров нет.
    internal sealed class StatusDirWatcher : IDisposable
    {
        readonly FileSystemWatcher watcher; readonly BlockStatusTracker tracker; readonly string dir;
        internal StatusDirWatcher(string dir, BlockStatusTracker tracker)
        {
            this.dir = dir; this.tracker = tracker;
            watcher = new FileSystemWatcher(dir, "*.json") { NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.FileName | NotifyFilters.Size, InternalBufferSize = 32768 };
            watcher.Changed += (s, e) => tracker.ScanFile(e.FullPath);
            watcher.Created += (s, e) => tracker.ScanFile(e.FullPath);
            watcher.Renamed += (s, e) => tracker.ScanFile(e.FullPath);
            watcher.Error += (s, e) => tracker.ScanAll(dir); // переполнение буфера: пересмотреть все файлы
            watcher.EnableRaisingEvents = true;
            tracker.ScanAll(dir); // текущее состояние до первых изменений
        }
        public void Dispose() { try { watcher.Dispose(); } catch { } }
    }

    internal static class TrayBusWiring
    {
        // Supervisor: component.start {name} / component.exit {name, code}; без шины — тихо.
        internal static void ComponentStart(EventBus bus, string name)
        { if (bus != null) bus.Publish(BusTopics.ComponentStart, BusTopics.Sources.Tray, "name", name); }
        internal static void ComponentExit(EventBus bus, string name, int code)
        { if (bus != null) bus.Publish(BusTopics.ComponentExit, BusTopics.Sources.Tray, "name", name, "code", code.ToString(System.Globalization.CultureInfo.InvariantCulture)); }

        // update.requested (кнопка «Проверить обновления», запуск) -> проверка. start вызывается в нужном потоке самим вызывающим.
        internal static IDisposable WireUpdateRequests(EventBus bus, Action<bool> startUpdateCheck)
        { return bus.Subscribe(BusTopics.UpdateRequested, e => startUpdateCheck(true)); }

        // tick.update -> плановая проверка (не ручная); занятость решает вызывающий.
        internal static IDisposable WireUpdateTick(EventBus bus, Action scheduledCheck)
        { return bus.Subscribe(BusTopics.TickUpdate, e => scheduledCheck()); }

        // block.ready transport -> первый прогон сторожа сети вместо StartDelayMs.
        internal static IDisposable WireTransportReady(EventBus bus, Action transportReady)
        { return bus.Subscribe(BusTopics.BlockReady, e => { if (e.Get("block") == "transport") transportReady(); }); }
    }
}
