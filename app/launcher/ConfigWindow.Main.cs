using System;
using System.Collections.Generic;
using System.Drawing;
using System.Diagnostics;
using System.Linq;
using System.Windows.Forms;

namespace RemoteAgents.Launcher
{
    // The existing settings form is the main window: the config editor, the step-by-step sections and the service tab.
    internal sealed partial class ConfigWindow
    {
        bool allowUnload, mainLaidOut;
        internal Action HiddenToTray;
        internal Func<string> MutationConflict;
        internal bool IsApplying { get { return running || detailsWindow != null && detailsWindow.IsApplying; } }
        readonly FlowLayoutPanel mainStatus = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, FlowDirection = FlowDirection.TopDown, WrapContents = false, Padding = new Padding(12, 8, 12, 4) };
        readonly Label syncStatus = new Label { AutoSize = true, MaximumSize = new Size(620, 0) };
        readonly Label technicalStatus = new Label { AutoSize = true, Visible = false, MaximumSize = new Size(620, 0) };
        readonly Label serverHealthDetails = new Label { AutoSize = true, MaximumSize = new Size(620, 0) };
        readonly Label pathStates = new Label { AutoSize = true, MaximumSize = new Size(620, 0) };
        readonly ComboBox pathChoice = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 430 };
        readonly FlowLayoutPanel serviceActions = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, FlowDirection = FlowDirection.TopDown, WrapContents = false, Padding = new Padding(10) };
        readonly List<Label> statusLines = new List<Label>();
        TabPage detailsTab, serviceTab; Panel detailsHost; SetupWizard detailsWindow;
        readonly FlowLayoutPanel happierAccount = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.TopDown, WrapContents = false, Visible = false, Padding = new Padding(0, 8, 0, 8) };
        readonly Label happierCaption = new Label { AutoSize = true, UseMnemonic = false, MaximumSize = new Size(620, 0) };
        readonly TextBox happierKey = new TextBox { ReadOnly = true, Visible = false, Width = 620 };
        readonly Button showHappierKey = new Button { Text = "Показать ключ", AutoSize = true };
        readonly Button copyHappierKey = new Button { Text = "Копировать ключ", AutoSize = true };
        readonly Button openHappier = new Button { Text = "Открыть Happier", AutoSize = true };
        readonly Label happierCreated = new Label { AutoSize = true, UseMnemonic = false, Visible = false, MaximumSize = new Size(620, 0), Padding = new Padding(8), BackColor = Color.LightGoldenrodYellow };
        HappierAccountModel happierModel = new HappierAccountModel();
        string pathsSignature = "";
        readonly PathSelection pathSelection = new PathSelection();
        internal static ConfigWindow Main(string home, string bundle)
        { return new ConfigWindow(home, bundle, null, true, true); }
        internal void RebindBundle(string current)
        {
            bundle = current;
            if (session != null) session.RebindBundle(current);
            if (followingSession != null && followingSession != session) followingSession.RebindBundle(current);
            if (detailsWindow != null && !detailsWindow.IsDisposed) detailsWindow.RebindBundle(current);
        }
        void BuildMain()
        {
            Text = Product.Name;
            var configPage = tabs.TabPages[0];
            detailsTab = new TabPage("Подробно") { AutoScroll = true };
            detailsHost = new Panel { Dock = DockStyle.Fill, AutoScroll = true }; detailsTab.Controls.Add(detailsHost);
            tabs.TabPages.Add(detailsTab);
            serviceTab = new TabPage("Сервис") { AutoScroll = true }; serviceTab.Controls.Add(serviceActions); tabs.TabPages.Add(serviceTab);
            BuildHappierAccount();
            serviceActions.Controls.Add(syncStatus);
            serviceActions.Controls.Add(serverHealthDetails);
            serviceActions.Controls.Add(pathStates);
            serviceActions.Controls.Add(new Label { Text = "Путь связи с сервером", AutoSize = true });
            serviceActions.Controls.Add(pathChoice);
            pathChoice.SelectionChangeCommitted += (s, e) => {
                var option = pathChoice.SelectedItem as PathOption;
                if (option != null) pathSelection.Choose(option.Tag);
            };
            for (int i = 0; i < WindowModel.StatusNames.Length; i++) { var line = new Label { AutoSize = true, MaximumSize = new Size(680, 0) }; statusLines.Add(line); mainStatus.Controls.Add(line); }
            mainStatus.Controls.Add(happierCreated);
            // Keep progress and the editor journal in the config page, not over the other tabs.
            // The paste window docks the journal Fill in its own layout row; here it sits under the editor.
            journal.Dock = DockStyle.Bottom; rowsPanel.Dock = DockStyle.Top;
            configPage.Controls.Add(rowsPanel); configPage.Controls.Add(journal);
            journal.Height = Font.Height * 6;
            Controls.Clear();
            var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 3 };
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, header.Height));
            layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            mainStatus.Dock = DockStyle.Fill; header.Dock = DockStyle.Fill;
            layout.Controls.Add(mainStatus, 0, 0); layout.Controls.Add(header, 0, 1); layout.Controls.Add(tabs, 0, 2);
            Controls.Add(layout);
            bottom.Dispose(); pastePanel.Dispose();
            mainStatus.SizeChanged += (s, e) => { foreach (var line in statusLines) line.MaximumSize = new Size(Math.Max(120, mainStatus.Width - 32), 0); happierCreated.MaximumSize = new Size(Math.Max(120, mainStatus.Width - 32), 0); };
            tabs.SelectedIndexChanged += (s, e) => {
                if (tabs.SelectedTab != serviceTab) HideHappierKey();
                if (tabs.SelectedTab == detailsTab) EnsureDetails();
                else if (detailsWindow != null && !detailsWindow.IsApplying) {
                    detailsWindow.CancelEmbedded(); detailsWindow.Dispose(); detailsWindow = null;
                }
            };
        }
        void BuildHappierAccount()
        {
            happierAccount.Controls.Add(happierCaption);
            var actions = new FlowLayoutPanel { AutoSize = true, WrapContents = true, MaximumSize = new Size(620, 0) };
            actions.Controls.Add(showHappierKey); actions.Controls.Add(copyHappierKey); actions.Controls.Add(openHappier);
            happierAccount.Controls.Add(actions); happierAccount.Controls.Add(happierKey);
            serviceActions.Controls.Add(happierAccount);
            showHappierKey.Click += (s, e) => {
                if (happierKey.Visible) { HideHappierKey(); return; }
                try {
                    string key = ReadHappierKey();
                    happierKey.Text = key; happierKey.Visible = true; showHappierKey.Text = "Скрыть ключ";
                } catch (Exception) { HappierActionFailed("Не удалось прочитать ключ Happier из хранилища."); }
            };
            // Click handlers run on the STA UI thread, including Clipboard.SetText.
            copyHappierKey.Click += (s, e) => {
                try { Clipboard.SetText(ReadHappierKey()); }
                catch (Exception) { HappierActionFailed("Не удалось скопировать ключ Happier. Повторите попытку."); }
            };
            openHappier.Click += (s, e) => {
                try {
                    RefreshHappierAccount();
                    string url = ConfigRequests.Origin(happierModel.WebUrl);
                    Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
                } catch (Exception) { HappierActionFailed("Не удалось открыть Happier. Проверьте HTTPS-адрес webappUrl в конфиге."); }
            };
            VisibleChanged += (s, e) => { if (!Visible) HideHappierKey(); else RefreshHappierAccount(); };
            serviceActions.SizeChanged += (s, e) => {
                int width = Math.Max(120, serviceActions.ClientSize.Width - 32);
                happierCaption.MaximumSize = actions.MaximumSize = new Size(width, 0);
                happierKey.Width = Math.Min(620, width);
            };
            RefreshHappierAccount();
        }
        void HideHappierKey()
        { happierKey.Clear(); happierKey.Visible = false; showHappierKey.Text = "Показать ключ"; }
        void RefreshHappierAccount()
        {
            HappierAccountModel current;
            try { current = HappierAccountModel.From(new Configuration(home).Data, name => SecretVault.Has(home, name)); }
            catch (Exception) { current = new HappierAccountModel(); }
            if (current.Label != happierModel.Label || current.SecretName != happierModel.SecretName || current.WebUrl != happierModel.WebUrl || !current.HasKey) HideHappierKey();
            happierModel = current;
            happierCaption.Text = "Аккаунт Happier: " + current.Label;
            happierAccount.Visible = current.Visible;
            showHappierKey.Visible = copyHappierKey.Visible = current.HasKey;
            openHappier.Enabled = current.WebUrl.Length > 0;
        }
        string ReadHappierKey()
        {
            RefreshHappierAccount();
            if (!happierModel.HasKey) throw new InvalidOperationException("Ключ Happier недоступен");
            string key = SecretVault.Get(home, happierModel.SecretName);
            if (string.IsNullOrEmpty(key)) throw new InvalidOperationException("Ключ Happier недоступен");
            return key;
        }
        void HappierActionFailed(string message)
        {
            HideHappierKey();
            // Fixed text only: vault/clipboard/process exceptions must never reach journals or the UI.
            MessageBox.Show(this, message, Product.Name, MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
        internal void ShowHappierAccountCreated(string message)
        {
            if (mainWindow) {
                HideHappierKey(); RefreshHappierAccount();
                happierCreated.Text = message; happierCreated.Visible = true;
                tabs.SelectedTab = serviceTab;
            } else MessageBox.Show(this, message + "\r\nКнопки аккаунта находятся в главном окне на вкладке «Сервис».", Product.Name, MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
        internal void ServiceActions(IEnumerable<KeyValuePair<string, Action>> actions, Action<string> choosePath)
        {
            var pathApply = new Button { Text = "Выбрать путь", AutoSize = true };
            pathApply.Click += (s, e) => { var item = pathChoice.SelectedItem as PathOption; if (item != null) choosePath(item.Tag); };
            serviceActions.Controls.Add(pathApply);
            foreach (var action in actions) {
                var a = action; var button = new Button { Text = a.Key, AutoSize = true, Padding = new Padding(6, 2, 6, 2) };
                button.Click += (s, e) => a.Value(); serviceActions.Controls.Add(button);
            }
            var expand = new CheckBox { Text = "Подробности", AutoSize = true };
            expand.CheckedChanged += (s, e) => technicalStatus.Visible = expand.Checked;
            serviceActions.Controls.Add(expand); serviceActions.Controls.Add(technicalStatus);
        }
        internal void UpdateMain(string[] lines, string sync, string technical, Dictionary<string, object> transport, Dictionary<string, object> health)
        {
            if (IsDisposed) return;
            RefreshHappierAccount();
            for (int i = 0; i < Math.Min(lines.Length, statusLines.Count); i++) if (statusLines[i].Text != lines[i]) statusLines[i].Text = lines[i];
            string operation = MutationConflict == null ? "" : MutationConflict();
            foreach (TabPage page in tabs.TabPages) page.Enabled = WindowModel.CanOpen(page.Text, operation);
            syncStatus.Text = sync; technicalStatus.Text = technical;
            serverHealthDetails.Text = ServerHealthView.Detail(health);
            var candidates = StatusView.Candidates(transport);
            pathStates.Text = "Связь: пути к серверу\r\n" + (candidates.Length == 0 ? "Ожидается проверка путей" : string.Join("\r\n", candidates.Select(c => TrayMenuModel.CandidateLine(c, transport))));
            string signature = Json.Encode(new { ok = Json.Bool(transport, "ok"), mode = Json.Str(transport, "mode"), active = Json.Str(transport, "active"), pinned = Json.Str(transport, "pinnedTag"), candidates = Json.Get(transport, "candidates") });
            if (signature == pathsSignature || pathChoice.DroppedDown) return;
            pathsSignature = signature;
            string selected = pathSelection.Update(transport);
            var paths = new List<PathOption> { new PathOption { Title = "Автовыбор", Tag = "" } };
            foreach (var c in StatusView.Candidates(transport).Where(c => Json.Bool(c, "enabled", true)))
                paths.Add(new PathOption { Tag = Json.Str(c, "tag"), Title = TrayMenuModel.CandidateLine(c, transport) });
            if (selected.Length > 0 && !paths.Any(p => p.Tag == selected)) paths.Add(new PathOption { Tag = selected, Title = selected + " — недоступен" });
            pathChoice.Items.Clear(); pathChoice.Items.AddRange(paths.Cast<object>().ToArray());
            pathChoice.SelectedIndex = Math.Max(0, paths.FindIndex(p => p.Tag == selected));
        }
        sealed class PathOption { internal string Tag, Title; public override string ToString() { return Title; } }
        void LayoutMain()
        {
            rowsPanel.Height = (int)((rows.Values.Count(r => r.Visible) * 24 + 12) * DeviceDpi / 96F);
            if (mainLaidOut) return; mainLaidOut = true;
            float scale = DeviceDpi / 96F; var area = Screen.FromControl(this).WorkingArea;
            MinimumSize = new Size(Math.Min((int)(540 * scale), area.Width - 24), Math.Min((int)(430 * scale), area.Height - 24));
            ClientSize = new Size(Math.Min((int)(740 * scale), area.Width - 40), Math.Min((int)(700 * scale), area.Height - 80));
            serviceActions.SizeChanged += (s, e) => {
                int width = Math.Max(150, serviceActions.ClientSize.Width - 32);
                syncStatus.MaximumSize = technicalStatus.MaximumSize = serverHealthDetails.MaximumSize = pathStates.MaximumSize = new Size(width, 0);
                pathChoice.Width = Math.Min((int)(430 * scale), width);
            };
        }
        void EnsureDetails()
        {
            if (detailsWindow != null && !detailsWindow.IsDisposed) return;
            detailsWindow = new SetupWizard(home, bundle, false, false);
            detailsWindow.SettingsApplied = () => {
                ConfigSession.SyncFromSettings(home);
                if (configText.Text == displayedConfigText) RefreshConfigText();
                else Log("Настройки обновлены в «Подробно». Ваши правки в редакторе конфига сохранены.");
            };
            detailsWindow.MutationConflict = () => running ? WindowModel.Conflict("применение настроек") : MutationConflict == null ? "" : MutationConflict();
            detailsWindow.TopLevel = false; detailsWindow.FormBorderStyle = FormBorderStyle.None;
            detailsWindow.PrepareEmbedded();
            detailsHost.Controls.Add(detailsWindow); detailsWindow.Show();
        }
        internal void OpenDetails(int section)
        { tabs.SelectedTab = detailsTab; EnsureDetails(); detailsWindow.OpenSection(section); }
        void ReportConflict(string message)
        {
            Log(message);
            // The config journal is on one tab only: report at the action as well.
            if (mainWindow && !IsDisposed) MessageBox.Show(this, message, Product.Name);
        }
        internal void Unload()
        {
            if (IsDisposed) return;
            allowUnload = true; cancel.Cancel();
            if (detailsWindow != null) detailsWindow.CancelEmbedded();
            // Disposal cancels the same ConfigSession and wizard actions; it never asks again.
            Dispose();
        }
    }
}
