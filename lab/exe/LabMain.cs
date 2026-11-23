using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using System.IO.Compression;

namespace RemoteAgents.Lab
{
    // EXE-сторож: распаковывает Python и код, запускает Python и перезапускает его. Логики связи здесь нет.
    // Протокол с Python (JSON-строки UTF-8): lab/exe/PROTOCOL в отчёте этапа; кратко --
    //   Python -> EXE (stdout): {"t":"state","color":"grey|yellow|green|red","tip":"..","lines":[..]}, {"t":"good","version":".."}, {"t":"report","text":".."}
    //   EXE -> Python (stdin):  {"t":"exit"}, {"t":"report"};  EOF stdin = выход.
    //   Коды выхода Python: 0 выход по просьбе, 3 перезапуск (code\pending.json -- новая версия), 4 память (та же версия), прочее -- падение.
    internal static class LabMain
    {
        [STAThread]
        static int Main(string[] args)
        {
            if (Array.IndexOf(args, "--disk-shell") >= 0) return LabDisk.ForwardShell(args); // V9: запрос из меню Проводника, до проверки mutex
            bool created;
            using (var mutex = new Mutex(true, @"Local\RemoteAgents-Lab", out created))
            {
                if (!created) { MessageBox.Show("RemoteAgents-Lab уже запущена: значок в области уведомлений.", "RemoteAgents-Lab"); return 1; }
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                string home = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RemoteAgents-lab");
                var log = new ExeLog(Path.Combine(home, "logs", "exe.log"));
                Application.ThreadException += (s, e) => log.Write("исключение UI: " + e.Exception);
                AppDomain.CurrentDomain.UnhandledException += (s, e) => log.Write("необработанное исключение: " + e.ExceptionObject);
                var ui = new Control(); var handle = ui.Handle; // обработчики событий процессов возвращаются в поток интерфейса через ui.BeginInvoke
                var supervisor = new Supervisor(home, log, ui);
                var tray = new LabTray(supervisor);
                supervisor.Begin();
                Application.Run(tray);
                supervisor.Dispose();
                log.Write("EXE закрыт");
                GC.KeepAlive(handle);
                return 0;
            }
        }
    }

    // exe.log: до 1 МБ, 2 файла (exe.log и exe.log.1).
    internal sealed class ExeLog
    {
        const long Limit = 1024 * 1024;
        readonly string path; readonly object gate = new object();
        public ExeLog(string path) { this.path = path; }
        public void Write(string text)
        {
            lock (gate) {
                try {
                    Directory.CreateDirectory(Path.GetDirectoryName(path));
                    if (File.Exists(path) && new FileInfo(path).Length > Limit) { try { File.Delete(path + ".1"); } catch { } File.Move(path, path + ".1"); }
                    File.AppendAllText(path, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + " " + text.Replace("\r", "").Replace("\n", " | ") + "\r\n", new UTF8Encoding(false));
                } catch { }
            }
        }
        public string Tail(int lines)
        {
            lock (gate) {
                try {
                    using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                    using (var reader = new StreamReader(stream, Encoding.UTF8)) {
                        var queue = new Queue<string>(); string line;
                        while ((line = reader.ReadLine()) != null) { queue.Enqueue(line); if (queue.Count > lines) queue.Dequeue(); }
                        return string.Join("\r\n", queue);
                    }
                } catch { return "(exe.log недоступен)"; }
            }
        }
    }

    internal sealed class LabState { public string Color = "grey"; public string Tip = "Запуск"; public string[] Lines = new string[0]; }

    internal sealed class PyRun
    {
        public Process Proc; public int Generation; public DateTime Started = DateTime.UtcNow;
        public bool GoodSeen, TimeoutFired, RestartRequested;
        public Thread Out, Err; public readonly ManualResetEventSlim Ready = new ManualResetEventSlim(false);
        public StreamWriter Input; public readonly object InputGate = new object();
    }

