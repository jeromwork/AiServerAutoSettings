using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace RemoteAgents.Launcher
{
    // A configured program started by hand: one small window with a big «Включить» (never at Windows sign-in).
    internal static class StartWindow
    {
        internal static bool Confirm()
        {
            using (var form = new Form { Text = Product.Name, StartPosition = FormStartPosition.CenterScreen, FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false,
                AutoScaleDimensions = new SizeF(96, 96), AutoScaleMode = AutoScaleMode.Dpi, Font = new Font("Segoe UI", 9F), ClientSize = new Size(340, 176), TopMost = true, KeyPreview = true }) {
                form.Controls.Add(new Label { Left = 16, Top = 14, Width = 308, Height = 28, Text = Product.Name + " настроен", Font = new Font("Segoe UI", 13F, FontStyle.Bold) });
                form.Controls.Add(new Label { Left = 16, Top = 46, Width = 308, Height = 36, Text = "Нажмите «Включить» — программа запустится и будет работать в трее (значок у часов)." });
                var on = new Button { Left = 16, Top = 88, Width = 308, Height = 50, Text = "Включить", Font = new Font("Segoe UI", 14F, FontStyle.Bold), DialogResult = DialogResult.OK,
                    BackColor = Color.FromArgb(0, 120, 212), ForeColor = Color.White, FlatStyle = FlatStyle.Flat };
                on.FlatAppearance.BorderSize = 0; form.Controls.Add(on); form.AcceptButton = on;
                var later = new LinkLabel { Left = 16, Top = 146, Width = 308, Height = 20, Text = "Не сейчас", TextAlign = ContentAlignment.MiddleCenter };
                later.LinkClicked += (a, b) => form.DialogResult = DialogResult.Cancel; form.Controls.Add(later);
                form.KeyDown += (a, b) => { if (b.KeyCode == Keys.Escape) form.DialogResult = DialogResult.Cancel; };
                return form.ShowDialog() == DialogResult.OK;
            }
        }
    }

    // One line per section: ⏳/✅/❌, a small bar while it runs, the current action and «Повторить» on failure.
    internal sealed class SectionRow : Panel
    {
        readonly Label icon = new Label { Left = 0, Top = 2, Width = 24, Height = 20, TextAlign = ContentAlignment.MiddleCenter };
        readonly Label title = new Label { Left = 26, Top = 2, Width = 112, Height = 20, TextAlign = ContentAlignment.MiddleLeft, AutoEllipsis = true };
        readonly ProgressBar bar = new ProgressBar { Left = 140, Top = 8, Width = 44, Height = 8, Style = ProgressBarStyle.Marquee, MarqueeAnimationSpeed = 30, Visible = false };
        readonly Label text = new Label { Left = 140, Top = 2, Width = 266, Height = 20, TextAlign = ContentAlignment.MiddleLeft, AutoEllipsis = true, Anchor = AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Top };
        internal readonly LinkLabel Retry = new LinkLabel { Left = 410, Top = 2, Width = 78, Height = 20, Text = "Повторить", TextAlign = ContentAlignment.MiddleRight, Visible = false, Anchor = AnchorStyles.Right | AnchorStyles.Top };
        readonly ToolTip tip; internal SectionState State = SectionState.Waiting;
        internal SectionRow(string caption, ToolTip tip)
        {
            this.tip = tip; Height = 24; Width = 488; Dock = DockStyle.Top;
            title.Text = caption; title.Font = new Font("Segoe UI", 9F, FontStyle.Bold);
            Controls.Add(icon); Controls.Add(title); Controls.Add(bar); Controls.Add(text); Controls.Add(Retry);
        }
        internal void Set(SectionState state, string message)
        {
            State = state; bool runningNow = state == SectionState.Running;
            icon.Text = state == SectionState.Done || state == SectionState.Unchanged ? "✅" : state == SectionState.Failed || state == SectionState.Blocked ? "❌" : state == SectionState.Waiting ? "•" : "⏳";
            icon.ForeColor = state == SectionState.Done || state == SectionState.Unchanged ? Color.ForestGreen : state == SectionState.Failed || state == SectionState.Blocked ? Color.Firebrick : state == SectionState.Waiting ? SystemColors.GrayText : Color.DarkGoldenrod;
            bar.Visible = runningNow; text.Left = runningNow ? 190 : 140; text.Width = Retry.Left - text.Left - 4;
            text.Text = message ?? ""; text.ForeColor = state == SectionState.Failed || state == SectionState.Blocked ? Color.Firebrick : SystemColors.ControlText;
            tip.SetToolTip(text, text.Text); Retry.Visible = state == SectionState.Failed || state == SectionState.Blocked;
        }
    }

    // «Вставить конфиг» (first run) and the tray settings (tabs «Конфиг» / «Папки»). Both apply through ConfigSession.
    internal sealed class ConfigWindow : Form
    {
        readonly string home; readonly Func<Task<string>> prepare; string bundle; readonly bool settings;
        internal bool Manual { get; private set; }
        readonly ToolTip tip = new ToolTip(); bool pasting = true;
        readonly Panel header = new Panel { Dock = DockStyle.Top }, pastePanel = new Panel { Dock = DockStyle.Top, Height = 204 },
            rowsPanel = new Panel { Dock = DockStyle.Top, Visible = false, Padding = new Padding(16, 6, 16, 4) },
            foldersPanel = new Panel { Dock = DockStyle.Top, Height = 236, Visible = false, Padding = new Padding(16, 4, 16, 4) },
            bottom = new Panel { Dock = DockStyle.Bottom, Height = 46, Padding = new Padding(12, 8, 12, 8) };
        readonly TextBox input = new TextBox { Multiline = true, ScrollBars = ScrollBars.Vertical, Left = 16, Top = 4, Width = 488, Height = 84, AcceptsReturn = true, WordWrap = true };
        readonly TextBox deviceName = new TextBox { Width = 250 };
        readonly TextBox journal = new TextBox { Dock = DockStyle.Fill, ReadOnly = true, Multiline = true, ScrollBars = ScrollBars.Vertical, Visible = false, BackColor = SystemColors.Window };
        readonly Label inputHint = new Label { Left = 16, Top = 90, Width = 488, Height = 32, ForeColor = SystemColors.GrayText };
        readonly Button start = new Button { Left = 16, Top = 124, Width = 488, Height = 46, Text = "Запустить", Font = new Font("Segoe UI", 14F, FontStyle.Bold),
            BackColor = Color.FromArgb(0, 120, 212), ForeColor = Color.White, FlatStyle = FlatStyle.Flat };
        readonly LinkLabel steps = new LinkLabel { Left = 300, Top = 174, Width = 204, Height = 20, Text = "Пройти по шагам", TextAlign = ContentAlignment.MiddleRight };
        readonly LinkLabel openFile = new LinkLabel { Left = 210, Top = 174, Width = 150, Height = 20, Text = "Открыть файл…" };
        readonly Button askAi = new Button { Left = 16, Top = 172, Width = 186, Height = 26, Text = "Собрать конфиг с ИИ" };
        readonly Button done = new Button { Text = "Готово", Width = 110, Dock = DockStyle.Right, Visible = false }, close = new Button { Text = "Закрыть", Width = 100, Dock = DockStyle.Right };
        readonly TreeView tree = new TreeView { Dock = DockStyle.Fill, CheckBoxes = true };
        readonly Dictionary<string, SectionRow> rows = new Dictionary<string, SectionRow>();
        DiskFolderTree folders; string foldersBase = "";
        TabControl tabs; TextBox configText; Button apply, folderApply;
        readonly CancellationTokenSource cancel = new CancellationTokenSource();
        Task<string> preparing; ConfigSession session; bool running, closingRequested; string defaultName;

        internal static bool First(string home, Func<Task<string>> prepare)
        { using (var form = new ConfigWindow(home, null, prepare, false)) { form.ShowDialog(); return form.Manual; } }
        internal static void Settings(string home, string bundle, bool foldersTab)
        {
            using (var form = new ConfigWindow(home, bundle, null, true)) {
                if (foldersTab) form.tabs.SelectedIndex = 1;
                form.ShowDialog();
            }
        }
        ConfigWindow(string home, string bundle, Func<Task<string>> prepare, bool settings)
        {
            this.home = home; this.bundle = bundle; this.prepare = prepare; this.settings = settings;
            AutoScaleDimensions = new SizeF(96, 96); AutoScaleMode = AutoScaleMode.Dpi; Font = new Font("Segoe UI", 9F);
            Text = Product.Name + (settings ? " — настройки" : " — подключение"); FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen; ClientSize = new Size(520, 300); TopMost = !settings; KeyPreview = true;
            start.FlatAppearance.BorderSize = 0;
            folders = new DiskFolderTree(tree, path => Task.Run(() => WizardRunner.Run(home, this.bundle, "DiskTree", new { @base = foldersBase, path }, cancel.Token)), Guard, () => running, Log);
            foldersPanel.Controls.Add(tree);
            foldersPanel.Controls.Add(new Label { Dock = DockStyle.Top, Height = 40, Text = "Какие папки держать на этом компьютере? Отметьте нужные; снятие отметки файлы не удаляет. Выбор сохранится в конфиге." });
            bottom.Controls.Add(done); bottom.Controls.Add(new Label { Dock = DockStyle.Right, Width = 8 }); bottom.Controls.Add(close);
            if (settings) BuildSettings(); else BuildPaste();
            // Docking: the last added control is the outermost one.
            Controls.Add(journal); Controls.Add(foldersPanel); Controls.Add(rowsPanel);
            if (!settings) Controls.Add(pastePanel); else Controls.Add(tabs);
            Controls.Add(header); Controls.Add(bottom);
            foreach (string s in ConfigSections.Rows.Reverse()) {
                string section = s; var row = new SectionRow(ConfigSections.Title(s), tip) { Visible = false }; rows[s] = row; rowsPanel.Controls.Add(row);
                row.Retry.LinkClicked += async (a, b) => await RetrySection(section);
            }
            close.Click += (a, b) => Close();
            done.Click += async (a, b) => await Finish();
            FormClosing += (a, b) => {
                if (!running) return; b.Cancel = true; closingRequested = true; Log("Отменяю текущую операцию…"); cancel.Cancel();
            };
            KeyDown += (a, b) => { if (b.KeyCode == Keys.Escape && !running) Close(); };
            Shown += (a, b) => Ready();
            Relayout();
        }
        protected override void Dispose(bool disposing) { if (disposing) { cancel.Dispose(); tip.Dispose(); } base.Dispose(disposing); }

        void BuildPaste()
        {
            header.Height = 74;
            header.Controls.Add(new Label { Left = 16, Top = 10, Width = 488, Height = 30, Text = "Вставьте конфиг", Font = new Font("Segoe UI", 15F, FontStyle.Bold) });
            header.Controls.Add(new Label { Left = 16, Top = 42, Width = 488, Height = 30, ForeColor = SystemColors.GrayText,
                Text = "Текст конфига, ссылку https://… или перетащите файл сюда. Конфиг выдаёт администратор или составляет ИИ-агент по docs/CONFIG.md." });
            defaultName = "Компьютер " + Environment.UserName;
            var nameLabel = new Label { Left = 16, Top = 94, Width = 150, Height = 22, Text = "Название компьютера:", TextAlign = ContentAlignment.MiddleLeft };
            deviceName.Left = 170; deviceName.Top = 92; deviceName.Text = defaultName;
            tip.SetToolTip(deviceName, "Так этот компьютер будет называться у агентов и в списке компьютеров (вместо WIN-…).");
            inputHint.Top = 118; inputHint.Height = 0;
            pastePanel.Controls.Add(input); pastePanel.Controls.Add(nameLabel); pastePanel.Controls.Add(deviceName); pastePanel.Controls.Add(inputHint);
            pastePanel.Controls.Add(start); pastePanel.Controls.Add(askAi); pastePanel.Controls.Add(openFile); pastePanel.Controls.Add(steps);
            start.Top = 122; askAi.Top = 172; openFile.Top = steps.Top = 176;
            tip.SetToolTip(askAi, "Скопирует готовый запрос для ИИ-чата в браузере: он расспросит вас и выдаст конфиг без паролей.");
            askAi.Click += (a, b) => CopyAiPrompt();
            AllowDrop = input.AllowDrop = true;
            DragEventHandler enter = (a, b) => { if (b.Data.GetDataPresent(DataFormats.FileDrop) || b.Data.GetDataPresent(DataFormats.UnicodeText)) b.Effect = DragDropEffects.Copy; };
            DragEventHandler drop = (a, b) => {
                if (running) return;
                var files = b.Data.GetData(DataFormats.FileDrop) as string[];
                if (files != null && files.Length == 1) LoadFile(files[0]); else if (b.Data.GetDataPresent(DataFormats.UnicodeText)) input.Text = Convert.ToString(b.Data.GetData(DataFormats.UnicodeText));
            };
            DragEnter += enter; DragDrop += drop; input.DragEnter += enter; input.DragDrop += drop;
            openFile.LinkClicked += (a, b) => { using (var d = new OpenFileDialog { Filter = "Конфиг RemoteAgents (*.json)|*.json|Все файлы|*.*", CheckFileExists = true }) if (d.ShowDialog(this) == DialogResult.OK) LoadFile(d.FileName); };
            steps.LinkClicked += (a, b) => { if (running) return; Manual = true; Close(); };
            start.Click += async (a, b) => await StartFromText(input.Text);
            AcceptButton = null;
        }
        void BuildSettings()
        {
            header.Height = 44;
            var profile = ConfigProfile.Load(home);
            header.Controls.Add(new Label { Left = 16, Top = 13, Width = 150, Height = 22, Text = "Название компьютера:", TextAlign = ContentAlignment.MiddleLeft });
            deviceName.Left = 170; deviceName.Top = 12; deviceName.Text = ConfigProfile.DeviceName(profile); header.Controls.Add(deviceName);
            var saveName = new Button { Left = 428, Top = 10, Width = 76, Height = 26, Text = "Сменить" }; header.Controls.Add(saveName);
            tip.SetToolTip(deviceName, "Так этот компьютер называется у агентов и в списке компьютеров. Смена сразу уходит на сервер.");
            saveName.Click += async (a, b) => await RenameDevice();
            tabs = new TabControl { Dock = DockStyle.Top, Height = 300 };
            var configTab = new TabPage("Конфиг") { Padding = new Padding(6) }; var foldersTab = new TabPage("Папки") { Padding = new Padding(6) };
            configText = new TextBox { Dock = DockStyle.Fill, Multiline = true, ScrollBars = ScrollBars.Both, WordWrap = false, AcceptsReturn = true, AcceptsTab = false, Font = new Font("Consolas", 9F) };
            tip.SetToolTip(configText, "Текущий конфиг без секретов. Можно поправить или вставить другой и нажать «Применить» — применятся только изменившиеся разделы.");
            var bar = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 36, FlowDirection = FlowDirection.LeftToRight, Padding = new Padding(0, 4, 0, 0) };
            var copy = new Button { Text = "Скопировать", AutoSize = true }; apply = new Button { Text = "Применить", AutoSize = true, Font = new Font("Segoe UI", 9F, FontStyle.Bold) };
            var save = new Button { Text = "Сохранить конфиг в файл…", AutoSize = true }; var details = new Button { Text = "Подробно…", AutoSize = true };
            tip.SetToolTip(copy, "В буфер — без секретов: можно показать ИИ-агенту или в чат.");
            tip.SetToolTip(details, "Прежние разделы настройки по шагам; они меняют тот же конфиг.");
            bar.Controls.Add(copy); bar.Controls.Add(apply); bar.Controls.Add(save); bar.Controls.Add(details);
            configTab.Controls.Add(configText); configTab.Controls.Add(bar);
            folderApply = new Button { Text = "Применить выбор", AutoSize = true, Font = new Font("Segoe UI", 9F, FontStyle.Bold) };
            var folderBar = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 36, Padding = new Padding(0, 4, 0, 0) }; folderBar.Controls.Add(folderApply);
            foldersTab.Controls.Add(tree); foldersTab.Controls.Add(new Label { Dock = DockStyle.Top, Height = 36, Text = "Какие папки держать на этом компьютере. Снятие отметки файлы не удаляет. Выбор сохраняется в конфиге." }); foldersTab.Controls.Add(folderBar);
            tabs.TabPages.Add(configTab); tabs.TabPages.Add(foldersTab);
            copy.Click += (a, b) => { try { Clipboard.SetText(configText.Text); Log("Конфиг скопирован без секретов."); } catch (Exception e) { Log("Ошибка: " + e.Message); } };
            apply.Click += async (a, b) => await StartFromText(configText.Text);
            save.Click += (a, b) => SaveToFile();
            details.Click += (a, b) => Details();
            folderApply.Click += async (a, b) => await ApplyFolders(false);
            tabs.SelectedIndexChanged += async (a, b) => { if (tabs.SelectedIndex == 1 && !folders.Loaded) await LoadFolders(); };
            RefreshConfigText();
        }
        void RefreshConfigText() { try { configText.Text = ConfigText.Pretty(ConfigBundle.ExportForAi(home)); } catch (Exception e) { configText.Text = ""; Log("Конфиг не прочитан: " + e.Message); } }

        async void Ready()
        {
            if (settings) { journal.Visible = true; Relayout(); if (tabs.SelectedIndex == 1) await LoadFolders(); return; }
            // Bundle extraction starts at once and overlaps with pasting.
            if (prepare != null) preparing = prepare();
            string beside = ConfigSource.FindBeside(Path.GetDirectoryName(Program.Exe));
            if (beside != null) { LoadFile(beside); Hint("Найден конфиг рядом с программой: " + Path.GetFileName(beside) + ". Нажмите «Запустить»."); }
            else if (ConfigProfile.Load(home).Count > 0) {
                try { input.Text = ConfigText.Pretty(ConfigBundle.ExportForAi(home)); Hint("Конфиг уже вставлялся раньше — нажмите «Запустить», чтобы продолжить настройку."); } catch (Exception) { }
            }
            string name = ConfigProfile.DeviceName(ConfigProfile.Load(home)); if (name.Length > 0) deviceName.Text = defaultName = name;
            input.Focus();
        }
        void Hint(string text, bool error = false)
        {
            inputHint.Text = text; inputHint.ForeColor = error ? Color.Firebrick : SystemColors.GrayText;
            int height = text.Length == 0 ? 0 : text.Length > 110 ? 50 : 32; if (inputHint.Height == height) return;
            inputHint.Height = height; start.Top = 122 + height; askAi.Top = 172 + height; openFile.Top = steps.Top = 176 + height; pastePanel.Height = 204 + height; Relayout();
        }
        // «Собрать конфиг с ИИ»: a ready request for any AI chat (embedded config-ai-prompt.md), into the clipboard.
        void CopyAiPrompt()
        {
            try {
                string prompt;
                using (var stream = typeof(ConfigWindow).Assembly.GetManifestResourceStream("RemoteAgents.ConfigAiPrompt.md"))
                using (var reader = new StreamReader(stream, Files.Utf8)) prompt = reader.ReadToEnd();
                prompt = Regex.Replace(prompt, "^<!--.*?-->\\s*", "", RegexOptions.Singleline);
                Clipboard.SetText(prompt.Replace("\r\n", "\n").Replace("\n", "\r\n"));
                Hint("Запрос скопирован. Вставьте в чат ИИ (ChatGPT, Claude, Gemini). Он задаст вопросы и выдаст конфиг без паролей — вставьте его сюда, пароли программа спросит сама.");
            } catch (Exception e) { Hint("Запрос не скопирован: " + e.Message, true); }
        }
        void LoadFile(string path)
        { try { input.Text = ConfigSource.ReadFile(path); Hint(""); } catch (Exception e) { Hint(e.Message, true); } }
        async Task<string> Bundle()
        {
            if (bundle != null) return bundle;
            if (prepare == null) throw new IOException("Программа не подготовлена");
            if (preparing == null || preparing.IsFaulted || preparing.IsCanceled) preparing = prepare();
            Log("Подготавливаю программу…");
            try { bundle = await preparing; }
            catch (OperationCanceledException) { throw; }
            catch (Exception e) { new Journal(home).Write("bundle.bootstrap.failed " + e.GetType().Name); throw new IOException("Не удалось подготовить файлы программы. Проверьте доступ к интернету и нажмите «Запустить» ещё раз. Журнал: logs\\launcher.log"); }
            return bundle;
        }
        void Relayout()
        {
            // Not pastePanel.Visible: before the form is shown WinForms reports every child as hidden.
            int height = header.Height + bottom.Height + (settings ? tabs.Height : pasting ? pastePanel.Height : 0);
            int visibleRows = rows.Values.Count(r => r.Visible); rowsPanel.Height = visibleRows * 24 + 12;
            if (rowsPanel.Visible) height += rowsPanel.Height;
            if (foldersPanel.Visible) height += foldersPanel.Height;
            if (journal.Visible) height += 120;
            var area = Screen.FromControl(this).WorkingArea;
            ClientSize = new Size(ClientSize.Width, Math.Min(height, area.Height - 60));
        }
        void Ui(Action action)
        {
            if (IsDisposed) return;
            try { if (InvokeRequired) BeginInvoke(action); else action(); } catch (InvalidOperationException) { }
        }
        void Log(string text)
        {
            Ui(() => { journal.AppendText(DateTime.Now.ToString("HH:mm:ss") + " " + text + "\r\n"); if (!journal.Visible) { journal.Visible = true; Relayout(); } });
        }
        void Report(string section, SectionState state, string text)
        {
            Ui(() => {
                SectionRow row; if (!rows.TryGetValue(section == ConfigSections.Bootstrap ? ConfigSections.Server : section, out row)) return;
                if (section == ConfigSections.Bootstrap) { text = "VPN первым: " + text; if (state == SectionState.Done || state == SectionState.Failed) state = SectionState.Waiting; }
                row.Set(state, text);
            });
        }
        void SetBusy(bool value)
        {
            running = value; start.Enabled = !value; askAi.Enabled = !value; steps.Enabled = !value; openFile.Enabled = !value; done.Enabled = !value; input.ReadOnly = value;
            if (apply != null) { apply.Enabled = folderApply.Enabled = !value; }
            UseWaitCursor = false; Cursor = value ? Cursors.AppStarting : Cursors.Default;
        }
        async Task Guard(Func<Task> action)
        {
            if (running) return; SetBusy(true);
            try { await action(); } catch (OperationCanceledException) { } catch (Exception e) { Log("Ошибка: " + e.Message); }
            finally { SetBusy(false); if (closingRequested) Close(); }
        }

        // Paste -> parse -> master password -> conflicts -> store -> plan -> run.
        async Task StartFromText(string text)
        {
            if (running) return; Hint("");
            await Guard(async () => {
                string source;
                try {
                    var kind = ConfigSource.Classify(text);
                    if (kind == ConfigSource.Kind.Empty) { Hint("Вставьте конфиг, ссылку или перетащите файл.", true); if (settings) Log("Поле конфига пустое."); return; }
                    if (kind == ConfigSource.Kind.Url) { Log("Загружаю конфиг по ссылке…"); string url = text.Trim(); source = await Task.Run(() => ConfigSource.Download(url, cancel.Token)); }
                    else if (kind == ConfigSource.Kind.File) source = ConfigSource.ReadFile(text);
                    else source = text;
                } catch (Exception e) when (e is InvalidDataException || e is IOException) { Hint(e.Message, true); Log("Ошибка: " + e.Message); return; }
                ParsedConfig parsed;
                try { parsed = ConfigBundle.Parse(source); } catch (InvalidDataException e) { Hint(e.Message, true); Log("Конфиг не принят: " + e.Message); return; }
                while (parsed.Locked) {
                    string master = AskPassword(this, "Мастер-пароль", "Секреты в конфиге закрыты мастер-паролем. Введите его — он нужен один раз и нигде не сохраняется.", false);
                    if (master == null) { Log("Вставка отменена: мастер-пароль не введён."); return; }
                    try { parsed = ConfigBundle.Unlock(parsed, master); } catch (InvalidDataException e) { MessageBox.Show(this, e.Message, Product.Name, MessageBoxButtons.OK, MessageBoxIcon.Warning); }
                }
                if (!settings) {
                    // Name: what the person typed wins over the config; the default yields to the config's name.
                    string typed = deviceName.Text.Trim(), configured = ConfigProfile.DeviceName(parsed.Profile);
                    string name = typed.Length > 0 && (typed != defaultName || configured.Length == 0) ? typed : configured;
                    if (name.Length > 0) { var withName = ConfigProfile.WithDeviceName(parsed.Profile, name); parsed.Profile["device"] = withName["device"]; deviceName.Text = name; }
                }
                var conflicts = ConfigBundle.Conflicts(home, parsed); HashSet<int> take = new HashSet<int>();
                if (conflicts.Length > 0) {
                    string current = ""; try { current = ConfigText.Pretty(ConfigBundle.ExportForAi(home)); } catch (Exception) { }
                    take = ChooseConflicts(this, conflicts, ConfigAi.Request(current, ConfigText.Pretty(ConfigAi.Redact(parsed.Profile, parsed.Secrets)), conflicts));
                    if (take == null) { Log("Применение отменено: расхождения не выбраны."); return; }
                }
                var accept = ConfigSections.Accept(parsed.Profile.Keys, conflicts, take);
                var kept = parsed.Profile.Keys.Where(ConfigSections.Known).Where(k => !accept.Contains(k)).ToArray();
                if (kept.Length > 0) Log("Оставлено как есть: " + string.Join(", ", kept));
                ConfigBundle.Store(home, parsed, accept);
                Log("Конфиг принят" + (parsed.Missing.Length > 0 ? "; пустых секретов: " + parsed.Missing.Length + " (спрошу по одному)" : "") + ".");
                await RunSession(new ConfigSession(home, Bundle, parsed.Secrets, parsed.Hints), null);
            });
        }
        async Task RunSession(ConfigSession next, IList<string> forced)
        {
            session = next;
            session.Log = Log; session.Report = Report;
            session.AskSecret = (name, why) => { string value = null; Func<string> ask = () => SecretPrompt.Ask(this, name, why); value = InvokeRequired ? (string)Invoke(ask) : ask(); return value; };
            rowsPanel.Visible = true;
            if (!settings) { pasting = false; pastePanel.Visible = false; header.Height = 44; header.Controls[1].Visible = false; ((Label)header.Controls[0]).Text = "Подключаю"; }
            await Bundle();
            var watch = Stopwatch.StartNew();
            var plan = forced ?? await session.Plan(cancel.Token);
            var profile = ConfigProfile.Load(home);
            foreach (var pair in rows) {
                bool described = ConfigSections.Present(profile, pair.Key);
                pair.Value.Visible = described || plan.Contains(pair.Key);
                if (forced == null || plan.Contains(pair.Key)) pair.Value.Set(plan.Contains(pair.Key) ? SectionState.Waiting : SectionState.Unchanged, plan.Contains(pair.Key) ? "в очереди" : "без изменений");
            }
            Relayout();
            if (plan.Count == 0) Log("Ничего не изменилось: всё уже настроено так, как в конфиге.");
            session.AskMissing(plan);
            await session.Execute(plan, cancel.Token);
            Log("Выполнено за " + (watch.ElapsedMilliseconds / 1000.0).ToString("0.0", CultureInfo.InvariantCulture) + " с.");
            var follow = session.FollowPending(cancel.Token).ContinueWith(t => { if (t.IsFaulted) Log("Слежение за установкой на сервере остановлено: " + t.Exception.GetBaseException().Message); }, TaskScheduler.Default);
            if (!settings) {
                bool disk = ConfigSections.Present(profile, ConfigSections.Disk) && rows[ConfigSections.Disk].State != SectionState.Failed && rows[ConfigSections.Disk].State != SectionState.Blocked;
                if (disk && !folders.Loaded) { foldersPanel.Visible = true; Relayout(); await LoadFoldersInner(); }
                done.Visible = true; AcceptButton = done; done.Focus();
            } else RefreshConfigText();
        }
        async Task RetrySection(string section)
        {
            if (running) return;
            var plan = new List<string> { section };
            // A repaired server releases the sections that waited for it.
            if (section == ConfigSections.Server) plan.AddRange(rows.Where(r => r.Value.State == SectionState.Blocked).Select(r => r.Key));
            await Guard(() => RunSession(session ?? new ConfigSession(home, Bundle), ConfigSections.Order.Where(plan.Contains).ToList()));
        }
        async Task LoadFolders() { await Guard(LoadFoldersInner); }
        async Task LoadFoldersInner()
        {
            await Bundle();
            var disk = Json.Map(Json.Get(ConfigProfile.Load(home), "disk")); foldersBase = Json.Text(disk, "base", ConfigSession.DiskBase());
            string b = foldersBase;
            try {
                var data = await Task.Run(() => WizardRunner.Run(home, bundle, "DiskTree", new { @base = b, path = "" }, cancel.Token));
                folders.ShowRoot(data, disk.ContainsKey("folders") ? Json.Strings(Json.Get(disk, "folders")) : null);
            } catch (OperationCanceledException) { throw; } catch (Exception e) { Log("Папки диска не загружены: " + e.Message); }
        }
        // Folders -> profile.disk.folders, then the Disk action applies only that.
        async Task ApplyFolders(bool quietWhenSame)
        {
            if (!folders.Loaded) { if (!quietWhenSame) Log("Сначала дождитесь загрузки папок."); return; }
            var profile = ConfigProfile.Load(home); var disk = Json.Map(Json.Get(profile, "disk"));
            var paths = folders.Selection.Paths;
            if (disk.ContainsKey("folders") && Json.Strings(Json.Get(disk, "folders")).SequenceEqual(paths)) { if (!quietWhenSame) Log("Выбор папок не изменился."); return; }
            ConfigProfile.Update(home, p => { var updated = ConfigProfile.WithFolders(p, paths, foldersBase); p["disk"] = updated["disk"]; });
            Log("Папки: " + (paths.Length == 0 ? "ничего не выбрано" : string.Join(", ", paths)));
            await Guard(() => RunSession(session ?? new ConfigSession(home, Bundle), new List<string> { ConfigSections.Disk }));
        }
        async Task Finish()
        {
            if (running) return;
            if (foldersPanel.Visible) await ApplyFolders(true);
            if (!FirstInstall.Required(home)) { DialogResult = DialogResult.OK; Close(); return; }
            bool ok = false;
            await Guard(async () => {
                Log("Проверяю итог: связь и мост…");
                var result = await (session ?? new ConfigSession(home, Bundle)).Activate(cancel.Token);
                Log(result.Summary); ok = !FirstInstall.Required(home);
            });
            if (ok) { DialogResult = DialogResult.OK; Close(); }
            else Log("Настройка ещё не завершена: исправьте разделы с ❌ («Повторить») и нажмите «Готово» снова.");
        }
        async Task RenameDevice()
        {
            string name = deviceName.Text.Trim();
            if (name.Length == 0 || name.Length > 80 || name.Any(char.IsControl)) { Log("Название: от 1 до 80 символов."); return; }
            ConfigProfile.Update(home, p => { p["device"] = ConfigProfile.WithDeviceName(p, name)["device"]; });
            Log("Название компьютера: «" + name + "». Сообщаю серверу…");
            await Guard(() => RunSession(session ?? new ConfigSession(home, Bundle), new List<string> { ConfigSections.Bridge }));
        }
        void Details()
        {
            if (running) return;
            try { SetupWizard.Display(home, bundle, false); ConfigSession.SyncFromSettings(home); RefreshConfigText(); folders.Loaded = false; }
            catch (Exception e) { Log("Ошибка: " + e.Message); }
        }
        void SaveToFile()
        {
            string master; if (!AskSaveMode(this, out master)) return;
            string name = Regex.Replace(ConfigProfile.DeviceName(ConfigProfile.Load(home)), "[^\\p{L}\\p{N}_-]+", "-").Trim('-');
            using (var d = new SaveFileDialog { Filter = "Конфиг RemoteAgents (*.json)|*.json", FileName = "remoteagents" + (name.Length > 0 ? "-" + name : "") + ".json", OverwritePrompt = true }) {
                if (d.ShowDialog(this) != DialogResult.OK) return;
                try { Files.Atomic(d.FileName, ConfigBundle.Export(home, master)); Log("Конфиг сохранён" + (master == null ? " БЕЗ пароля — храните файл как пароль" : " с мастер-паролем") + ": " + d.FileName); }
                catch (Exception e) { Log("Ошибка сохранения: " + e.Message); }
            }
        }

        // Hidden input; null = cancel. confirm: second field must match (new master password).
        internal static string AskPassword(IWin32Window owner, string caption, string text, bool confirm)
        {
            using (var form = new Form { Text = Product.Name + " — " + caption, ClientSize = new Size(400, confirm ? 186 : 140), StartPosition = FormStartPosition.CenterParent,
                FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false, AutoScaleMode = AutoScaleMode.Dpi, Font = new Font("Segoe UI", 9F) }) {
                form.Controls.Add(new Label { Left = 12, Top = 10, Width = 376, Height = 50, Text = text });
                var first = new TextBox { Left = 12, Top = 62, Width = 376, UseSystemPasswordChar = true }; form.Controls.Add(first);
                var second = new TextBox { Left = 12, Top = 108, Width = 376, UseSystemPasswordChar = true, Visible = confirm };
                if (confirm) { form.Controls.Add(new Label { Left = 12, Top = 88, Width = 376, Height = 18, Text = "Ещё раз:" }); form.Controls.Add(second); }
                int top = confirm ? 146 : 100;
                var ok = new Button { Text = "OK", Left = 212, Top = top, Width = 86, DialogResult = DialogResult.OK }; var cancel = new Button { Text = "Отмена", Left = 302, Top = top, Width = 86, DialogResult = DialogResult.Cancel };
                form.Controls.Add(ok); form.Controls.Add(cancel); form.AcceptButton = ok; form.CancelButton = cancel;
                while (form.ShowDialog(owner) == DialogResult.OK) {
                    if (first.Text.Length == 0) continue;
                    if (confirm && first.Text != second.Text) { MessageBox.Show(form, "Пароли не совпадают", Product.Name); second.Clear(); continue; }
                    return first.Text;
                }
                return null;
            }
        }
        static bool AskSaveMode(IWin32Window owner, out string master)
        {
            master = null;
            using (var form = new Form { Text = Product.Name + " — сохранить конфиг", ClientSize = new Size(420, 168), StartPosition = FormStartPosition.CenterParent,
                FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false, AutoScaleMode = AutoScaleMode.Dpi, Font = new Font("Segoe UI", 9F) }) {
                form.Controls.Add(new Label { Left = 12, Top = 10, Width = 396, Height = 34, Text = "Полный конфиг со всеми настройками и секретами: им можно восстановить программу или подключить ещё один свой компьютер." });
                var withPassword = new RadioButton { Left = 12, Top = 52, Width = 396, Height = 22, Text = "С мастер-паролем (секреты зашифрованы; пароль передавайте отдельно)", Checked = true };
                var plain = new RadioButton { Left = 12, Top = 78, Width = 396, Height = 36, Text = "Без пароля — секреты открытым текстом. Храните файл как пароль." };
                form.Controls.Add(withPassword); form.Controls.Add(plain);
                var ok = new Button { Text = "Дальше…", Left = 232, Top = 128, Width = 86, DialogResult = DialogResult.OK }; var cancel = new Button { Text = "Отмена", Left = 322, Top = 128, Width = 86, DialogResult = DialogResult.Cancel };
                form.Controls.Add(ok); form.Controls.Add(cancel); form.AcceptButton = ok; form.CancelButton = cancel;
                if (form.ShowDialog(owner) != DialogResult.OK) return false;
                if (plain.Checked) return true;
            }
            master = AskPassword(owner, "мастер-пароль", "Придумайте мастер-пароль для этого файла. Он нигде не сохраняется: без него конфиг не открыть.", true);
            return master != null;
        }
        // «сейчас / в конфиге» per conflict; default «Оставить как есть». Returns indices taken from the config, null = cancel.
        internal static HashSet<int> ChooseConflicts(IWin32Window owner, string[] conflicts, string aiText)
        {
            int height = 74 + conflicts.Length * 64 + 48;
            using (var form = new Form { Text = Product.Name + " — конфиг расходится с настроенным", ClientSize = new Size(520, Math.Min(height, 560)), StartPosition = FormStartPosition.CenterParent,
                FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false, AutoScaleMode = AutoScaleMode.Dpi, Font = new Font("Segoe UI", 9F), AutoScroll = true }) {
                form.Controls.Add(new Label { Left = 12, Top = 10, Width = 496, Height = 54, Text = "Конфиг меняет то, что уже настроено. Эти пункты сами не применяются — выберите для каждого. Остальные разделы конфига применятся как обычно." });
                var take = new List<RadioButton>(); int top = 66;
                foreach (string line in conflicts) {
                    var box = new Panel { Left = 12, Top = top, Width = 496, Height = 58 };
                    box.Controls.Add(new Label { Left = 0, Top = 0, Width = 496, Height = 32, Text = line });
                    var fromConfig = new RadioButton { Left = 0, Top = 32, Width = 200, Height = 22, Text = "Взять из конфига" };
                    var keep = new RadioButton { Left = 210, Top = 32, Width = 200, Height = 22, Text = "Оставить как есть", Checked = true };
                    box.Controls.Add(fromConfig); box.Controls.Add(keep); form.Controls.Add(box); take.Add(fromConfig); top += 64;
                }
                var copy = new Button { Text = "Скопировать для ИИ", Left = 12, Top = top + 6, Width = 160, Height = 28 };
                var ok = new Button { Text = "Продолжить", Left = 332, Top = top + 6, Width = 88, Height = 28, DialogResult = DialogResult.OK };
                var cancel = new Button { Text = "Отмена", Left = 424, Top = top + 6, Width = 84, Height = 28, DialogResult = DialogResult.Cancel };
                var copied = new Label { Left = 178, Top = top + 12, Width = 150, Height = 20, ForeColor = Color.ForestGreen };
                copy.Click += (a, b) => { try { Clipboard.SetText(aiText); copied.Text = "Скопировано"; } catch (Exception) { copied.Text = "Буфер занят"; } };
                new ToolTip().SetToolTip(copy, "Запрос для ИИ-агента: ссылка на docs/CONFIG.md, оба конфига и расхождения — без секретов.");
                form.Controls.Add(copy); form.Controls.Add(copied); form.Controls.Add(ok); form.Controls.Add(cancel); form.AcceptButton = ok; form.CancelButton = cancel;
                if (form.ShowDialog(owner) != DialogResult.OK) return null;
                // One «keep» wins for its whole section (e.g. disk root and removed folders): ConfigSections.Accept.
                return new HashSet<int>(Enumerable.Range(0, conflicts.Length).Where(i => take[i].Checked));
            }
        }
    }
}
