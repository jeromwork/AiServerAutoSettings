using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Windows.Forms;

namespace RemoteAgents.Launcher
{
    internal sealed partial class ConfigWindow
    {
        readonly Dictionary<string, Control> pages = new Dictionary<string, Control>();
        readonly Panel pageHost = new BufferedPanel { Dock = DockStyle.Fill };
        readonly MainWindowSizing mainSizing = new MainWindowSizing();
        Control pageHeader; Size resizeStart;
        readonly FlowLayoutPanel settingsBody = Stack(), aboutBody = Stack();
        readonly Label pageTitle = WrapLabel();
        readonly Button pageBack = new Button { Text = "← Назад", AutoSize = true }, settingsButton = new Button { Text = "⚙", AutoSize = true, AccessibleName = "Настройки" };
        // Одна кнопка на всех страницах: смена фазы не меняет ширину строки заголовка.
        readonly Button updateButton = new Button {
            Text = UpdateButtonModel.IdleButtonText, AutoSize = false, AutoEllipsis = true,
            Size = new Size(128, 30), MinimumSize = new Size(128, 30),
            AccessibleName = "Проверить обновления", Visible = false
        };
        Action updateCheck;
        readonly ToolTip updateTip = new ToolTip();
        // Подпись целиком приходит из модели; длинный текст обрезается внутри кнопки.
        internal void SetUpdateButton(bool enabled, string text, string detail = null)
        {
            if (IsDisposed) return;
            updateButton.Enabled = enabled;
            updateButton.Text = text;
            updateTip.SetToolTip(updateButton, string.IsNullOrEmpty(text) ? "Проверить обновления" : string.IsNullOrEmpty(detail) ? text : detail);
        }
        Expander advanced;
        Label aboutInfo;

