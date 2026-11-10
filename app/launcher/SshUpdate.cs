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
    internal static class External
    {
        public static int Run(string exe, string[] args, string cwd, string output, int timeoutMs, long maxBytes, CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            using (var job = new NativeJob()) using (var process = job.StartRedirected(exe, args, cwd, output)) {
                var watch = Stopwatch.StartNew();
                while (!process.WaitForExit(100)) {
                    token.ThrowIfCancellationRequested();
                    if (watch.ElapsedMilliseconds > timeoutMs) throw new IOException("Внешняя команда не завершилась");
                    if (output != null && new FileInfo(output).Length > maxBytes) throw new IOException("Вывод команды слишком велик");
                }
                token.ThrowIfCancellationRequested();
                if (output != null && new FileInfo(output).Length > maxBytes) throw new IOException("Вывод команды слишком велик");
                return process.ExitCode;
            }
        }
        [System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern uint GetOEMCP();
        public static string ReadPowerShellOutput(string path)
        {
            byte[] data = File.ReadAllBytes(path);
            if (data.Length >= 2 && ((data[0] == 255 && data[1] == 254) || (data[0] == 254 && data[1] == 255))) return File.ReadAllText(path);
            try { return new UTF8Encoding(false, true).GetString(data).TrimStart('\uFEFF'); }
            catch (DecoderFallbackException) { return Encoding.GetEncoding((int)GetOEMCP()).GetString(data); }
        }
        public static bool SelfTest(string folder, string home, CancellationToken token)
        {
            return Run("powershell.exe", new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", Path.Combine(folder, "selftest.ps1"), "-Home", home }, folder, null, 120000, 4 * 1024 * 1024, token) == 0;
        }
    }
    internal sealed class SshSource
    {
        public string Exe, RemoteDir; public string[] Args;
        public static SshSource Load(Configuration config, string home)
        {
            var update = config.Update; Dictionary<string, object> profile = new Dictionary<string, object>();
            var args = Json.Strings(Json.Get(update, "args"));
            if (!update.ContainsKey("args")) {
                var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                var roots = new[] { Path.Combine(home, "ssh-profiles"), Path.Combine(local, "RemoteAgents", "ssh-profiles") }.Distinct();
                string found = null;
                foreach (string root in roots) {
                    if (!Directory.Exists(root)) continue;
                    found = Directory.GetDirectories(root).OrderBy(p => p, StringComparer.OrdinalIgnoreCase)
                        .SelectMany(p => Directory.Exists(Path.Combine(p, "project-connections")) ? Directory.GetDirectories(Path.Combine(p, "project-connections")).OrderBy(q => q, StringComparer.OrdinalIgnoreCase) : Enumerable.Empty<string>())
                        .Select(p => Path.Combine(p, "ssh-transport.json")).FirstOrDefault(File.Exists);
                    if (found != null) break;
                }
                if (found == null) { string saved = Path.Combine(local, "RemoteDisk", "profile.txt"); if (File.Exists(saved)) { var p = Files.ReadLine(saved); if (File.Exists(p)) found = p; } }
                if (found == null) throw new InvalidDataException("Нет SSH-профиля");
                profile = Json.Read(found); args = Json.Strings(Json.Get(profile, "arguments"));
            }
            if (args.Length == 0) throw new InvalidDataException("Нет аргументов SSH");
            var options = new List<string>(); string target = null;
            // Connection argv ends with exactly one destination, without a remote command.
            const string valued = "BbcDEeFIiJLlmOopQRSWw";
            for (int i = 0; i < args.Length; i++) {
                var a = args[i];
                if (!a.StartsWith("-", StringComparison.Ordinal)) { if (i != args.Length - 1 || target != null) throw new InvalidDataException("Неверные аргументы SSH"); target = a; break; }
                if (a == "--" || a == "-N" || a == "-f" || a == "-s" || a == "-G" || a == "-V") throw new InvalidDataException("Неподходящий режим SSH");
                options.Add(a);
                if (a.Length == 2 && valued.IndexOf(a[1]) >= 0) { if (++i >= args.Length) throw new InvalidDataException("Нет значения SSH-опции"); options.Add(args[i]); }
            }
            if (string.IsNullOrWhiteSpace(target) || target.Contains("\n") || target.Contains("\r")) throw new InvalidDataException("Нет адреса SSH");
            int port = Json.Int(update, "viaLocalPort", 0);
            // Imported legacy argv contains -p 22: honor the actual managed profile route.
            // Explicit updater argv continues to use its own viaLocalPort setting.
            string profileConfig = Json.Str(profile, "configPath"), profileServer = Json.Str(profile, "serverAddress");
            if (port == 0 && profileServer.Length > 0 && File.Exists(profileConfig)) {
                foreach (Match block in Regex.Matches(File.ReadAllText(profileConfig), @"(?ms)^# BEGIN RemoteAgents transport [^\r\n]+\r?\n(.*?)^# END RemoteAgents transport [^\r\n]+")) {
                    if (!Regex.IsMatch(block.Groups[1].Value, "(?m)^Host \"" + Regex.Escape(profileServer) + "\"\\r?$")) continue;
                    var localPort = Regex.Match(block.Groups[1].Value, @"(?m)^    Port (\d+)\r?$");
                    if (localPort.Success) { port = int.Parse(localPort.Groups[1].Value); break; }
                }
            }
            if (port != 0) {
                if (port < 1 || port > 65535) throw new InvalidDataException("Неверный локальный порт");
                int at = target.LastIndexOf('@'); string user = at >= 0 ? target.Substring(0, at + 1) : "";
                string host = Json.Text(update, "hostKeyAlias", Json.Text(profile, "serverAddress", at >= 0 ? target.Substring(at + 1) : target));
                var kept = new List<string>();
                for (int i = 0; i < options.Count; i++) {
                    string a = options[i]; char key = a.Length > 1 ? a[1] : '\0';
                    string value = a.Length == 2 && valued.IndexOf(key) >= 0 ? options[++i] : a.Substring(2);
                    if (key == 'p' || key == 'F' || key == 'J') continue;
                    if (key == 'o' && new[] { "hostname", "port", "hostkeyalias", "proxycommand", "proxyjump" }.Any(k => value.StartsWith(k + "=", StringComparison.OrdinalIgnoreCase) || value.StartsWith(k + " ", StringComparison.OrdinalIgnoreCase))) continue;
                    kept.Add(a); if (a.Length == 2 && valued.IndexOf(key) >= 0) kept.Add(value);
                }
                options = new List<string> { "-F", "NUL", "-p", port.ToString(), "-o", "HostKeyAlias=" + host, "-o", "ProxyCommand=none", "-o", "ProxyJump=none" }; options.AddRange(kept);
                target = user + "127.0.0.1";
            }
            var all = new List<string> { "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "StrictHostKeyChecking=yes", "-T" }; all.AddRange(options); all.Add(target);
            return new SshSource { Exe = Json.Text(update, "sshExe", Json.Text(profile, "sshExecutable", "ssh.exe")), Args = all.ToArray(), RemoteDir = Json.Text(update, "remoteDir", "~/.local/share/remote-agents/dist") };
        }
        internal static string RemotePath(string dir, string file)
        {
            if (dir.IndexOfAny(new[] { '\r', '\n', '\0' }) >= 0) throw new InvalidDataException("Неверный удалённый путь");
            if (dir == "~") return "\"$HOME\"/" + ShellQuote(file);
            if (dir.StartsWith("~/", StringComparison.Ordinal)) return "\"$HOME\"/" + ShellQuote(dir.Substring(2).TrimEnd('/') + "/" + file);
            return ShellQuote(dir.TrimEnd('/') + "/" + file);
        }
        static string ShellQuote(string value) { return "'" + value.Replace("'", "'\"'\"'") + "'"; }
        public void Fetch(string file, string output, long limit, CancellationToken token)
        {
            var args = Args.Concat(new[] { "cat -- " + RemotePath(RemoteDir, file) }).ToArray();
            if (External.Run(Exe, args, Path.GetDirectoryName(output), output, 300000, limit, token) != 0) throw new IOException("Нет связи для обновления");
        }
        public Manifest Manifest(string home, CancellationToken token)
        {
            string file = Path.Combine(home, "bundle", "manifest." + Guid.NewGuid().ToString("N") + ".tmp");
            try { Fetch("manifest.json", file, 1024 * 1024, token); return global::RemoteAgents.Launcher.Manifest.Parse(Files.LF(File.ReadAllText(file))); }
            finally { if (File.Exists(file)) File.Delete(file); }
        }
    }
}
