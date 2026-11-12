using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace RemoteAgents.Launcher
{
    internal static class SecretCommand
    {
        public static int Run(string home, string[] args)
        { return Execute(home, args, (name, why) => SecretPrompt.Ask(null, name, why)); }
        internal static int Execute(string home, string[] args, Func<string, string, string> prompt)
        {
            try {
                args = args ?? new string[0];
                if (args.Length > 0 && args[0] == "secret") args = args.Skip(1).ToArray();
                if (args.Length == 1 && args[0] == "status") return Status(home);
                if (args.Length == 4 && args[0] == "set" && args[2] == "--why") {
                    ConfigBundle.ValidName(args[1]);
                    string value = prompt(args[1], args[3]);
                    if (value == null) { Console.WriteLine("отменено"); return 1; }
                    SecretVault.Set(home, args[1], value); Console.WriteLine("сохранено"); return 0;
                }
                if (args.Length == 4 && args[0] == "import" && args[2] == "--from") {
                    ConfigBundle.ValidName(args[1]); string source = args[3], value;
                    if (source.StartsWith("env:", StringComparison.Ordinal)) {
                        string variable = source.Substring(4);
                        if (variable.Any(char.IsControl) || !Regex.IsMatch(variable, "^[A-Za-z_][A-Za-z0-9_]{0,127}$")) return Usage();
                        value = Environment.GetEnvironmentVariable(variable);
                        if (value == null) { Console.Error.WriteLine("Переменная окружения не задана"); return 1; }
                    } else if (source.StartsWith("bitwarden:", StringComparison.Ordinal)) value = FromBitwarden(source.Substring(10));
                    else return Usage();
                    if (value == null || value.Length == 0) { Console.Error.WriteLine("Источник не содержит значения секрета"); return 1; }
                    SecretVault.Set(home, args[1], value); Console.WriteLine("сохранено"); return 0;
                }
                return Usage();
            } catch {
                // Exceptions from JSON/CLI/DPAPI can contain raw credential text. Never print them.
                Console.Error.WriteLine("Не удалось выполнить команду секрета; проверьте имя, доступность источника и хранилища");
                return 1;
            }
        }
        static int Usage()
        {
            Console.Error.WriteLine("secret set <имя> --why <объяснение> | secret status | secret import <имя> --from env:ИМЯ|bitwarden:объект/поле");
            return 2;
        }
        static int Status(string home)
        {
            using (var lease = new SecretVault.Lease(home)) {
                var values = SecretVault.Load(home);
                var settings = ConfigBundle.ReadSettings(home);
                var profile = ConfigBundle.CurrentProfile(home, settings); ConfigBundle.LegacyValues(home,settings,profile,values);
                var referenced = new HashSet<string>(ConfigBundle.References(profile).Select(r => Json.Str(r,"secret")), StringComparer.Ordinal);
                foreach (string name in values.Keys.Concat(referenced).Distinct(StringComparer.Ordinal).OrderBy(n => n,StringComparer.Ordinal)) {
                    string value; bool present = values.TryGetValue(name,out value) && value.Length > 0;
                    Console.WriteLine(name + ": " + (present ? "есть" : "нет") + (referenced.Contains(name) ? " (ссылка в конфиге)" : ""));
                }
                return 0;
            }
        }
        static string FromBitwarden(string source)
        {
            int slash = source.LastIndexOf('/');
            if (slash < 1 || slash == source.Length - 1 || source.Length > 512) throw new InvalidDataException();
            string item = source.Substring(0,slash), field = source.Substring(slash+1);
            if (item[0] == '-' || item.Any(char.IsControl) || field.Any(char.IsControl)) throw new InvalidDataException();
            var start = new ProcessStartInfo(SecretVault.Windows ? "bw.exe" : "bw",Files.Arguments(new[]{"get","item",item})) {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
                StandardOutputEncoding = Files.Utf8, StandardErrorEncoding = Files.Utf8
            };
            using (var process = Process.Start(start)) {
                process.StandardInput.Close();
                var output = ReadBounded(process.StandardOutput);
                var errors = process.StandardError.BaseStream.CopyToAsync(Stream.Null);
                try {
                    if (!process.WaitForExit(15000)) throw new IOException();
                    if (process.ExitCode != 0) throw new IOException();
                    if (!Task.WaitAll(new Task[]{output, errors}, 2000)) throw new IOException();
                    string json = output.GetAwaiter().GetResult();
                    return BitwardenField(Json.Map(Json.Parse(json)),field);
                } finally { try { if (!process.HasExited) process.Kill(); } catch { } }
            }
        }
        static async Task<string> ReadBounded(StreamReader reader)
        {
            var result = new StringBuilder(); var buffer = new char[4096]; int count; bool overflow = false;
            while ((count = await reader.ReadAsync(buffer,0,buffer.Length).ConfigureAwait(false)) > 0) {
                if (result.Length + count > ConfigBundle.MaxLength) overflow = true;
                if (!overflow) result.Append(buffer,0,count);
            }
            Array.Clear(buffer,0,buffer.Length);
            if (overflow) throw new InvalidDataException();
            return result.ToString();
        }
        internal static string BitwardenField(Dictionary<string,object> item, string field)
        {
            var login = Json.Map(Json.Get(item,"login"));
            if (field == "password" || field == "username" || field == "totp") return Json.Get(login,field) as string;
            if (field == "notes") return Json.Get(item,"notes") as string;
            // Only exact field names; no JSON paths, templates, commands, or evaluations.
            var matches = Json.Array(Json.Get(item,"fields")).Select(Json.Map).Where(f => Json.Str(f,"name") == field).ToArray();
            if (matches.Length != 1) throw new InvalidDataException();
            return Json.Get(matches[0],"value") as string;
        }
    }
}
