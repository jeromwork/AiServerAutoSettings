using System;
using System.Drawing;
using System.Windows.Forms;

namespace RemoteAgents.Launcher
{
    internal sealed partial class ConfigWindow
    {
        readonly FlowLayoutPanel homeBody = Stack(), happierBody = Stack();
        readonly InfoBar mainBanner = new InfoBar();
        readonly Button vpnSwitch = new Button { AutoSize = true, Padding = new Padding(6, 3, 6, 3) };
        readonly Button bridgeSwitch = new Button { AutoSize = true, Padding = new Padding(6, 3, 6, 3) };
        bool vpnOn, bridgeOn;
        readonly Label vpnTitle = WrapLabel(), vpnState = WrapLabel(), vpnDetail = WrapLabel();
        readonly LinkLabel pathLink = new LinkLabel { AutoSize = true, UseMnemonic = false };
        readonly LinkLabel diagnosticPathLink = new LinkLabel { AutoSize = true, UseMnemonic = false };
        readonly Label vpnDnsDetails = WrapLabel();
        readonly Label diskTitle = WrapLabel(), diskState = WrapLabel(), diskDetail = WrapLabel();
        readonly Label happierTitle = WrapLabel(), happierState = WrapLabel(), happierDetail = WrapLabel();
        readonly Label helperTitle = WrapLabel(), helperState = WrapLabel(), helperDetail = WrapLabel();
        readonly Label lanTitle = WrapLabel(), lanState = WrapLabel(), lanDetail = WrapLabel();
        readonly LinkLabel lanDetails = new LinkLabel { Text = "Подробно", AutoSize = true };
        string lanDetailsText = "";
        CardPanel vpnCard, diskCard, happierCard, helperCard, lanCard;
        readonly MainScreenRenderGate renderGate = new MainScreenRenderGate();

