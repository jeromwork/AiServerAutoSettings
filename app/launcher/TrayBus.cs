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
        readonly Dictionary<string, string> reasons = new Dictionary<string, string>(StringComparer.Ordinal);
        readonly Dictionary<string, bool> ready = new Dictionary<string, bool>(StringComparer.Ordinal);
        // Файл статуса учитывается, только если записан не раньше since: запуска трея или последнего component.start/exit блока.
        readonly Dictionary<string, DateTime> since = new Dictionary<string, DateTime>(StringComparer.Ordinal);
        readonly DateTime started; readonly Func<DateTime> clock; readonly Func<string, DateTime> lastWrite;
        // clock/lastWrite передаются параметрами, чтобы тесты не зависели от реального времени и файловой системы.
        internal BlockStatusTracker(EventBus bus, DateTime startedUtc, Func<DateTime> clock = null, Func<string, DateTime> lastWrite = null)
        {
            this.bus = bus; started = startedUtc;
            this.clock = clock ?? (() => DateTime.UtcNow);
            this.lastWrite = lastWrite ?? (p => File.GetLastWriteTimeUtc(p));
            // Перезапуск компонента делает прежний файл статуса устаревшим: ждём новой записи.
            bus.Subscribe("component.", e => { if (e.Topic == BusTopics.ComponentStart || e.Topic == BusTopics.ComponentExit) Reset(e.Get("name")); });
        }
        internal void Reset(string block)
        {
            if (string.IsNullOrEmpty(block)) return;
            lock (gate) { ready.Remove(block); reasons.Remove(block); since[block] = clock(); }
        }
        bool Fresh(string block, DateTime modified)
        {
            lock (gate) { DateTime s; if (!since.TryGetValue(block, out s) || s < started) s = started; return modified >= s; }
        }

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
            // Факт отсутствия локальной сети из статуса транспорта (Р8), без возраста файла и текста summary.
            string reason = block == "transport" && Json.Str(status, "localNet") == "down" ? "no-network" : Json.Text(status, "summary", "not-ok");
            lock (gate) {
                bool was; bool known = ready.TryGetValue(block, out was);
                string previousReason; reasons.TryGetValue(block, out previousReason);
                if (known && was == now && (now || previousReason == reason)) return;
                reasons[block] = reason;
                ready[block] = now;
                if (now) bus.Publish(BusTopics.BlockReady, BusTopics.Sources.Tray, "block", block);
                else if (known || reason == "no-network") bus.Publish(BusTopics.BlockDegraded, BusTopics.Sources.Tray, "block", block, "reason", reason);
                // Первый no-network тоже публикуется: отсутствие сети засчитывается доской здоровья.
            }
        }

        // Файл мог быть пойман посреди записи — тогда следующее событие файла повторит разбор.
        internal void ScanFile(string path)
        {
            try {
                if (!File.Exists(path)) return;
                string block = Path.GetFileNameWithoutExtension(path);
                if (!Fresh(block, lastWrite(path))) return; // файл от прошлого запуска: не факт о текущем
                Observe(block, Json.Read(path));
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

    // Одна ждущая доставка тика в UI: пока предыдущая не выполнена, новые тики отбрасываются.
    internal sealed class TickGate
    {
        int pending;
        // post ставит действие в UI и возвращает false, если не смог (окно закрыто): тогда счётчик сбрасывается.
        internal bool Deliver(Func<Action, bool> post, Action work)
        {
            if (System.Threading.Interlocked.CompareExchange(ref pending, 1, 0) != 0) return false;
            bool posted = false;
            try { posted = post(() => { try { work(); } finally { System.Threading.Interlocked.Exchange(ref pending, 0); } }); }
            finally { if (!posted) System.Threading.Interlocked.Exchange(ref pending, 0); }
            return posted;
        }
        internal bool Pending { get { return System.Threading.Volatile.Read(ref pending) != 0; } }
    }

    internal static class TrayBusWiring
    {
        // Supervisor: component.start {name} / component.exit {name, code}; без шины — тихо.
        internal static void ComponentStart(EventBus bus, string name)
        { if (bus != null) bus.Publish(BusTopics.ComponentStart, BusTopics.Sources.Tray, "name", name); }
        internal static void ComponentExit(EventBus bus, string name, int code)
        { if (bus != null) bus.Publish(BusTopics.ComponentExit, BusTopics.Sources.Tray, "name", name, "code", code.ToString(System.Globalization.CultureInfo.InvariantCulture)); }
        internal static void ComponentStaleRestart(EventBus bus, string name)
        { if (bus != null) bus.Publish(BusTopics.ComponentStaleRestart, BusTopics.Sources.Tray, "name", name); }

        // tick.supervisor -> периодическая проверка зависших компонентов.
        internal static IDisposable WireSupervisorTick(EventBus bus, Action onTick)
        { return bus.Subscribe(BusTopics.TickSupervisor, e => onTick()); }

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
