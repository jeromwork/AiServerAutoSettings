using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Text.RegularExpressions;

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

        // Чистые функции: опции отправки идут первыми (OpenSSH берёт первое значение).
        internal static string[] BuildArguments(string[] sourceArgs, string alias, string script)
        {
            var args = new List<string> { "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2", "-o", "HostKeyAlias=" + alias };
            args.AddRange(sourceArgs.Where(a => a != "-n"));
            args.Add("python3 -c 'import base64;exec(base64.b64decode(\"" + script + "\"))' recv");
            return args.ToArray();
        }
        internal static bool ValidReply(int exit, string output, string batchId)
        {
            return exit == 0 && Regex.IsMatch(output ?? "", @"\AOK batch=" + Regex.Escape(batchId) + @" stored=[0-9]+(?:\r?\n)?\z");
        }
        static int Left(Stopwatch watch, int timeoutMs) { return Math.Max(0, timeoutMs - (int)watch.ElapsedMilliseconds); }

        public SendResult Send(byte[] gz, string batchId, string path, int timeoutMs)
        {
            var watch = Stopwatch.StartNew();
            SshSource source;
            try {
                var update = new Dictionary<string, object>(new Configuration(home).Update);
                if (path == "direct") update.Remove("viaLocalPort");
                else if (Json.Int(update, "viaLocalPort", 0) == 0) return Fail("no-channel-port");
                source = SshSource.Load(Configuration.ForUpdate(Json.Encode(update)), home);
            } catch (Exception e) { return Fail("ssh-source:" + e.GetType().Name); }
            string script;
            try { script = Script(); } catch (Exception e) { return Fail("script:" + e.GetType().Name); }
            var info = new ProcessStartInfo(Files.Executable(source.Exe), Files.Arguments(BuildArguments(source.Args, source.HostKeyAlias, script))) {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8 };
            var stdout = new StringBuilder(); var stderr = new StringBuilder();
            try {
                if (Left(watch, timeoutMs) <= 0) return Fail("timeout", -1);
                using (var process = Process.Start(info)) {
                    var outputDone = new TaskCompletionSource<bool>(); var errorDone = new TaskCompletionSource<bool>();
                    process.OutputDataReceived += (s, e) => { if (e.Data == null) outputDone.TrySetResult(true); else lock (stdout) { if (stdout.Length < 4096) stdout.Append(e.Data).Append('\n'); } };
                    process.ErrorDataReceived += (s, e) => { if (e.Data == null) errorDone.TrySetResult(true); else lock (stderr) { if (stderr.Length < 4096) stderr.AppendLine(e.Data); } };
                    process.BeginOutputReadLine(); process.BeginErrorReadLine();
                    // Запись stdin тоже может заблокироваться, если SSH не читает: общий срок включает её.
                    var input = Task.Run(() => { try { process.StandardInput.BaseStream.Write(gz, 0, gz.Length); process.StandardInput.Close(); } catch { } });
                    if (!process.WaitForExit(Left(watch, timeoutMs)) ||
                        !Task.WaitAll(new Task[] { input, outputDone.Task, errorDone.Task }, Left(watch, timeoutMs))) {
                        try { process.Kill(); } catch { }
                        return Fail("timeout", -1);
                    }
                    string output, error; lock (stdout) output = stdout.ToString(); lock (stderr) error = stderr.ToString();
                    return ValidReply(process.ExitCode, output, batchId) ? new SendResult { Ok = true } :
                        Fail(process.ExitCode == 0 ? "bad-reply:" + TailReply(output) : "ssh-exit", process.ExitCode, error);
                }
            } catch (Exception e) { return Fail("start:" + e.GetType().Name); }
        }
        static string TailReply(string output) { return output.Length > 80 ? output.Substring(0, 80) : output; }
    }
}