        string AboutText()
        { return "Версия: " + Program.Version + "\r\nБандл: " + Path.GetFileName(bundle) + "\r\nПапка: " + home; }
        void BuildPages()
        {
            var top = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, ColumnCount = 3, Padding = new Padding(12, 8, 12, 8) };
            top.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize)); top.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); top.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            pageTitle.Font = Theme.Big; pageTitle.Anchor = AnchorStyles.Left; pageBack.Visible = false;
            top.Controls.Add(pageBack, 0, 0); top.Controls.Add(pageTitle, 1, 0); var corner = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = Padding.Empty };
            corner.Controls.Add(updateButton); corner.Controls.Add(settingsButton); top.Controls.Add(corner, 2, 0);
            updateTip.SetToolTip(updateButton, "Проверить обновления"); new ToolTip().SetToolTip(settingsButton, "Настройки");
            updateButton.Click += (s, e) => updateCheck?.Invoke();
            pageBack.Click += (s, e) => ShowPage(currentPage == "Настройки" ? "Главная" : "Настройки");
            settingsButton.Click += (s, e) => ShowPage("Настройки");
            pageHeader = top;
            Controls.Add(pageHost); Controls.Add(top);
            ResizeBegin += (s, e) => resizeStart = Size;
            ResizeEnd += (s, e) => { if (Size != resizeStart) mainSizing.UserResized(); };
            Resize += (s, e) => { if (WindowState == FormWindowState.Maximized) mainSizing.UserResized(); };
            DpiChanged += (s, e) => BeginInvoke(new Action(() => { if (!IsDisposed) SizeForPage(currentPage); }));
            RegisterFlowPage("Главная", homeBody); RegisterFlowPage("Настройки", settingsBody);
            var serverBody = Stack();
            var serverState = WrapLabel(); serverBody.Controls.Add(serverState);
            Action refreshServer = () => serverState.Text = DeploymentText();
            AddButton(serverBody, "Сверить состояние", async () => {
                await Guard(async () => { var check = new ConfigSession(home, Bundle); check.Log = Log; await check.Plan(cancel.Token); });
                refreshServer();
            });
            AddButton(serverBody, "Применить конфиг сервера", async () => { await RetrySection(ConfigSections.Server); refreshServer(); });
            RegisterFlowPage("Сервер", serverBody); refreshServer();
            FlowLayoutPanel serverLink; MakeCard(settingsBody, new Label { Text = "Сервер", AutoSize = true }, out serverLink);
            AddButton(serverLink, "Открыть", () => { refreshServer(); ShowPage("Сервер"); });
            AddSetting("Сеть и пути", "Сервер, связь, VPN и выход в интернет", 1);
            var lanBody = Stack(); var lanState = WrapLabel(); lanBody.Controls.Add(lanState);
            AddButton(lanBody, "Применить конфиг сервера", async () => { await RetrySection(ConfigSections.Server); lanState.Text = DeploymentText(); });
            AddButton(lanBody, "Профили локальных сетей", () => OpenDetails(6));
            RegisterFlowPage("Локальные сети", lanBody);
            FlowLayoutPanel lanLink; MakeCard(settingsBody, new Label { Text = "Локальные сети", AutoSize = true }, out lanLink);
            AddButton(lanLink, "Открыть", () => { lanState.Text = DeploymentText(); ShowPage("Локальные сети"); });
            {
                AddSetting("Диск", "Папки и синхронизация", 2);
                AddSetting("Happier", "Аккаунт и адрес приложения", 3);
                var helperBody = AddSetting("Помощник", "Управление компьютером", 4);
                settingsBridgeSwitch = new Button { AutoSize = true, Padding = new Padding(6, 3, 6, 3), AccessibleName = "Удалённое управление" };
                helperBody.Controls.Add(settingsBridgeSwitch);
                settingsBridgeSwitch.Click += (s, e) => { if (settingsBridgeSwitch.Enabled) DispatchMainAction(bridgeOn ? "bridge-off" : "bridge-on"); };
            }
            FlowLayoutPanel about;
            MakeCard(settingsBody, new Label { Text = "О программе", AutoSize = true }, out about);
            aboutInfo = WrapLabel(); aboutInfo.Text = AboutText(); about.Controls.Add(aboutInfo); about.Controls.Add(aboutBody);
            // Renaming the computer remains available beside the settings sections.
            header.AutoSize = true;
            var rename = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, WrapContents = true };
            rename.Controls.Add(new Label { Text = "Название компьютера", AutoSize = true });
            deviceName.Width = 220; rename.Controls.Add(deviceName); AddButton(rename, "Сменить", async () => await RenameDevice());
            header.Controls.Add(rename); about.Controls.Add(header);
            advanced = new Expander { Title = "Дополнительно", AutoSize = true, Margin = new Padding(0, 0, 0, 12) };
            var advancedLinks = Stack(); advancedLinks.Dock = DockStyle.Top;
            AddButton(advancedLinks, "Редактор конфига", () => ShowPage("Редактор конфига"));
            AddButton(advancedLinks, "Диагностика", OpenDiagnostics);
            advanced.Body.Controls.Add(advancedLinks); advanced.Body.AutoSize = true; advanced.Expanded = false; settingsBody.Controls.Add(advanced);

            var editor = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 3, ColumnCount = 1, Padding = new Padding(8) };
            editor.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            editor.RowStyles.Add(new RowStyle(SizeType.AutoSize)); editor.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); editor.RowStyles.Add(new RowStyle(SizeType.Absolute, Font.Height * 6));
            var rowsHost = new Panel { Dock = DockStyle.Fill, AutoScroll = true, AutoSize = true, MaximumSize = new Size(0, (int)(210 * DeviceDpi / 96F)) };
            rowsPanel.MinimumSize = new Size((int)(520 * DeviceDpi / 96F), 0);
            rowsHost.Controls.Add(rowsPanel); editor.Controls.Add(rowsHost, 0, 0);
            editor.Controls.Add(configPage, 0, 1); journal.Dock = DockStyle.Fill; editor.Controls.Add(journal, 0, 2);
            RegisterPage("Редактор конфига", editor);
            serviceActions.Controls.Add(syncStatus); serviceActions.Controls.Add(serverHealthDetails); serviceActions.Controls.Add(pathStates);
            var deployDiagnostic = WrapLabel(); deployDiagnostic.Text = DeploymentText(); serviceActions.Controls.Add(deployDiagnostic);
            AddButton(serviceActions, "Состояние развёртывания сервера", () => { deployDiagnostic.Text = DeploymentText(); ShowPage("Сервер"); });
            AddButton(serviceActions, "Скопировать журнал", CopyDiagnosticLog);
            serviceActions.Controls.Add(diagnosticPathLink);
            serviceActions.Controls.Add(vpnDnsDetails);
            diagnosticPathLink.LinkClicked += (s, e) => pathMenu.Show(diagnosticPathLink, new Point(0, diagnosticPathLink.Height));
            RegisterFlowPage("Диагностика", serviceActions);
            detailsHost = new Panel { Dock = DockStyle.Fill, AutoScroll = true }; RegisterPage("Раздел настроек", detailsHost);
            ShowPage("Главная");
        }
        FlowLayoutPanel AddSetting(string title, string description, int section)
        {
            FlowLayoutPanel body;
            MakeCard(settingsBody, new Label { Text = title, AutoSize = true }, out body);
            var detail = WrapLabel(); detail.Text = description; detail.ForeColor = Theme.Muted; body.Controls.Add(detail);
            AddButton(body, "Открыть", () => OpenDetails(section));
            return body;
        }
        void RegisterPage(string name, Control page)
        { pages.Add(name, page); page.Dock = DockStyle.Fill; pageHost.Controls.Add(page); page.Visible = false; }
        void RegisterFlowPage(string name, FlowLayoutPanel body)
        {
            var scroll = new BufferedPanel { Dock = DockStyle.Fill, AutoScroll = true, Padding = new Padding(12, 4, 12, 12) };
            body.Location = new Point(scroll.Padding.Left, scroll.Padding.Top); scroll.Controls.Add(body);
            // Each nested card/flow receives the viewport width, so long text wraps at every DPI.
            scroll.ClientSizeChanged += (s, e) => FitContent(body, Math.Max(100, scroll.ClientSize.Width - scroll.Padding.Horizontal - SystemInformation.VerticalScrollBarWidth));
            RegisterPage(name, scroll);
        }
        static void FitContent(Control parent, int width)
        {
            parent.SuspendLayout();
            parent.MinimumSize = new Size(width, 0); parent.MaximumSize = new Size(width, 0); parent.Width = width;
            foreach (Control child in parent.Controls) {
                int available = Math.Max(60, width - parent.Padding.Horizontal - child.Margin.Horizontal);
                if (child is Label || child is Button) child.MaximumSize = new Size(available, 0);
                else if (child is InfoBar) { child.MinimumSize = new Size(available, 0); child.MaximumSize = new Size(available, 0); child.Width = available; }
                else if (child is TextBox) child.Width = available;
                else if (child is Expander) {
                    child.MinimumSize = new Size(available, 0); child.MaximumSize = new Size(available, 0); child.Width = available;
                    FitContent(((Expander)child).Body, Math.Max(60, available - child.Padding.Horizontal));
                }
                else if (child is Panel) FitContent(child, available);
            }
            parent.ResumeLayout(true);
        }
        void FitPage(Control page)
        {
            var body = page.Controls.OfType<FlowLayoutPanel>().FirstOrDefault();
            if (body != null) FitContent(body, Math.Max(100, page.ClientSize.Width - page.Padding.Horizontal - SystemInformation.VerticalScrollBarWidth));
        }
        internal void ShowPage(string name)
        {
            string operation = MutationConflict == null ? "" : MutationConflict();
            if (!WindowModel.CanOpen(name, operation)) { ReportConflict(operation); return; }
            if (name != "Главная") HideHappierKey();
            currentPage = name;
            SuspendLayout();
            foreach (var page in pages) page.Value.Visible = page.Key == name;
            pages[name].BringToFront(); FitPage(pages[name]);
            pageTitle.Text = name == "Главная" ? Product.Name : name;
            pageBack.Visible = name != "Главная"; settingsButton.Visible = name == "Главная"; updateButton.Visible = updateCheck != null;
            ResumeLayout(true);
            SizeForPage(name);
            if (name != "Раздел настроек" && detailsWindow != null && !detailsWindow.IsApplying) {
                detailsWindow.CancelEmbedded(); detailsWindow.Dispose(); detailsWindow = null;
            }
        }
        void SizeForPage(string name)
        {
            if (!mainLaidOut || WindowState != FormWindowState.Normal) return;
            var area = Screen.FromControl(this).WorkingArea;
            MinimumSize = new Size(Math.Min(Theme.Px(this, 360), area.Width), Math.Min(Theme.Px(this, 440), area.Height));
            Size content = Size.Empty;
            if (name == "Раздел настроек")
                content = new Size(Theme.Px(this, 780) + SystemInformation.VerticalScrollBarWidth,
                    Theme.Px(this, 460) + pageHeader.Height);
            else if (name == "Редактор конфига")
                content = new Size(rowsPanel.MinimumSize.Width + pages[name].Padding.Horizontal + SystemInformation.VerticalScrollBarWidth,
                    Theme.Px(this, 460) + pageHeader.Height);
            var required = content.IsEmpty ? Size.Empty : SizeFromClientSize(content);
            Bounds = mainSizing.ForPage(Bounds, required, name == "Главная" || name == "Настройки", DeviceDpi, area);
        }
        string DeploymentText()
        {
            try {
                var result = Json.Read(Path.Combine(home, "state", "server-apply.json"));
                return DiagnosticReport.Clean(DiagnosticReport.FormatServerApply(Json.Encode(result), Program.Version, "см. журнал шага"), DiagnosticReport.KnownSecrets(home));
            } catch (Exception) { return "Состояние развёртывания ещё не получено. Нажмите «Сверить состояние»."; }
        }
        void OpenDiagnostics()
        { advanced.Expanded = true; ShowPage("Диагностика"); }
    }
}