        static Label WrapLabel()
        { return new Label { AutoSize = true, UseMnemonic = false, Margin = new Padding(0, 2, 0, 2) }; }
        static FlowLayoutPanel Stack()
        { return new BufferedFlowPanel { AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, FlowDirection = FlowDirection.TopDown, WrapContents = false, Margin = Padding.Empty }; }
        static Button AddButton(Control body, string text, Action action)
        {
            var button = new Button { Text = text, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Padding = new Padding(6, 3, 6, 3), Margin = new Padding(0, 4, 4, 0) };
            button.Click += (s, e) => action(); body.Controls.Add(button); return button;
        }
        CardPanel MakeCard(FlowLayoutPanel parent, Label title, out FlowLayoutPanel body)
        {
            var card = new CardPanel { AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Margin = new Padding(0, 0, 0, 10) };
            body = Stack(); body.Dock = DockStyle.Top; title.Font = Theme.Title; body.Controls.Add(title); card.Controls.Add(body); parent.Controls.Add(card);
            return card;
        }
        void BuildCards()
        {
            homeBody.Controls.Add(mainBanner); mainBanner.Margin = new Padding(0, 0, 0, 10); mainBanner.Visible = false;
            mainBanner.ActionClicked += (s, e) => DispatchMainAction(bannerAction);
            mainBanner.DetailsClicked += (s, e) => OpenDiagnostics();
            FlowLayoutPanel body;
            vpnCard = MakeCard(homeBody, vpnTitle, out body);
            var switchRow = new FlowLayoutPanel { AutoSize = true, WrapContents = true, Margin = Padding.Empty };
            switchRow.Controls.Add(vpnSwitch); body.Controls.Add(switchRow);
            vpnState.Font = Theme.Big; vpnDetail.ForeColor = Theme.Muted;
            body.Controls.Add(vpnState); body.Controls.Add(vpnDetail); body.Controls.Add(pathLink);
            vpnSwitch.AccessibleName = "VPN";
            vpnSwitch.Click += (s, e) => { if (vpnSwitch.Enabled && VpnRequested != null) VpnRequested(!vpnOn); };
            pathLink.LinkClicked += (s, e) => pathMenu.Show(pathLink, new Point(0, pathLink.Height));
            lanCard = MakeCard(homeBody, lanTitle, out body); body.Controls.Add(lanState); body.Controls.Add(lanDetail); lanDetail.ForeColor = Theme.Muted;
            body.Controls.Add(lanDetails);
            lanDetails.LinkClicked += (s, e) => MessageBox.Show(this, lanDetailsText, "Локальные сети", MessageBoxButtons.OK, MessageBoxIcon.Information);
            diskCard = MakeCard(homeBody, diskTitle, out body); body.Controls.Add(diskState); body.Controls.Add(diskDetail);
            diskDetail.ForeColor = Theme.Muted; AddButton(body, "Открыть Диск", () => DispatchMainAction("open-disk"));
            happierCard = MakeCard(homeBody, happierTitle, out body); body.Controls.Add(happierState); body.Controls.Add(happierDetail);
            happierDetail.ForeColor = Theme.Muted; body.Controls.Add(happierCreated); body.Controls.Add(happierBody);
            helperCard = MakeCard(homeBody, helperTitle, out body);
            body.Controls.Add(bridgeSwitch); body.Controls.Add(helperState); body.Controls.Add(helperDetail); helperDetail.ForeColor = Theme.Muted;
            bridgeSwitch.AccessibleName = "Удалённое управление";
            bridgeSwitch.Click += (s, e) => { if (bridgeSwitch.Enabled) DispatchMainAction(bridgeOn ? "bridge-off" : "bridge-on"); };
        }
        void DispatchMainAction(string action)
        {
            if (action == "details") { OpenDiagnostics(); return; }
            if (action == "vpn-on") { if (VpnRequested != null) VpnRequested(true); return; }
            if (MainAction != null) MainAction(action);
        }
        void RenderCards(MainScreenView view, MainScreenFacts facts)
        {
            string dns = MainScreenModel.CleanSecrets(VpnStatus.DnsDetail(facts.Vpn ?? Json.Map(null)));
            bool pathEnabled = string.IsNullOrEmpty(facts.Operation);
            var step = renderGate.Next(view, pathEnabled, dns);
            // TrayContext.Tick calls this every second: the same picture must not touch controls or the layout.
            if (!step.Render) return;
            homeBody.SuspendLayout();
            try {
                bannerAction = view.Banner.ActionId;
                if (view.Banner.Visible) mainBanner.ShowMessage(view.Banner.Tone, view.Banner.Text, view.Banner.ActionText);
                else mainBanner.HideMessage();
                vpnCard.Visible = view.Vpn.Visible; SetText(vpnTitle, view.Vpn.Title);
                SetText(vpnState, view.Vpn.State); vpnState.ForeColor = Theme.Ink(view.Vpn.Tone); SetText(vpnDetail, view.Vpn.Detail);
                vpnOn = view.Vpn.On; vpnSwitch.Enabled = view.Vpn.SwitchEnabled;
                SetText(vpnSwitch, view.Vpn.SwitchText); vpnSwitch.AccessibleDescription = view.Vpn.SwitchText;
                SetText(pathLink, view.Vpn.PathLink); SetText(diagnosticPathLink, view.Vpn.PathLink);
                pathLink.Enabled = diagnosticPathLink.Enabled = pathEnabled;
                SetText(vpnDnsDetails, dns);
                vpnDnsDetails.Visible = view.Vpn.Visible && dns.Length > 0;
                // LAN details open in a message box («Подробно»); the label itself stays hidden (no on/off flip per tick).
                RenderCard(view.Lan, lanCard, lanTitle, lanState, lanDetail, false);
                lanDetailsText = view.Lan.Detail;
                RenderCard(view.Disk, diskCard, diskTitle, diskState, diskDetail);
                RenderCard(view.Happier, happierCard, happierTitle, happierState, happierDetail);
                RenderCard(view.Helper, helperCard, helperTitle, helperState, helperDetail);
                bridgeOn = view.Helper.On; bridgeSwitch.Enabled = view.Helper.SwitchEnabled;
                SetText(bridgeSwitch, view.Helper.SwitchText); bridgeSwitch.AccessibleDescription = view.Helper.SwitchText;
            } finally { homeBody.ResumeLayout(true); }
            if (step.Layout) FitPage(pages["Главная"]);
        }
        static void RenderCard(CardView view, CardPanel card, Label title, Label state, Label detail, bool showDetail = true)
        {
            card.Visible = view.Visible; SetText(title, view.Title); SetText(state, view.State); state.ForeColor = Theme.Ink(view.Tone); SetText(detail, view.Detail);
            detail.Visible = showDetail && view.Detail.Length > 0;
        }
        // Text only: Visible/Enabled getters also reflect the parent (hidden window), so they are assigned directly —
        // WinForms itself ignores an unchanged Visible/Enabled/ForeColor.
        static void SetText(Control control, string value)
        {
            value = value ?? "";
            if (control.Text != value) control.Text = value;
        }
    }
}