    internal sealed class Supervisor : IDisposable
    {
        public const int RestartGraceSeconds = 45;        // ожидание мягкого выхода Python при перезапуске; худший stop() TUN ~26 с, app.py ждёт до 40 с
        public const int PythonSilenceFuseSeconds = 120;   // таймер В
        const int MaxLine = 200000, MaxQueuedLines = 1000, MaxStderrLogged = 200, StderrTail = 30;
        public readonly string Home, Version;
        readonly ExeLog log; readonly Control ui; readonly LabJob job = new LabJob();
        readonly System.Windows.Forms.Timer timerV = new System.Windows.Forms.Timer();
        public CodeSlots Slots; public LabState State = new LabState();
        public volatile string DiskHome = ""; public volatile bool DiskRunning;   // Python сообщил «Диск: работает» (поле disk:true в state); читает поток Проводника
        public void WriteLog(string text) { log.Write(text); }
        public event Action StateChanged; public event Action<string> ReportReady; public event Action Quit;
        PyRun run; int generation, queuedLines; bool exitRequested, stopped, disposed;
        string pythonExe, embeddedName, stopReason = "";
        readonly Queue<string> stderrTail = new Queue<string>();

        public Supervisor(string home, ExeLog log, Control ui)
        {
            Home = home; this.log = log; this.ui = ui;
            var attr = typeof(Supervisor).Assembly.GetCustomAttributes(typeof(AssemblyInformationalVersionAttribute), false).OfType<AssemblyInformationalVersionAttribute>().FirstOrDefault();
            Version = Clean(attr != null ? attr.InformationalVersion : "dev", 80);
            // Таймер В. Почему нет события: присланный код может не упасть, а повиснуть -- тогда никто ничего не сообщит,
            // и без этого предохранителя ПК остался бы без связи до прихода владельца. Успеха таймер никогда не объявляет.
            timerV.Interval = PythonSilenceFuseSeconds * 1000;
            timerV.Tick += (s, e) => {
                timerV.Stop();
                var r = run; if (r == null) return;
                log.Write("таймер В: версия " + Slots.Current + " не подняла канал за " + PythonSilenceFuseSeconds + " с, гашу Python");
                r.TimeoutFired = true; job.Terminate();
            };
        }
        public bool IsRunning { get { return run != null; } }
        public bool IsAdmin { get { try { return new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator); } catch { return false; } } }

        void Post(Action action) { try { if (!disposed) ui.BeginInvoke(action); } catch (InvalidOperationException) { } }
        void SetState(string color, string tip, params string[] lines)
        {
            var dash = Version.IndexOf('-'); var stage = dash > 0 ? Version.Substring(0, dash) : Version;
            tip = stage + " \u00b7 " + tip;
            State = new LabState { Color = color, Tip = tip.Length > 63 ? tip.Substring(0, 63) : tip, Lines = lines };
            var handler = StateChanged; if (handler != null) handler();
        }
        static string Clean(string text, int max)
        {
            var sb = new StringBuilder();
            foreach (char c in text ?? "") { if (sb.Length >= max) break; sb.Append(char.IsLetterOrDigit(c) && c < 128 || c == '.' || c == '_' || c == '-' || c == ' ' || c == ':' || c == '+' ? c : '_'); }
            return sb.ToString();
        }

        public void Begin()
        {
            log.Write("EXE " + Version + " запущен, админ=" + IsAdmin + ", home=" + Home);
            SetState("grey", "Запуск", "Распаковка");
            try {
                foreach (var sub in new[] { "runtime", "code", "logs", "undo", "state" }) Directory.CreateDirectory(Path.Combine(Home, sub));
                Unpack();
                WriteStopCmd();
                Slots = CodeSlots.Load(Path.Combine(Home, "code"), embeddedName, log.Write);
            } catch (Exception ex) {
                log.Write("не удалось подготовиться: " + ex);
                stopped = true; stopReason = "не удалось распаковать: " + ex.Message;
                SetState("red", "Ошибка запуска", stopReason);
                return;
            }
            StartPython();
        }

