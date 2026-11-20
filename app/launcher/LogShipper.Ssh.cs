using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;

namespace RemoteAgents.Launcher
{
    // Отправка пачки через ssh.exe тем же ключом, что у обновлений: сначала канал (127.0.0.1:<порт>), потом напрямую.
    internal sealed class SshLogSender : ILogSender
    {
        readonly string home;
        readonly Func<string> bundleFolder;
        string scriptBase64;
        internal SshLogSender(string home, Func<string> bundleFolder) { this.home = home; this.bundleFolder = bundleFolder; }

        string Script()
        {
            if (scriptBase64 != null) return scriptBase64;
            string file = Path.Combine(bundleFolder(), "server", "logs_in.py");
            if (!File.Exists(file)) throw new FileNotFoundException("Нет server/logs_in.py в бандле");
            return scriptBase64 = Convert.ToBase64String(File.ReadAllBytes(file));
        }
        static SendResult Fail(string err, int exit = 0, string stderr = "") { return new SendResult { Err = err, Exit = exit, Stderr = stderr }; }

        public SendResult Send(byte[] gz, string batchId, string path)
        {
            SshSource source;
            try {
                var update = new Dictionary<string, object>(new Configuration(home).Update);
                // Прямой путь: без перенаправления на локальный порт канала (ssh.exe идёт мимо TUN).
                if (path == "direct") update.Remove("viaLocalPort");
                else if (Json.Int(update, "viaLocalPort", 0) == 0) return Fail("no-channel-port");
                source = SshSource.Load(Configuration.ForUpdate(Json.Encode(update)), home);
            } catch (Exception e) { return Fail("ssh-source:" + e.GetType().Name); }
            string script;
            try { script = Script(); } catch (Exception e) { return Fail("script:" + e.GetType().Name); }
            // -n убираем (нужен stdin), добавляем короткие таймауты.
            var args = source.Args.Where(a => a != "-n").ToList();
            string target = args[args.Count - 1]; args.RemoveAt(args.Count - 1);
            args.AddRange(new[] { "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2" });
            args.Add(target);
            args.Add("python3 -c 'import base64;exec(base64.b64decode(\"" + script + "\"))' recv");
            var info = new ProcessStartInfo(Files.Executable(source.Exe), Files.Arguments(args)) {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8 };
            var stdout = new StringBuilder(); var stderr = new StringBuilder();
            try {
                using (var process = Process.Start(info)) {
                    process.OutputDataReceived += (s, e) => { if (e.Data != null) lock (stdout) { if (stdout.Length < 4096) stdout.AppendLine(e.Data); } };
                    process.ErrorDataReceived += (s, e) => { if (e.Data != null) lock (stderr) { if (stderr.Length < 4096) stderr.AppendLine(e.Data); } };
                    process.BeginOutputReadLine(); process.BeginErrorReadLine();
                    try { process.StandardInput.BaseStream.Write(gz, 0, gz.Length); process.StandardInput.Close(); } catch (IOException) { }
                    if (!process.WaitForExit(20000)) { try { process.Kill(); } catch { } process.WaitForExit(2000); return Fail("timeout", -1, stderr.ToString()); }
                    process.WaitForExit(); // дочитывает асинхронный вывод
                    string output; lock (stdout) output = stdout.ToString().Trim();
                    bool ok = process.ExitCode == 0 && output.StartsWith("OK batch=" + batchId, StringComparison.Ordinal);
                    return ok ? new SendResult { Ok = true } : Fail(process.ExitCode == 0 ? "bad-reply:" + (output.Length > 80 ? output.Substring(0, 80) : output) : "ssh-exit", process.ExitCode, stderr.ToString());
                }
            } catch (Exception e) { return Fail("start:" + e.GetType().Name); }
        }
    }
}
