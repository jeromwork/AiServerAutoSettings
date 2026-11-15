using System;
using System.Collections.Generic;
using System.Drawing;
using System.Diagnostics;
using System.Linq;
using System.Windows.Forms;

namespace RemoteAgents.Launcher
{
    internal sealed partial class ConfigWindow
    {
        bool allowUnload, mainLaidOut;
        internal Action HiddenToTray;
        internal Func<string> MutationConflict;
        internal Action<bool> VpnRequested;
        internal Action<string> MainAction;
        internal bool IsApplying { get { return running || detailsWindow != null && detailsWindow.IsApplying; } }
        readonly Label syncStatus = WrapLabel(), technicalStatus = WrapLabel(), serverHealthDetails = WrapLabel(), pathStates = WrapLabel();
        readonly FlowLayoutPanel serviceActions = Stack();
        Panel detailsHost; SetupWizard detailsWindow;
        readonly FlowLayoutPanel happierAccount = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.TopDown, WrapContents = false, Visible = false };
        readonly TextBox happierKey = new TextBox { ReadOnly = true, Visible = false, Width = 280 };
        readonly Button showHappierKey = new Button { Text = "Показать ключ", AutoSize = true };
        readonly Button copyHappierKey = new Button { Text = "Копировать ключ", AutoSize = true };
        readonly Button openHappier = new Button { Text = "Открыть Happier", AutoSize = true };
        readonly Label happierCreated = new Label { AutoSize = true, UseMnemonic = false, Visible = false, Padding = new Padding(8), BackColor = Color.LightGoldenrodYellow };
        HappierAccountModel happierModel = new HappierAccountModel();
        MainScreenFacts screenFacts; string screenTechnical = "", bannerAction = "", currentPage = "Главная";
        readonly ContextMenuStrip pathMenu = new ContextMenuStrip();
        readonly PathSelection pathSelection = new PathSelection();
        Action<string> choosePath;
        internal static ConfigWindow Main(string home, string bundle)
        { return new ConfigWindow(home, bundle, null, true, true); }
        internal void RebindBundle(string current)
        {
            bundle = current;
            if (session != null) session.RebindBundle(current);
            if (followingSession != null && followingSession != session) followingSession.RebindBundle(current);
            if (detailsWindow != null && !detailsWindow.IsDisposed) detailsWindow.RebindBundle(current);
            if (aboutInfo != null) aboutInfo.Text = AboutText();
        }
        void BuildMain()
        {
            Text = Product.Name; BackColor = Theme.Window; ForeColor = Theme.Text;
            Controls.Clear();
            BuildCards(); BuildPages(); BuildHappierAccount(); FitPage(pages["Главная"]);
            windowLayout.Dispose(); bottom.Dispose(); pastePanel.Dispose();
            VisibleChanged += (s, e) => { if (Visible) WindowChrome.Apply(this); };
        }
        void BuildHappierAccount()
        {
            var actions = new FlowLayoutPanel { AutoSize = true, WrapContents = true, MaximumSize = new Size(620, 0) };
            actions.Controls.Add(openHappier); actions.Controls.Add(showHappierKey); actions.Controls.Add(copyHappierKey);
            happierAccount.Controls.Add(actions); happierAccount.Controls.Add(happierKey);
            happierBody.Controls.Add(happierAccount);
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
            happierBody.SizeChanged += (s, e) => {
                int width = Math.Max(120, happierBody.ClientSize.Width - 32);
                actions.MaximumSize = new Size(width, 0);
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
                ShowPage("Главная");
            } else MessageBox.Show(this, message + "\r\nКнопки аккаунта находятся в главном окне на карточке «Happier».", Product.Name, MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
        internal void ServiceActions(IEnumerable<KeyValuePair<string, Action>> actions, Action<string> selectPath)
        {
            choosePath = selectPath;
            foreach (var action in actions) {
                var a = action;
                AddButton(serviceActions, a.Key, a.Value);
                if (a.Key == "Журналы" || a.Key == "Перезапустить компоненты" || a.Key == "Проверить обновления на сервере")
                    AddButton(aboutBody, a.Key == "Проверить обновления на сервере" ? "Проверить обновления" : a.Key, a.Value);
            }
            serviceActions.Controls.Add(technicalStatus);
            AddButton(serviceActions, "Скопировать отчёт", () => {
                if (screenFacts == null) return;
                try { Clipboard.SetText(MainScreenModel.Report(screenFacts, screenTechnical)); }
                catch (Exception) { MessageBox.Show(this, "Не удалось скопировать отчёт. Повторите попытку.", Product.Name); }
            });
            FitPage(pages["Настройки"]); FitPage(pages["Диагностика"]);
        }
        internal void UpdateActivity(string text) { syncStatus.Text = text; }
        internal void UpdateMain(MainScreenFacts facts, string technical, Dictionary<string, object> transport, Dictionary<string, object> health)
        {
            if (IsDisposed) return;
            screenFacts = facts; screenTechnical = technical;
            RefreshHappierAccount();
            var view = MainScreenModel.Build(facts);
            RenderCards(view, facts);
            apply.Enabled = !running && string.IsNullOrEmpty(facts.Operation);
            technicalStatus.Text = technical;
            serverHealthDetails.Text = ServerHealthView.Detail(health);
            var candidates = StatusView.Candidates(transport);
            pathStates.Text = "Связь: пути к серверу\r\n" + (candidates.Length == 0 ? "Ожидается проверка путей" : string.Join("\r\n", candidates.Select(c => TrayMenuModel.CandidateLine(c, transport))));
            // Do not replace a menu underneath a pointer; its commands retain the same PathSelection policy.
            if (pathMenu.Visible) return;
            string selected = pathSelection.Update(transport);
            foreach (ToolStripItem item in pathMenu.Items.Cast<ToolStripItem>().ToArray()) item.Dispose();
            pathMenu.Items.Clear();
            AddPath("Автовыбор", "", selected);
            foreach (var candidate in candidates.Where(c => Json.Bool(c, "enabled", true)))
                AddPath(TrayMenuModel.CandidateLine(candidate, transport), Json.Str(candidate, "tag"), selected);
            if (selected.Length > 0 && !candidates.Any(c => Json.Bool(c, "enabled", true) && Json.Str(c, "tag") == selected)) AddPath(selected + " — недоступен", selected, selected);
        }
        void AddPath(string title, string tag, string selected)
        {
            var item = new ToolStripMenuItem(title) { Checked = tag == selected };
            item.Click += (s, e) => { pathSelection.Choose(tag); if (choosePath != null) choosePath(tag); };
            pathMenu.Items.Add(item);
        }
        void LayoutMain()
        {
            rowsPanel.Height = (int)((rows.Values.Count(r => r.Visible) * 24 + 12) * DeviceDpi / 96F);
            if (mainLaidOut) return; mainLaidOut = true;
            float scale = DeviceDpi / 96F; var area = Screen.FromControl(this).WorkingArea;
            MinimumSize = new Size(Math.Min((int)(360 * scale), area.Width - 24), Math.Min((int)(440 * scale), area.Height - 24));
            ClientSize = new Size(Math.Min((int)(420 * scale), area.Width - 40), Math.Min((int)(600 * scale), area.Height - 80));
        }
        void EnsureDetails()
        {
            if (detailsWindow != null && !detailsWindow.IsDisposed) return;
            detailsWindow = new SetupWizard(home, bundle, false, false);
            detailsWindow.SettingsApplied = () => {
                ConfigSession.SyncFromSettings(home);
                if (configText.Text == displayedConfigText) RefreshConfigText();
                else Log("Настройки обновлены. Ваши правки в редакторе конфига сохранены.");
            };
            detailsWindow.MutationConflict = () => running ? WindowModel.Conflict("применение настроек") : MutationConflict == null ? "" : MutationConflict();
            detailsWindow.TopLevel = false; detailsWindow.FormBorderStyle = FormBorderStyle.None;
            detailsWindow.PrepareEmbedded();
            detailsHost.Controls.Add(detailsWindow); detailsWindow.Show();
        }
        internal void OpenDetails(int section)
        { ShowPage("Раздел настроек"); EnsureDetails(); detailsWindow.OpenSection(section); }
        void ReportConflict(string message)
        {
            Log(message);
            if (mainWindow && !IsDisposed) MessageBox.Show(this, message, Product.Name);
        }
        internal void Unload()
        {
            if (IsDisposed) return;
            allowUnload = true; cancel.Cancel();
            if (detailsWindow != null) detailsWindow.CancelEmbedded();
            Dispose();
        }
    }
}
