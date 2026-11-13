using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace RemoteAgents.Launcher
{
    internal static class CloudSettings
    {
        internal const string MailFolder = "Облако Mail";
        internal static Dictionary<string, object> First(object value)
        { return value is Dictionary<string, object> ? Json.Map(value) : Json.Map(Json.Array(value).FirstOrDefault()); }
        internal static string LocalFolder(Dictionary<string, object> settings)
        {
            string local = Json.Str(Json.Map(Json.Get(settings, "cloud")), "localFolder");
            if (local.Length > 0) return Environment.ExpandEnvironmentVariables(local);
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), MailFolder);
        }
        internal static string MissingFolder(string folder)
        { return "Папка облака не найдена: " + folder + ". Установите официальное приложение «Облако Mail» с https://cloud.mail.ru/ и войдите в свой аккаунт. Если выбрали другую папку, укажите cloud.localFolder в настройках этого устройства."; }
    }
    internal sealed class CloudCommandResult
    {
        internal int ExitCode;
        internal string Output = "", Error = "";
    }
    // Our only cloud protocol: one JSON on stdin; no password in commands, files or progress.
    internal static class CloudApply
    {
        internal const string Command = "bash \"$HOME/.local/share/remoteagents-cloud/server-cloud.sh\" apply";
        internal static SectionOutcome Apply(Dictionary<string, object> profile, Func<object, string> secret,
            Func<string, string, CloudCommandResult> execute)
        {
            var cloud = CloudSettings.First(Json.Get(profile, "cloud"));
            if (cloud.Count == 0) return new SectionOutcome { Ok = true, Summary = "Облако не задано — шаг пропущен" };
            string password = secret(Json.Get(cloud, "password"));
            if (string.IsNullOrEmpty(password)) return new SectionOutcome { Summary = "Не задан пароль облака" };
            var payload = new Dictionary<string, object> {
                { "vendor", Json.Str(cloud, "vendor") }, { "login", Json.Str(cloud, "login") }, { "password", password },
                { "remoteRoot", Json.Text(cloud, "remoteRoot", "Disk") }, { "localRoot", "~/Disk" }, { "pollSeconds", Json.Int(cloud, "pollSeconds", 20) }
            };
            CloudCommandResult result;
            try { result = execute(Command, Files.LF(Json.Encode(payload)) + "\n"); }
            catch (OperationCanceledException) { throw; }
            catch { return new SectionOutcome { Summary = "Не удалось выполнить настройку облака: проверьте связь с сервером" }; }
            bool ok = false;
            try { ok = result.ExitCode == 0 && Json.Bool(Json.Map(Json.Parse(Files.LF(result.Output))), "ok"); }
            catch { }
            if (ok) return new SectionOutcome { Ok = true, Summary = "Облако настроено на сервере ✓" };
            string reason = Files.LF(result.Error).Split('\n')[0].Trim();
            reason = Redact(reason, password);
            return new SectionOutcome { Summary = reason.Length == 0 ? "Сервер не подтвердил настройку облака (код " + result.ExitCode + ")" : reason };
        }
        internal static string Redact(string text, string password)
        {
            foreach (string value in new[] { Json.Encode(password).Trim('"'), password, Files.LF(password) }.Where(v => v.Length > 0).Distinct().OrderByDescending(v => v.Length)) text = text.Replace(value, "<secret>");
            return text.Length > 2048 ? text.Substring(0, 2048) : text;
        }
#if !PORTABLE_TEST
        internal static CloudCommandResult Execute(string home, string bundle, string input, System.Threading.CancellationToken token)
        {
            using (var relay = new PasswordRelay(input.TrimEnd('\n'))) {
                var result = WizardRunner.Run(home, bundle, "Cloud", new { secretPipe = relay.Name }, token);
                return new CloudCommandResult { ExitCode = Json.Int(result, "exitCode", -1), Output = Json.Str(result, "stdout"), Error = Json.Str(result, "stderr") };
            }
        }
#endif
    }
}
