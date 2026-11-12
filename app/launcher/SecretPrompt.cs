using System;
using System.IO;
using System.Text;
using System.Threading;
#if !PORTABLE_TEST
using System.Drawing;
using System.Windows.Forms;
#endif

namespace RemoteAgents.Launcher
{
    internal static class SecretPrompt
    {
#if !PORTABLE_TEST
        public static string Ask(IWin32Window owner, string name, string why)
        {
            if (!SecretVault.Windows) return AskConsole(name, why);
            if (!Environment.UserInteractive) return null;
            if (Thread.CurrentThread.GetApartmentState() != ApartmentState.STA) {
                string result = null; Exception error = null;
                var thread = new Thread(() => { try { result = Ask(null, name, why); } catch (Exception e) { error = e; } });
                thread.SetApartmentState(ApartmentState.STA); thread.Start(); thread.Join();
                if (error != null) throw new InvalidOperationException("Не удалось показать окно ввода секрета");
                return result;
            }
            using (var form = new Form { Text = "RemoteAgents — секрет", ClientSize = new Size(560, 280), FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false, ShowInTaskbar = true, TopMost = true, StartPosition = owner == null ? FormStartPosition.CenterScreen : FormStartPosition.CenterParent, AutoScaleMode = AutoScaleMode.Dpi })
            using (var input = new SecretInput { Left = 20, Top = 130, Width = 520, UseSystemPasswordChar = true, MaxLength = ConfigBundle.MaxLength }) {
                form.Controls.Add(new Label { Left = 20, Top = 18, Width = 520, Height = 28, Text = name, Font = new Font(SystemFonts.MessageBoxFont, FontStyle.Bold), UseMnemonic = false });
                form.Controls.Add(new Label { Left = 20, Top = 50, Width = 520, Height = 72, Text = string.IsNullOrWhiteSpace(why) ? ConfigBundle.StandardHint(name) : why, UseMnemonic = false });
                form.Controls.Add(input);
                form.Controls.Add(new Label { Left = 20, Top = 165, Width = 520, Height = 36, Text = "Секрет сохраняется отдельно. В чат и журнал он не попадёт. Многострочный ключ можно вставить или выбрать из файла.", UseMnemonic = false });
                var fromFile = new Button { Left = 20, Top = 225, Width = 130, Height = 32, Text = "Из файла…" };
                fromFile.Click += (s, e) => {
                    using (var dialog = new OpenFileDialog { Title = "Секретный ключ или профиль", CheckFileExists = true }) {
                        if (dialog.ShowDialog(form) != DialogResult.OK) return;
                        try {
                            if (new FileInfo(dialog.FileName).Length > ConfigBundle.MaxLength) throw new IOException();
                            input.SetSecret(File.ReadAllText(dialog.FileName));
                        } catch { MessageBox.Show(form, "Не удалось прочитать файл секрета (лимит 4 МиБ).", "RemoteAgents", MessageBoxButtons.OK, MessageBoxIcon.Error); }
                    }
                };
                var save = new Button { Left = 310, Top = 225, Width = 110, Height = 32, Text = "Сохранить", DialogResult = DialogResult.OK };
                var cancel = new Button { Left = 430, Top = 225, Width = 110, Height = 32, Text = "Отмена", DialogResult = DialogResult.Cancel };
                form.Controls.Add(fromFile); form.Controls.Add(save); form.Controls.Add(cancel); form.AcceptButton = save; form.CancelButton = cancel;
                form.Shown += (s, e) => { form.Activate(); input.Focus(); };
                return form.ShowDialog(owner) == DialogResult.OK ? input.Secret : null;
            }
        }
        // A masked single-line edit cannot retain pasted multiline OpenSSH/OVPN text.
        // Intercept paste to retain that text in memory while displaying a fixed mask.
        sealed class SecretInput : TextBox
        {
            string imported;
            bool updating;
            internal string Secret { get { return imported ?? Text; } }
            internal void SetSecret(string value)
            {
                if (value.Length > ConfigBundle.MaxLength) return;
                imported = value; updating = true; try { Text = new string('x', Math.Min(12, value.Length)); SelectAll(); } finally { updating = false; }
            }
            protected override void OnTextChanged(EventArgs e) { if (!updating) imported = null; base.OnTextChanged(e); }
            protected override void WndProc(ref Message message)
            {
                const int Paste = 0x0302;
                if (message.Msg == Paste) {
                    try { if (Clipboard.ContainsText()) { string text = Clipboard.GetText(); if (text.IndexOfAny(new[]{'\r','\n'}) >= 0) { SetSecret(text); return; } } }
                    catch { return; }
                }
                base.WndProc(ref message);
            }
            protected override void Dispose(bool disposing) { imported = null; if (disposing) Clear(); base.Dispose(disposing); }
        }
#else
        public static string Ask(object owner, string name, string why) { return AskConsole(name, why); }
#endif
        static string AskConsole(string name, string why)
        {
            // An agent/pipe cannot supply an interactive password. Never fall back to echoed stdin.
            if (Console.IsInputRedirected) return null;
            Console.Error.WriteLine(name + ": " + (string.IsNullOrWhiteSpace(why) ? ConfigBundle.StandardHint(name) : why));
            var value = new StringBuilder();
            try {
                while (true) {
                    var key = Console.ReadKey(true);
                    if (key.Key == ConsoleKey.Escape || (key.Key == ConsoleKey.C && (key.Modifiers & ConsoleModifiers.Control) != 0)) return null;
                    if (key.Key == ConsoleKey.Enter) return value.ToString();
                    if (key.Key == ConsoleKey.Backspace) { if (value.Length > 0) value.Length--; }
                    else if (!char.IsControl(key.KeyChar) && value.Length < ConfigBundle.MaxLength) value.Append(key.KeyChar);
                }
            } finally { value.Clear(); Console.Error.WriteLine(); }
        }
    }
}
