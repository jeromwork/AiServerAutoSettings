using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using System.IO.Compression;

namespace RemoteAgents.Lab
{
    // EXE-сторож: распаковывает Python и код, запускает Python и перезапускает его. Логики связи здесь нет.
    // Протокол с Python (JSON-строки UTF-8): lab/exe/PROTOCOL в отчёте этапа; кратко --
    //   Python -> EXE (stdout): {"t":"state","color":"grey|yellow|green|red","tip":"..","lines":[..]}, {"t":"good","version":".."}, {"t":"report","text":".."}, {"t":"notice","text":".."} (подсказка трея), {"t":"restart-exe"} (перезапуск EXE после обновления/отката)
    //   EXE -> Python (stdin):  {"t":"exit"}, {"t":"report"}, {"t":"update"};  EOF stdin = выход.
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
                if (supervisor.RestartExeRequested) {
                    // Новый файл EXE уже лежит по тому же пути: освобождаем mutex и запускаем его.
                    try { mutex.ReleaseMutex(); } catch (Exception) { }
                    try { mutex.Dispose(); } catch (Exception) { }
                    string exe = Application.ExecutablePath, prev = Supervisor.PrevExePath;
                    var messages = new List<string>();   // окна показываем только после запуска нового EXE: запуск не ждёт «ОК»
                    if (supervisor.RollbackError != null) messages.Add("Не удалось вернуть предыдущую версию: " + supervisor.RollbackError);
                    if (!File.Exists(exe) && File.Exists(prev)) {
                        try { File.Move(prev, exe); } catch (Exception ex0) { log.Write("не удалось переименовать .prev.exe в EXE: " + ex0.Message); exe = prev; messages.Add("Запущена предыдущая версия: " + Path.GetFileName(prev)); }
                    }
                    try { Process.Start(exe); }
                    catch (Exception ex) {
                        log.Write("перезапуск EXE не удался: " + ex.Message);
                        bool ok = false;
                        if (exe != prev && File.Exists(prev)) { try { Process.Start(prev); ok = true; } catch (Exception ex2) { log.Write("запуск .prev.exe не удался: " + ex2.Message); } }
                        messages.Add(ok ? "Не удалось запустить новую версию. Запущена предыдущая." : "Запустите " + Path.GetFileName(prev));
                    }
                    foreach (var m in messages) MessageBox.Show(m, "RemoteAgents");
                }
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

