using System;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Drawing;
using System.Windows.Forms;
using System.Threading;
using System.Security.AccessControl;
using System.Runtime.InteropServices;

// OpenSSH starts this program and owns its stdout pipe. No password is passed
// through PowerShell, command arguments, environment variables or disk files.
public static class RemoteAgentsAskpass
{
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int kind);
    [DllImport("kernel32.dll")] static extern uint GetFileType(IntPtr handle);

    public static string Classify(string prompt)
    {
        if (prompt == null || prompt.Length > 16384) return "unknown";
        if (prompt.Contains("Are you sure you want to continue connecting (yes/no") &&
            Regex.IsMatch(prompt, @"SHA256:[A-Za-z0-9+/=]+")) return "host";
        if (Regex.IsMatch(prompt, @"\A[^\r\n]+@[^\r\n]+'s password: ?\z")) return "password";
        if (Regex.IsMatch(prompt, @"\AEnter passphrase for key '[^\r\n]+': ?\z")) return "key";
        return "unknown";
    }

    public sealed class PasswordDialog : Form
    {
        public readonly TextBox Entry = new TextBox();
        public readonly Button Toggle = new Button();
        public PasswordDialog(string kind)
        {
            Text = kind == "password" ? "Пароль сервера" : "Защита подключения";
            ClientSize = new Size(520, 170); FormBorderStyle = FormBorderStyle.FixedDialog;
            StartPosition = FormStartPosition.CenterScreen; MaximizeBox = false; MinimizeBox = false;
            var label = new Label { Left = 16, Top = 14, Width = 488, Height = 42,
                Text = kind == "password" ? "Введите пароль пользователя VPS, не панели хостинга.\r\nВставить: Ctrl+V. Чтобы проверить ввод, нажмите «Показать»." : "Введите пароль защиты подключения, не пароль сервера.\r\nВставить: Ctrl+V. Чтобы проверить ввод, нажмите «Показать»." };
            Entry.SetBounds(16, 64, 372, 26); Entry.UseSystemPasswordChar = true;
            Entry.ShortcutsEnabled = true; Entry.MaxLength = 32767; Entry.TabIndex = 0;
            Toggle.Text = "Показать"; Toggle.SetBounds(396, 62, 108, 28);
            Toggle.Click += delegate { ToggleVisibility(); };
            var ok = new Button { Text = "Продолжить", DialogResult = DialogResult.OK };
            var cancel = new Button { Text = "Отмена", DialogResult = DialogResult.Cancel };
            ok.SetBounds(264, 116, 116, 30); cancel.SetBounds(388, 116, 116, 30);
            Controls.AddRange(new Control[] { label, Entry, Toggle, ok, cancel });
            AcceptButton = ok; CancelButton = cancel; Shown += delegate { Entry.Focus(); };
            FormClosing += delegate(object sender, FormClosingEventArgs e) {
                if (DialogResult == DialogResult.OK && (Encoding.UTF8.GetByteCount(Entry.Text) > 1022 || Entry.Text.IndexOfAny(new char[] { '\r', '\n', '\0' }) >= 0)) {
                    e.Cancel = true;
                    MessageBox.Show("Слишком длинный ввод или перенос строки. Проверьте пароль.", "Проверьте ввод", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                }
            };
        }
        public void ToggleVisibility()
        {
            Entry.UseSystemPasswordChar = !Entry.UseSystemPasswordChar;
            Toggle.Text = Entry.UseSystemPasswordChar ? "Показать" : "Скрыть";
        }
        protected override void Dispose(bool disposing)
        {
            if (disposing) Entry.Clear();
            base.Dispose(disposing);
        }
    }

    public static Form CreateHostDialog(string prompt)
    {
        var form = new Form { Text = "Проверьте сервер", ClientSize = new Size(680, 420),
            StartPosition = FormStartPosition.CenterScreen, MinimizeBox = false, MaximizeBox = false,
            FormBorderStyle = FormBorderStyle.FixedDialog };
        var label = new Label { Left = 16, Top = 14, Width = 648, Height = 48,
            Text = "Сверьте код SHA256 ниже с кодом в панели хостинга.\r\nНажмите «Да, код совпал» только после сверки. Иначе — «Отмена»." };
        var details = new TextBox { Left = 16, Top = 68, Width = 648, Height = 280,
            Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Both, WordWrap = false,
            Text = prompt, TabStop = false };
        var yes = new Button { Text = "Да, код совпал", DialogResult = DialogResult.Yes };
        var cancel = new Button { Text = "Отмена", DialogResult = DialogResult.Cancel };
        yes.SetBounds(364, 368, 160, 32); cancel.SetBounds(536, 368, 128, 32);
        form.Controls.AddRange(new Control[] { label, details, yes, cancel });
        // Enter and Escape both cancel: trusting a new server requires a deliberate click.
        form.AcceptButton = cancel; form.CancelButton = cancel;
        form.Shown += delegate { cancel.Focus(); };
        return form;
    }

    public static void WriteResponse(Stream output, string value)
    {
        byte[] bytes = new UTF8Encoding(false).GetBytes(value + "\n");
        try { output.Write(bytes, 0, bytes.Length); output.Flush(); }
        finally { Array.Clear(bytes, 0, bytes.Length); }
    }

    [STAThread]
    public static int Main(string[] args)
    {
        EventWaitHandle cancelled = null;
        try
        {
            string eventName = Environment.GetEnvironmentVariable("REMOTE_AGENTS_ASKPASS_CANCEL");
            if (String.IsNullOrEmpty(eventName) || GetFileType(GetStdHandle(-11)) != 3 || !Environment.UserInteractive)
                return 1;
            cancelled = EventWaitHandle.OpenExisting(eventName, EventWaitHandleRights.Modify | EventWaitHandleRights.Synchronize);
            if (cancelled.WaitOne(0)) return 1;
            string prompt = args.Length == 1 ? args[0] : null;
            string kind = Classify(prompt);
            Application.EnableVisualStyles();
            if (kind == "unknown")
            {
                cancelled.Set();
                MessageBox.Show("Неподдерживаемый вопрос подключения. Ввод остановлен без ответа.\r\nОбратитесь за помощью; пароль не вводите в это окно.", "Подключение остановлено", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return 1;
            }
            if (kind == "host")
            {
                using (Form form = CreateHostDialog(prompt))
                {
                    if (form.ShowDialog() != DialogResult.Yes) { cancelled.Set(); return 1; }
                    WriteResponse(Console.OpenStandardOutput(), "yes");
                    return 0;
                }
            }
            using (var form = new PasswordDialog(kind))
            {
                if (form.ShowDialog() != DialogResult.OK) { cancelled.Set(); return 1; }
                WriteResponse(Console.OpenStandardOutput(), form.Entry.Text);
                form.Entry.Clear();
                return 0;
            }
        }
        catch
        {
            if (cancelled != null) { try { cancelled.Set(); } catch { } }
            Console.Error.WriteLine("Окно ввода недоступно. Подключение остановлено.");
            return 1;
        }
        finally { if (cancelled != null) cancelled.Dispose(); }
    }
}