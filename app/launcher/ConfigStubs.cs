// ВРЕМЕННЫЕ ЗАГЛУШКИ потока D для интерфейса потока A (docs/CONFIG-CONTRACT.md, раздел 3).
// Сигнатуры совпадают с соглашением. Координатор удаляет этот файл при слиянии с app/config-a.
// Поведение — минимально правдоподобное, чтобы окно и оркестратор можно было собрать и показать:
// шифрования enc1, DPAPI и проверки схемы здесь НЕТ.
#if !PORTABLE_TEST
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Windows.Forms;

namespace RemoteAgents.Launcher
{
    internal sealed class ParsedConfig { public Dictionary<string,object> Profile; public Dictionary<string,string> Secrets; public bool Locked;
                                         public string[] Missing; public Dictionary<string,string> Hints; }
    internal static class ConfigBundle
    {
        internal static ParsedConfig Parse(string text)
        {
            Dictionary<string,object> data;
            try { data = Json.Map(Json.Parse(text ?? "")); } catch (Exception) { throw new InvalidDataException("Это не конфиг RemoteAgents: текст не является JSON"); }
            if (Json.Str(data, "kind") != "remoteagents-config") throw new InvalidDataException("Это не конфиг RemoteAgents: нет \"kind\": \"remoteagents-config\"");
            var secrets = Json.Map(Json.Get(data, "secrets"));
            var profile = new Dictionary<string,object>(data); profile.Remove("secrets");
            var values = secrets.Where(p => p.Key != "protected" && p.Key != "kdf" && p.Key != "check").ToDictionary(p => p.Key, p => Json.Str(secrets, p.Key));
            return new ParsedConfig { Profile = profile, Secrets = values, Locked = secrets.ContainsKey("protected"),
                Missing = values.Where(p => p.Value.Length == 0).Select(p => p.Key).ToArray(), Hints = new Dictionary<string,string>() };
        }
        internal static ParsedConfig Unlock(ParsedConfig p, string master)
        { if (string.IsNullOrEmpty(master)) throw new InvalidDataException("Неверный мастер-пароль"); p.Locked = false; return p; }
        internal static string[] Conflicts(string home, ParsedConfig p) { return new string[0]; }
        internal static void Store(string home, ParsedConfig p, IEnumerable<string> acceptSections)
        {
            var accept = new HashSet<string>(acceptSections);
            ConfigProfile.Update(home, current => { foreach (var pair in p.Profile) if (accept.Contains(pair.Key) || !ConfigSections.Known(pair.Key)) current[pair.Key] = pair.Value; });
            foreach (var pair in p.Secrets) if (pair.Value.Length > 0 && pair.Value != ConfigAi.Hidden) SecretVault.Set(home, pair.Key, pair.Value);
        }
        internal static string Export(string home, string master)
        {
            var data = new Dictionary<string,object>(ConfigProfile.Load(home));
            var secrets = new Dictionary<string,object>(); foreach (var name in SecretVault.Names(home)) secrets[name] = File.ReadAllText(StubVault.File(home, name));
            data["secrets"] = secrets; return Json.Encode(data);
        }
        internal static string ExportForAi(string home)
        {
            var data = new Dictionary<string,object>(ConfigProfile.Load(home));
            data["secrets"] = SecretVault.Names(home).ToDictionary(n => n, n => (object)ConfigAi.Hidden); return Json.Encode(data);
        }
    }
    internal static class SecretVault
    {
        internal static void Set(string home, string name, string value) { Directory.CreateDirectory(Path.GetDirectoryName(StubVault.File(home, name))); Files.Atomic(StubVault.File(home, name), value); }
        internal static bool Has(string home, string name) { return File.Exists(StubVault.File(home, name)); }
        internal static string[] Names(string home)
        { string d = Path.Combine(home, "secrets", "stub-vault"); return Directory.Exists(d) ? Directory.GetFiles(d).Select(Path.GetFileName).Where(n => !n.EndsWith(".tmp")).OrderBy(n => n).ToArray() : new string[0]; }
        internal static void Materialize(string home) { }
    }
    internal static class SecretPrompt
    {
        internal static string Ask(IWin32Window owner, string name, string why)
        {
            using (var form = new Form { Text = "RemoteAgents — нужен секрет", ClientSize = new System.Drawing.Size(420, 150), StartPosition = FormStartPosition.CenterParent, FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false }) {
                form.Controls.Add(new Label { Left = 12, Top = 10, Width = 396, Height = 54, Text = why });
                var box = new TextBox { Left = 12, Top = 70, Width = 396, UseSystemPasswordChar = true }; form.Controls.Add(box);
                var ok = new Button { Text = "Сохранить", Left = 226, Top = 108, Width = 90, DialogResult = DialogResult.OK }; var cancel = new Button { Text = "Отмена", Left = 318, Top = 108, Width = 90, DialogResult = DialogResult.Cancel };
                form.Controls.Add(ok); form.Controls.Add(cancel); form.AcceptButton = ok; form.CancelButton = cancel;
                return form.ShowDialog(owner) == DialogResult.OK && box.Text.Length > 0 ? box.Text : null;
            }
        }
    }
    internal static class SecretCommand { internal static int Run(string home, string[] args) { Console.Error.WriteLine("secret: появится после слияния потока A"); return 2; } }
    static class StubVault { internal static string File(string home, string name) { return Path.Combine(home, "secrets", "stub-vault", name); } }
}
#endif