    internal sealed class LabState { public string Color = "grey"; public string Tip = "Запуск"; public string[] Lines = new string[0]; public bool Control; }

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
        public const int FinalExitGraceSeconds = 80;      // TUN до 40 с + уборка до 30 с
        public const int PythonSilenceFuseSeconds = 120;   // таймер В
        const int MaxLine = 200000, MaxQueuedLines = 1000, MaxStderrLogged = 200, StderrTail = 30;
        public readonly string Home, Version;
        readonly ExeLog log; readonly Control ui; readonly LabJob job = new LabJob();
        readonly System.Windows.Forms.Timer timerV = new System.Windows.Forms.Timer();
        bool timerVStoppedByNoConfig;
        public CodeSlots Slots; public LabState State = new LabState();
        public volatile int HappierPort; public volatile string DiskHome = ""; public volatile bool DiskRunning;   // Python сообщил «Диск: работает» (поле disk:true в state); читает поток Проводника
        public volatile string WebUiUrl = ""; public volatile bool ControlEnabled;
        public void WriteLog(string text) { log.Write(text); }
        public event Action StateChanged; public event Action<string> ReportReady, Notice; public event Action Quit;
        public volatile bool RestartExeRequested;
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
            State = new LabState { Color = color, Tip = tip.Length > 63 ? tip.Substring(0, 63) : tip, Lines = lines, Control = ControlEnabled };
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
            WriteBinZip();
            foreach (var old in Directory.GetDirectories(Path.Combine(Home, "runtime"), "py-*")) if (Path.GetFileName(old) != "py-" + pyHash) try { Directory.Delete(old, true); } catch { }
        }
        // Ресурс bin.zip (если он есть в сборке) кладём на диск как есть: <home>\runtime\bin.zip; пишем, только если файла нет или sha256 отличается.
        void WriteBinZip()
        {
            try {
                byte[] bytes;
                using (var stream = typeof(Supervisor).Assembly.GetManifestResourceStream("bin.zip")) {
                    if (stream == null) return;
                    var memory = new MemoryStream(); stream.CopyTo(memory); bytes = memory.ToArray();
                }
                string path = Path.Combine(Home, "runtime", "bin.zip");
                using (var sha = SHA256.Create())
                    if (File.Exists(path) && sha.ComputeHash(File.ReadAllBytes(path)).SequenceEqual(sha.ComputeHash(bytes))) return;
                string temp = path + ".tmp";
                File.WriteAllBytes(temp, bytes);
                if (File.Exists(path)) File.Delete(path);
                File.Move(temp, path);
                log.Write("записан bin.zip");
            } catch (Exception ex) { log.Write("bin.zip не записан: " + ex.Message); }
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
            psi.EnvironmentVariables["RA_EXE"] = Application.ExecutablePath; psi.EnvironmentVariables["RA_EXE_VERSION"] = Version;
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
            else if (Slots.Unverified) { timerVStoppedByNoConfig = false; timerV.Stop(); timerV.Start(); }
        }

        static readonly Regex UrlMaskRegex = new Regex(@"https?://[^\s""'>]+", RegexOptions.IgnoreCase);
        static readonly Regex TokenMaskRegex = new Regex(@"([?&#]?(?:token|auth|key|secret)=)[^\s""'&]+", RegexOptions.IgnoreCase);

        static string MaskUrl(string text)
        {
            if (string.IsNullOrEmpty(text)) return text;
            try {
                text = UrlMaskRegex.Replace(text, m => {
                    string u = m.Value;
                    int q = u.IndexOfAny(new[] { '?', '#', ';' });
                    if (q >= 0) u = u.Substring(0, q);
                    int slash = u.IndexOf('/', 8);
                    if (slash >= 0 && u.Length - slash > 1) return u.Substring(0, slash + 1) + "***";
                    return u + "/*";
                });
                text = TokenMaskRegex.Replace(text, "$1***");
            } catch { }
            return text;
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
                    line = MaskUrl(line);
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
            run = null; timerV.Stop(); timerVStoppedByNoConfig = false; HappierPort = 0; DiskRunning = false; DiskHome = ""; WebUiUrl = "";
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
            catch (Exception) {
                string safe = MaskUrl(line);
                log.Write("не JSON от Python: " + (safe.Length > 120 ? safe.Substring(0, 120) : safe));
                return;
            }
            object type; if (msg == null || !msg.TryGetValue("t", out type)) return;
            switch (type as string) {
                case "noconfig": {
                    log.Write("Python сообщил noconfig: конфига нет, останавливаю таймер В");
                    timerVStoppedByNoConfig = true;
                    timerV.Stop();
                    break;
                }
                case "config-ok": {
                    log.Write("Python сообщил config-ok");
                    if (timerVStoppedByNoConfig) {
                        timerVStoppedByNoConfig = false;
                        if (Slots != null && Slots.Unverified) {
                            timerV.Stop();
                            timerV.Start();
                            log.Write("таймер В перезапущен после config-ok");
                        }
                    }
                    break;
                }
                case "state": {
                    object color, tip, lines; msg.TryGetValue("color", out color); msg.TryGetValue("tip", out tip); msg.TryGetValue("lines", out lines);
                    string c = color as string; if (c != "grey" && c != "yellow" && c != "green" && c != "red") c = "grey";
                    var list = new List<string>();
                    var array = lines as System.Collections.IEnumerable;
                    if (array != null) foreach (var item in array) { if (list.Count >= 50) break; string s = Convert.ToString(item) ?? ""; list.Add(s.Length > 300 ? s.Substring(0, 300) : s); }
                    object disk; msg.TryGetValue("disk", out disk); DiskRunning = !exitRequested && disk is bool && (bool)disk;
                    object diskHome; msg.TryGetValue("diskHome", out diskHome); string dh = diskHome as string; DiskHome = DiskRunning && dh != null && dh.Length < 260 && dh.IndexOfAny(new[] { '"', '\r', '\n', '\0' }) < 0 ? dh : "";
                    object hp; msg.TryGetValue("happierPort", out hp); int hpn; try { hpn = hp == null ? 0 : Convert.ToInt32(hp); } catch (Exception) { hpn = 0; } HappierPort = hpn > 0 && hpn < 65536 ? hpn : 0;
                    object ctrl;
                    if (msg.TryGetValue("control", out ctrl) && ctrl != null) {
                        if (ctrl is bool) ControlEnabled = (bool)ctrl;
                        else if (ctrl is int) ControlEnabled = (int)ctrl != 0;
                        else if (bool.TryParse(ctrl.ToString(), out bool b)) ControlEnabled = b;
                    }
                    SetState(exitRequested ? "grey" : c, exitRequested ? "Выход..." : (tip as string) ?? "", list.ToArray());
                    break;
                }
                case "ui": {
                    object url; msg.TryGetValue("url", out url);
                    string u = url as string;
                    if (!string.IsNullOrEmpty(u)) WebUiUrl = u;
                    break;
                }
                case "open-ui": {
                    object url; msg.TryGetValue("url", out url);
                    string u = url as string;
                    if (!string.IsNullOrEmpty(u)) WebUiUrl = u;
                    else u = WebUiUrl;
                    if (!string.IsNullOrEmpty(u)) {
                        try { Process.Start(u); }
                        catch (Exception ex) { log.Write("open-ui не удалось: " + ex.GetType().Name); }
                    }
                    break;
                }
                case "good": {
                    r.GoodSeen = true; timerV.Stop();
                    object version; msg.TryGetValue("version", out version);
                    log.Write("Python сообщил good (версия Python: " + Clean(version as string, 80) + "); версия кода " + Slots.Current + " проверена");
                    Slots.MarkGood();
                    break;
                }
                case "notice": {
                    object text; msg.TryGetValue("text", out text);
                    string t = ((text as string) ?? "").Replace("\r", " ").Replace("\n", " "); if (t.Length > 200) t = t.Substring(0, 200);
                    if (t.StartsWith("Уже последняя версия") || t.StartsWith("Ошибка") || t.StartsWith("Не удалось") || t.StartsWith("Нет связи")) { updateLockUntil = DateTime.MinValue; UpdateStatus = null; var up = UpdateProgress; if (up != null) up(); }
                    if (t.Length > 0) { var handler = Notice; if (handler != null) handler(t); }
                    break;
                }
                case "update-progress": {
                    object text; msg.TryGetValue("text", out text);
                    string t = ((text as string) ?? "").Replace("\r", " ").Replace("\n", " ");
                    if (t.Length == 0) UpdateStatus = null;
                    else
                    {
                        UpdateStatus = t.Length > 24 ? t.Substring(0, 24) : t;
                        updateLockUntil = DateTime.UtcNow.AddSeconds(120); // продлеваем блок, пока идёт прогресс
                    }
                    var upd = UpdateProgress; if (upd != null) upd();
                    break;
                }
                case "restart-exe": {
                    log.Write("Python просит перезапустить EXE: выхожу и запускаю заново");
                    updateLockUntil = DateTime.MinValue;
                    if (exitRequested || RestartExeRequested) { RestartExeRequested = true; break; }   // выход уже идёт: только флаг, без повторного RequestExit
                    RestartExeRequested = true;
                    var runX = run; RequestExit(false); ForceKillAfterGrace(runX);
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
        public void SetControl(bool enabled)
        {
            ControlEnabled = enabled;
            Send("{\"t\":\"control\",\"enabled\":" + (enabled ? "true" : "false") + "}");
            SetState(State.Color, State.Tip, State.Lines);
        }
        public void RequestExit(bool final = true)
        {
            if (run == null) { Finish(); return; }
            if (exitRequested) { log.Write("повторный Выход: гашу всё принудительно"); job.Terminate(); return; }
            exitRequested = true; DiskRunning = false; DiskHome = "";
            timerV.Stop(); // Выход ждёт мягкую остановку и очистку TUN (до ~30 с); таймер запуска не должен её оборвать.
            int grace = final ? FinalExitGraceSeconds : RestartGraceSeconds;
            log.Write("Выход: прошу Python закрыться (final=" + final + ", жду до " + grace + " с)");
            SetState("grey", "Выход...", "Жду, пока Python закроется.", "Очистка может занять до 30 с. Не закрывается: нажмите Выход ещё раз -- погасит принудительно.");
            Send(final ? "{\"t\":\"exit\",\"final\":true}" : "{\"t\":\"exit\"}");
            var r = run;
            var t = new System.Windows.Forms.Timer { Interval = grace * 1000 };
            t.Tick += (s, e) => { t.Stop(); t.Dispose(); if (run == r) { log.Write("Python не вышел за " + grace + " с при выходе: гашу"); job.Terminate(); } };
            t.Start();
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
        DateTime updateLockUntil = DateTime.MinValue;
        // После «Обновить» Python сам переставляет exe/.prev/.tmp: 120 с (или до restart-exe/выхода) откат и повторное обновление недоступны.
        public string UpdateStatus { get; private set; }
        public event Action UpdateProgress;
        public bool UpdateLocked { get { return DateTime.UtcNow < updateLockUntil; } }
        public bool ExitInProgress { get { return exitRequested || RestartExeRequested; } }
        public volatile string RollbackError; bool pendingRollbackFiles;
        public bool PythonRunning { get { return run != null && !exitRequested; } }
        public void RequestUpdate() { if (UpdateLocked) return; updateLockUntil = DateTime.UtcNow.AddSeconds(120); Send("{\"t\":\"update\"}"); }
        void ForceKillAfterGrace(PyRun r)
        {
            if (r == null) return;
            var t = new System.Windows.Forms.Timer { Interval = RestartGraceSeconds * 1000 };
            t.Tick += (s, e) => { t.Stop(); t.Dispose(); if (run == r) { log.Write("Python не вышел за " + RestartGraceSeconds + " с при перезапуске EXE: гашу"); job.Terminate(); } };
            t.Start();
        }
        public static string PrevExePath { get { string exe = Application.ExecutablePath; return Path.Combine(Path.GetDirectoryName(exe), Path.GetFileNameWithoutExtension(exe) + ".prev.exe"); } }
        // Откат EXE не зависит от Python. Если Python запущен, файлы не трогаем, пока он не завершится (в Finish), иначе гонка с update.py.
        public void RollbackExe()
        {
            var handler = Notice;
            if (ExitInProgress) { if (handler != null) handler("Выход уже идёт"); return; }
            if (UpdateLocked) { if (handler != null) handler("Идёт обновление, подождите"); return; }
            if (!File.Exists(PrevExePath)) { if (handler != null) handler("Предыдущей версии нет"); return; }
            pendingRollbackFiles = true; RestartExeRequested = true;
            var run0 = run;
            RequestExit(false);   // Python нет: сразу Finish, где и меняются файлы; иначе мягкий выход и таймер 45 с
            ForceKillAfterGrace(run0);
        }
        // Меняем местами exe и .prev.exe; вызывается, когда Python уже завершён. Ошибка -- файлы возвращены, причина в RollbackError.
        void DoRollbackFiles()
        {
            string exe = Application.ExecutablePath, prev = PrevExePath, tmp = exe + ".tmp";
            int step = 0;
            try {
                if (!File.Exists(prev)) throw new FileNotFoundException("Предыдущей версии нет");
                if (File.Exists(tmp)) {
                    string old = tmp + ".old";
                    if (File.Exists(old)) File.Delete(old);
                    File.Move(tmp, old);
                    log.Write("прежний " + Path.GetFileName(tmp) + " переименован в " + Path.GetFileName(old));
                }
                File.Move(exe, tmp); step = 1;
                File.Move(prev, exe); step = 2;
                File.Move(tmp, prev); step = 3;
                log.Write("откат EXE: файлы заменены");
            } catch (Exception ex) {
                log.Write("откат EXE не удался на шаге " + step + ": " + ex.Message);
                try {
                    if (step == 2) { File.Move(exe, prev); step = 1; }
                    if (step == 1) File.Move(tmp, exe);
                } catch (Exception ex2) { log.Write("возврат файлов после ошибки отката: " + ex2.Message); }
                RollbackError = ex.Message;
            }
        }
        public void RequestReport()
        {
            var handler = ReportReady;
            if (run == null) { if (handler != null) handler("Python не запущен.\r\n\r\n=== EXE ===\r\n" + BuildExeReport()); return; }
            Send("{\"t\":\"report\"}");
            // Пока Python готовит полный отчёт, сразу отдаём отчёт EXE; полный придёт событием report (Python может не ответить).
            if (handler != null) handler("(Python ещё не ответил)\r\n\r\n=== EXE ===\r\n" + BuildExeReport());
        }
        void Finish() { if (pendingRollbackFiles) { pendingRollbackFiles = false; DoRollbackFiles(); } var handler = Quit; if (handler != null) handler(); }

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
