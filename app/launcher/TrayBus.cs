using System;
using System.Collections.Generic;
using System.IO;
using System.Text.RegularExpressions;

namespace RemoteAgents.Launcher
{
    // Шина в лаунчере (шаг B2): логика без WinForms, чтобы проверять её микро-тестами с ручной шиной.

    // Файлы status/<блок>.json -> block.ready | block.degraded. Публикуется только смена состояния блока.
    internal sealed class BlockStatusTracker
    {
        readonly EventBus bus; readonly object gate = new object();
        internal const int MaxBlocks = 64; // неизвестные имена сверх лимита игнорируются до перезапуска трекера
        readonly Dictionary<string, string> states = new Dictionary<string, string>(StringComparer.Ordinal);
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
            block = BlockName(block);
            if (block.Length == 0) return;
            lock (gate) {
                if (!since.ContainsKey(block) && since.Count >= MaxBlocks) return;
                ready.Remove(block); reasons.Remove(block); states.Remove(block); since[block] = clock();
            }
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
        static string BlockName(string block)
        {
            block = (block ?? "").ToLowerInvariant();
            if (!Regex.IsMatch(block, @"^[a-z0-9_-]{1,64}$")) return "";
            return block == "bridge" ? "control" : block;
        }
        internal int TrackedBlocks { get { lock (gate) return ready.Count; } }
        internal bool IsBlockReady(string block) { lock (gate) { bool v; return ready.TryGetValue(BlockName(block), out v) && v; } }

        internal void Observe(string block, Dictionary<string, object> status)
        {
            block = BlockName(block);
            if (block.Length == 0) return;
            bool now = IsReady(block, status);
            string topic = now ? BusTopics.BlockReady : Json.Str(status, "phase") == "failed" ? BusTopics.BlockFailed : BusTopics.BlockDegraded;
            // Факт отсутствия локальной сети из статуса транспорта (Р8), без возраста файла и текста summary.
            string reason = block == "transport" && Json.Str(status, "localNet") == "down" ? "no-network" : Json.Text(status, "summary", "not-ok");
            lock (gate) {
                bool known = ready.ContainsKey(block);
                if (!known && ready.Count >= MaxBlocks) return;
                string previousState; states.TryGetValue(block, out previousState);
                string previousReason; reasons.TryGetValue(block, out previousReason);
                if (known && previousState == topic && (now || previousReason == reason)) return;
                states[block] = topic;
                reasons[block] = reason;
                ready[block] = now;
                if (now) bus.Publish(BusTopics.BlockReady, BusTopics.Sources.Tray, "block", block);
                else if (known || reason == "no-network" || topic == BusTopics.BlockFailed) bus.Publish(topic, BusTopics.Sources.Tray, "block", block, "reason", reason);
                // Первый no-network тоже публикуется: отсутствие сети засчитывается доской здоровья.
            }
        }

        // Файл мог быть пойман посреди записи — тогда следующее событие файла повторит разбор.
        internal void ScanFile(string path)
        {
            try {
                // ReplaceFile (Files.Atomic) на Windows создаёт служебные *.json~RF<hex>.TMP.
                // DOS/8.3-маска FileSystemWatcher может пропустить их даже с фильтром *.json.
                // Такой сигнал лишь перечитывает конечный .json; содержимое временного файла не есть готовность.
                var match = Regex.Match(Path.GetFileName(path), @"^([a-z0-9_-]{1,64})\.json(?:~RF[0-9a-f]+(?:\.tmp)?)?$", RegexOptions.IgnoreCase);
                if (!match.Success) return;
                string name = match.Groups[1].Value;
                path = Path.Combine(Path.GetDirectoryName(path), name + ".json");
                if (!File.Exists(path)) return;
                string block = BlockName(name);
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
            watcher.Renamed += (s, e) => { tracker.ScanFile(e.FullPath); tracker.ScanFile(e.OldFullPath); };
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
