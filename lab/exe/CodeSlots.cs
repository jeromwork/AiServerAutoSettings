using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace RemoteAgents.Lab
{
    internal enum SlotAction { Restart, Stop }

    // Какая версия кода (папка code\<имя>) сейчас запускается, какая проверена (lastGood) и что делать, когда Python вышел.
    // Состояние -- code\state.json, запись атомарно. Решения принимает только эта часть; таймеров здесь нет.
    internal sealed class CodeSlots
    {
        public string Current, LastGood, EmbeddedSeen, RollbackReason;
        public int FailsGood, MemRestarts;
        public string Reason = "";          // причина последнего решения, для журнала и значка
        readonly string codeDir, embedded;
        static readonly Regex NameRule = new Regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$");
        public const int MaxFailsGood = 3, MaxMemRestarts = 3;
        public const double LongRunSeconds = 600;   // читаем часы при выходе, ничего не ждём

        CodeSlots(string codeDir, string embedded) { this.codeDir = codeDir; this.embedded = embedded; }
        public string StatePath { get { return Path.Combine(codeDir, "state.json"); } }
        public string PendingPath { get { return Path.Combine(codeDir, "pending.json"); } }
        public bool Unverified { get { return Current != LastGood; } }
        public bool Exists(string name) { return name != null && NameRule.IsMatch(name) && File.Exists(Path.Combine(codeDir, name, "run_lab.py")); }
        public string ScriptPath { get { return Path.Combine(codeDir, Current, "run_lab.py"); } }

        public static CodeSlots Load(string codeDir, string embedded, Action<string> log)
        {
            var slots = new CodeSlots(codeDir, embedded);
            try {
                var json = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(slots.StatePath, Encoding.UTF8).TrimStart('﻿'));
                slots.Current = Text(json, "current"); slots.LastGood = Text(json, "lastGood"); slots.EmbeddedSeen = Text(json, "embeddedSeen");
                slots.RollbackReason = Text(json, "rollbackReason");
                slots.FailsGood = Num(json, "failsGood"); slots.MemRestarts = Num(json, "memRestarts");
            } catch (FileNotFoundException) { slots.Current = null; }
            catch (DirectoryNotFoundException) { slots.Current = null; }
            catch (Exception ex) { log("state.json повреждён (" + ex.GetType().Name + "), беру встроенную версию"); slots.Current = null; slots.LastGood = null; slots.EmbeddedSeen = null; }
            // Новая сборка EXE (встроенный код новый) или битое/пустое состояние -- встроенная версия становится текущей.
            if (slots.EmbeddedSeen != embedded || slots.Current == null || !slots.Exists(slots.Current)) {
                if (slots.EmbeddedSeen == embedded && slots.Current != null) log("версия " + slots.Current + " исчезла с диска, беру встроенную");
                slots.Current = embedded; slots.EmbeddedSeen = embedded; slots.FailsGood = 0; slots.MemRestarts = 0;
            }
            if (slots.LastGood != null && !slots.Exists(slots.LastGood)) slots.LastGood = null;
            slots.Save();
            return slots;
        }

        static string Text(Dictionary<string, object> json, string key) { object v; return json.TryGetValue(key, out v) && v is string && ((string)v).Length > 0 ? (string)v : null; }
        static int Num(Dictionary<string, object> json, string key) { object v; return json.TryGetValue(key, out v) && v is int ? Math.Max(0, Math.Min(1000, (int)v)) : 0; }

        public void Save()
        {
            var json = new Dictionary<string, object> {
                { "current", Current }, { "lastGood", LastGood }, { "embeddedSeen", EmbeddedSeen }, { "failsGood", FailsGood },
                { "memRestarts", MemRestarts }, { "rollbackReason", RollbackReason }
            };
            Directory.CreateDirectory(codeDir);
            string temp = StatePath + ".tmp";
            File.WriteAllText(temp, new JavaScriptSerializer().Serialize(json), new UTF8Encoding(false));
            if (File.Exists(StatePath)) File.Replace(temp, StatePath, null); else File.Move(temp, StatePath);
        }

        // Python прислал good (первый channel.up): текущая версия проверена.
        public void MarkGood() { LastGood = Current; FailsGood = 0; MemRestarts = 0; RollbackReason = null; Save(); }

        // Вернуть имя папки из pending.json (и удалить файл), если она годна. Иначе null.
        public string TakePending(Action<string> log)
        {
            string name = null;
            try {
                if (!File.Exists(PendingPath)) return null;
                var json = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(PendingPath, Encoding.UTF8).TrimStart('﻿'));
                name = Text(json, "dir");
            } catch (Exception ex) { log("pending.json нечитаем: " + ex.GetType().Name); }
            try { File.Delete(PendingPath); } catch { }
            if (name == null || !Exists(name)) { log("pending.json указывает на негодную папку, перезапускаю прежнюю версию"); return null; }
            return name;
        }

        // Python вышел. code -- код выхода; timeoutV -- сработал таймер В; requested -- перезапуск по кнопке в трее.
        public SlotAction OnExit(int code, bool timeoutV, bool requested, double ranSeconds, bool goodSeen, Action<string> log)
        {
            Reason = "";
            if (requested) { Reason = "перезапуск по просьбе владельца"; return SlotAction.Restart; }
            if (!timeoutV && code == 3) {
                string next = TakePending(log);
                if (next != null && next != Current) { Current = next; FailsGood = 0; MemRestarts = 0; Reason = "новая версия кода " + next; Save(); return SlotAction.Restart; }
                // Непроверенная версия, которая перезапускает себя без нового кода, -- это петля без пауз: считаем падением.
                if (!Unverified) { Reason = "перезапуск по просьбе Python (код 3)"; Save(); return SlotAction.Restart; }
            }
            if (!timeoutV && code == 4) {
                MemRestarts++;
                if (MemRestarts > MaxMemRestarts) { Reason = "память Python превышена " + MemRestarts + " раз подряд"; Save(); return SlotAction.Stop; }
                Reason = "перезапуск из-за памяти (" + MemRestarts + " из " + MaxMemRestarts + ")"; Save(); return SlotAction.Restart;
            }
            string why = timeoutV ? "версия " + Current + " не подняла канал за 120 с" : code == 0 ? "версия " + Current + " вышла с кодом 0 без просьбы" : "версия " + Current + " упала с кодом " + code;
            // Для Python (--rollback-reason) и сервера причина по-английски и только из ASCII.
            string whyEn = timeoutV ? "version " + Current + " did not bring the channel up in 120 s" : code == 0 ? "version " + Current + " exited with code 0 unrequested" : "version " + Current + " crashed, exit code " + code;
            if (Unverified) {
                if (LastGood != null) { Current = LastGood; RollbackReason = whyEn; FailsGood = 0; MemRestarts = 0; Reason = "откат на " + LastGood + ": " + why; Save(); return SlotAction.Restart; }
                if (Current != embedded && Exists(embedded)) { Current = embedded; RollbackReason = whyEn; FailsGood = 0; MemRestarts = 0; Reason = "откат на встроенную версию: " + why; Save(); return SlotAction.Restart; }
            } else if (goodSeen && ranSeconds >= LongRunSeconds) FailsGood = 0; // долго работала -- это не цепочка падений
            FailsGood++;
            if (FailsGood >= MaxFailsGood) { Reason = why + "; подряд падений: " + FailsGood; Save(); return SlotAction.Stop; }
            Reason = why + "; перезапуск (" + FailsGood + " из " + MaxFailsGood + ")"; Save(); return SlotAction.Restart;
        }

        public void ResetAfterStop() { FailsGood = 0; MemRestarts = 0; Save(); }

        // Папки code\ вне Current/LastGood/встроенной не удаляем здесь: за счёт папок отвечает updater Python (не больше 5);
        // при потере папки Load вернёт встроенную версию, она всегда восстанавливается из EXE.
        public static bool ValidName(string name) { return name != null && NameRule.IsMatch(name); }
    }
}