        // ---- распаковка (во временную папку, затем Directory.Move) ----
        void Unpack()
        {
            foreach (var parent in new[] { "runtime", "code" })
                foreach (var dir in Directory.GetDirectories(Path.Combine(Home, parent), ".tmp-*")) try { Directory.Delete(dir, true); } catch { }
            string pyHash = ResourceHash("python-embed.zip"), codeHash = ResourceHash("lab-code.zip");
            string pyDir = Path.Combine(Home, "runtime", "py-" + pyHash);
            if (!File.Exists(Path.Combine(pyDir, ".ok"))) { ExtractResource("python-embed.zip", pyDir); log.Write("распакован Python py-" + pyHash); }
            pythonExe = Path.Combine(pyDir, "python.exe");
            embeddedName = "emb-" + codeHash;
            string codeDir = Path.Combine(Home, "code", embeddedName);
            if (!File.Exists(Path.Combine(codeDir, ".ok"))) { ExtractResource("lab-code.zip", codeDir); log.Write("распакован встроенный код " + embeddedName); }
            foreach (var old in Directory.GetDirectories(Path.Combine(Home, "runtime"), "py-*")) if (Path.GetFileName(old) != "py-" + pyHash) try { Directory.Delete(old, true); } catch { }
        }
        static byte[] ResourceBytes(string name)
        {
            using (var stream = typeof(Supervisor).Assembly.GetManifestResourceStream(name)) {
                if (stream == null) throw new InvalidOperationException("в EXE нет ресурса " + name);
                var memory = new MemoryStream(); stream.CopyTo(memory); return memory.ToArray();
            }
        }
        static string ResourceHash(string name)
        {
            using (var sha = SHA256.Create()) return string.Concat(sha.ComputeHash(ResourceBytes(name)).Take(6).Select(b => b.ToString("x2")));
        }
        static void ExtractResource(string name, string target)
        {
            string parent = Path.GetDirectoryName(target);
            string temp = Path.Combine(parent, ".tmp-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(temp);
            using (var zip = new ZipArchive(new MemoryStream(ResourceBytes(name)), ZipArchiveMode.Read)) {
                string root = Path.GetFullPath(temp) + Path.DirectorySeparatorChar;
                foreach (var entry in zip.Entries) {
                    if (entry.FullName.EndsWith("/")) continue;
                    string dest = Path.GetFullPath(Path.Combine(temp, entry.FullName));
                    if (!dest.StartsWith(root, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("путь вне папки: " + entry.FullName);
                    Directory.CreateDirectory(Path.GetDirectoryName(dest));
                    entry.ExtractToFile(dest, true);
                }
            }
            File.WriteAllText(Path.Combine(temp, ".ok"), "ok");
            if (Directory.Exists(target)) Directory.Delete(target, true);
            Directory.Move(temp, target);
        }
        void WriteStopCmd()
        {
            try {
                string text = Encoding.UTF8.GetString(ResourceBytes("STOP.cmd")).TrimStart('﻿').Replace("\r\n", "\n").Replace("\r", "\n").Replace("\n", "\r\n");
                byte[] bytes = new UTF8Encoding(false).GetBytes(text);
                string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "RemoteAgents-Lab СТОП.cmd");
                if (!File.Exists(path) || !File.ReadAllBytes(path).SequenceEqual(bytes)) File.WriteAllBytes(path, bytes);
            } catch (Exception ex) { log.Write("СТОП.cmd на рабочий стол не записан: " + ex.Message); }
        }

        // ---- запуск и события Python ----
        void StartPython()
        {
            stopped = false;
            var r = new PyRun { Generation = ++generation };
            run = r;
            string args = "-X utf8 -u \"" + Slots.ScriptPath + "\" --home \"" + Home + "\" --exe-version \"" + Version + "\"";
            if (Slots.RollbackReason != null) args += " --rollback-reason \"" + Clean(Slots.RollbackReason, 160) + "\"";
            var psi = new ProcessStartInfo(pythonExe, args) {
                UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = Home,
                RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
                StandardOutputEncoding = new UTF8Encoding(false), StandardErrorEncoding = new UTF8Encoding(false)
            };
            psi.EnvironmentVariables.Remove("PYTHONPATH"); psi.EnvironmentVariables.Remove("PYTHONHOME");
            lock (stderrTail) stderrTail.Clear();
            log.Write("запуск Python #" + r.Generation + ": код " + Slots.Current + (Slots.Unverified ? " (непроверенный)" : "") + (Slots.RollbackReason != null ? ", откат: " + Slots.RollbackReason : ""));
            SetState("grey", "Запуск Python", "Код: " + Slots.Current);
            var process = new Process { StartInfo = psi, EnableRaisingEvents = true };
            r.Proc = process;
            process.Exited += (s, e) => OnProcessExited(r);
            string assignError = null;
            try { process.Start(); }
            catch (Exception ex) { log.Write("Python не запустился: " + ex.Message); r.Ready.Set(); Post(() => HandleExit(r, -2)); return; }
            try { job.Assign(process); } catch (Exception ex) { assignError = ex.Message; }
            r.Input = new StreamWriter(process.StandardInput.BaseStream, new UTF8Encoding(false)) { AutoFlush = true, NewLine = "\n" };
            r.Out = new Thread(() => ReadOut(r)) { IsBackground = true, Name = "py-out" }; r.Out.Start();
            r.Err = new Thread(() => ReadErr(r)) { IsBackground = true, Name = "py-err" }; r.Err.Start();
            r.Ready.Set();
            if (assignError != null) { log.Write("Python не помещён в Job Object: " + assignError + "; гашу"); try { process.Kill(); } catch { } }
            else if (Slots.Unverified) { timerV.Stop(); timerV.Start(); }
        }

        void ReadOut(PyRun r)
        {
            var reader = r.Proc.StandardOutput; var sb = new StringBuilder(); var buf = new char[4096]; bool overflow = false; int n;
            try {
                while ((n = reader.Read(buf, 0, buf.Length)) > 0)
                    for (int i = 0; i < n; i++) {
                        char c = buf[i];
                        if (c == '\n') {
                            if (overflow) log.Write("строка Python длиннее предела, отброшена");
                            else if (sb.Length > 0) {
                                string line = sb.ToString();
                                if (Interlocked.Increment(ref queuedLines) > MaxQueuedLines) { Interlocked.Decrement(ref queuedLines); log.Write("очередь строк Python переполнена, строка отброшена"); }
                                else Post(() => { Interlocked.Decrement(ref queuedLines); OnLine(r, line); });
                            }
                            sb.Clear(); overflow = false;
                        } else if (c != '\r') { if (sb.Length < MaxLine) sb.Append(c); else overflow = true; }
                    }
            } catch (Exception ex) { log.Write("чтение stdout Python: " + ex.Message); }
        }
        void ReadErr(PyRun r)
        {
            int logged = 0;
            try {
                string line;
                while ((line = r.Proc.StandardError.ReadLine()) != null) {
                    if (line.Length > 500) line = line.Substring(0, 500);
                    lock (stderrTail) { stderrTail.Enqueue(line); if (stderrTail.Count > StderrTail) stderrTail.Dequeue(); }
                    if (logged < MaxStderrLogged) { logged++; log.Write("python stderr: " + line); if (logged == MaxStderrLogged) log.Write("python stderr: дальше в журнал не пишу (предел)"); }
                }
            } catch (Exception ex) { log.Write("чтение stderr Python: " + ex.Message); }
        }

        void OnProcessExited(PyRun r)      // поток из пула
        {
            r.Ready.Wait();
            int code; try { code = r.Proc.ExitCode; } catch { code = -3; }
            // Python мог упасть, не убрав детей: гасим всех в Job, чтобы их копии pipe закрылись и чтение дошло до EOF.
            // Join без срока: после Terminate держателей pipe не осталось, EOF придёт сразу.
            try { job.Terminate(); } catch { }
            try { if (r.Out != null) r.Out.Join(); if (r.Err != null) r.Err.Join(); } catch { }
            Post(() => HandleExit(r, code));
        }

        void HandleExit(PyRun r, int code)
        {
            if (r != run) return;
            run = null; timerV.Stop(); DiskRunning = false; DiskHome = "";
            double seconds = (DateTime.UtcNow - r.Started).TotalSeconds;
            log.Write("Python #" + r.Generation + " вышел с кодом " + code + " за " + (int)seconds + " с" + (r.TimeoutFired ? " (таймер В)" : "") + (r.GoodSeen ? ", канал был" : ""));
            if (exitRequested) { Finish(); return; }
            var action = Slots.OnExit(code, r.TimeoutFired, r.RestartRequested, seconds, r.GoodSeen, log.Write);
            log.Write("решение: " + (action == SlotAction.Restart ? "запуск" : "стоп") + " -- " + Slots.Reason);
            if (action == SlotAction.Restart) { StartPython(); return; }
            stopped = true; stopReason = Slots.Reason;
            SetState("red", "Остановлено: " + stopReason, "Остановлено: " + stopReason, "Меню значка -> Состояние -> Перезапустить Python");
        }

        void OnLine(PyRun r, string line)
        {
            if (r != run) return;
            Dictionary<string, object> msg;
            try { msg = new JavaScriptSerializer { MaxJsonLength = MaxLine }.Deserialize<Dictionary<string, object>>(line); }
            catch (Exception) { log.Write("не JSON от Python: " + (line.Length > 120 ? line.Substring(0, 120) : line)); return; }
            object type; if (msg == null || !msg.TryGetValue("t", out type)) return;
            switch (type as string) {
                case "state": {
                    object color, tip, lines; msg.TryGetValue("color", out color); msg.TryGetValue("tip", out tip); msg.TryGetValue("lines", out lines);
                    string c = color as string; if (c != "grey" && c != "yellow" && c != "green" && c != "red") c = "grey";
                    var list = new List<string>();
                    var array = lines as System.Collections.IEnumerable;
                    if (array != null) foreach (var item in array) { if (list.Count >= 50) break; string s = Convert.ToString(item) ?? ""; list.Add(s.Length > 300 ? s.Substring(0, 300) : s); }
                    object disk; msg.TryGetValue("disk", out disk); DiskRunning = !exitRequested && disk is bool && (bool)disk;
                    object diskHome; msg.TryGetValue("diskHome", out diskHome); string dh = diskHome as string; DiskHome = DiskRunning && dh != null && dh.Length < 260 && dh.IndexOfAny(new[] { '"', '\r', '\n', '\0' }) < 0 ? dh : "";
                    SetState(exitRequested ? "grey" : c, exitRequested ? "Выход..." : (tip as string) ?? "", list.ToArray());
                    break;
                }
                case "good": {
                    r.GoodSeen = true; timerV.Stop();
                    object version; msg.TryGetValue("version", out version);
                    log.Write("Python сообщил good (версия Python: " + Clean(version as string, 80) + "); версия кода " + Slots.Current + " проверена");
                    Slots.MarkGood();
                    break;
                }
                case "report": {
                    object text; msg.TryGetValue("text", out text);
                    var handler = ReportReady; if (handler != null) handler(((text as string) ?? "") + "\r\n\r\n=== EXE ===\r\n" + BuildExeReport());
                    break;
                }
            }
        }

        void Send(string json)
        {
            var r = run; if (r == null || r.Input == null) return;
            try { lock (r.InputGate) r.Input.WriteLine(json); } catch (Exception ex) { log.Write("запись в stdin Python: " + ex.Message); }
        }

        // ---- команды из трея ----
        public void RequestExit()
        {
            if (run == null) { Finish(); return; }
            if (exitRequested) { log.Write("повторный Выход: гашу всё принудительно"); job.Terminate(); return; }
            exitRequested = true; DiskRunning = false; DiskHome = "";
            timerV.Stop(); // Выход ждёт мягкую остановку и очистку TUN (до ~30 с); таймер запуска не должен её оборвать.
            log.Write("Выход: прошу Python закрыться");
            SetState("grey", "Выход...", "Жду, пока Python закроется.", "Очистка TUN может занять до 30 с. Не закрывается: нажмите Выход ещё раз -- погасит принудительно.");
            Send("{\"t\":\"exit\"}");
        }
        public void RestartPython()
        {
            if (run != null) {
                if (run.RestartRequested) { log.Write("перезапуск уже запрошен: повторный клик игнорирую"); return; }
                var r = run; r.RestartRequested = true; log.Write("перезапуск Python по просьбе владельца: прошу закрыться, жду до " + RestartGraceSeconds + " с");
                Send("{\"t\":\"exit\"}");   // мягкая остановка TUN: Python сам снимет адаптер, Terminate только по сроку
                var t = new System.Windows.Forms.Timer { Interval = RestartGraceSeconds * 1000 };
                t.Tick += (s, e) => { t.Stop(); t.Dispose(); if (run == r) { log.Write("Python не закрылся за " + RestartGraceSeconds + " с: гашу принудительно"); job.Terminate(); } };
                t.Start(); return;
            }
            if (stopped && Slots != null) { Slots.ResetAfterStop(); log.Write("запуск после остановки по просьбе владельца"); StartPython(); }
        }
        public void RequestReport()
        {
            var handler = ReportReady;
            if (run == null) { if (handler != null) handler("Python не запущен.\r\n\r\n=== EXE ===\r\n" + BuildExeReport()); return; }
            Send("{\"t\":\"report\"}");
            // Пока Python готовит полный отчёт, сразу отдаём отчёт EXE; полный придёт событием report (Python может не ответить).
            if (handler != null) handler("(Python ещё не ответил)\r\n\r\n=== EXE ===\r\n" + BuildExeReport());
        }
        void Finish() { var handler = Quit; if (handler != null) handler(); }

        public string BuildExeReport()
        {
            var sb = new StringBuilder();
            sb.AppendLine("RemoteAgents-Lab EXE " + Version + ", " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + ", админ=" + IsAdmin);
            sb.AppendLine("Папка: " + Home);
            var r = run;
            sb.AppendLine("Python: " + (r != null ? "запущен, pid " + SafePid(r) + ", #" + r.Generation + ", работает " + (int)(DateTime.UtcNow - r.Started).TotalSeconds + " с, good=" + r.GoodSeen : "не запущен" + (stopped ? " (остановлен: " + stopReason + ")" : "")));
            if (Slots != null) sb.AppendLine("Код: current=" + Slots.Current + ", lastGood=" + Slots.LastGood + ", embedded=" + embeddedName + ", failsGood=" + Slots.FailsGood + ", memRestarts=" + Slots.MemRestarts + ", откат=" + Slots.RollbackReason + ", решение=" + Slots.Reason);
            sb.AppendLine("Значок: " + State.Color + " / " + State.Tip);
            foreach (var line in State.Lines) sb.AppendLine("  " + line);
            sb.AppendLine("--- stderr Python (последние) ---");
            lock (stderrTail) foreach (var line in stderrTail) sb.AppendLine(line);
            sb.AppendLine("--- exe.log (последние 50) ---");
            sb.AppendLine(log.Tail(50));
            return sb.ToString().Replace("\r\n", "\n").Replace("\n", "\r\n");
        }
        static string SafePid(PyRun r) { try { return r.Proc.Id.ToString(); } catch { return "?"; } }

        public void Dispose() { disposed = true; timerV.Dispose(); job.Dispose(); }
    }
}
