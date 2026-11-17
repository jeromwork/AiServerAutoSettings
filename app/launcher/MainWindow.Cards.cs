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
        bool vpnOn;
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

        static Label WrapLabel()
        { return new Label { AutoSize = true, UseMnemonic = false, Margin = new Padding(0, 2, 0, 2) }; }
        static FlowLayoutPanel Stack()
        { return new FlowLayoutPanel { AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, FlowDirection = FlowDirection.TopDown, WrapContents = false, Margin = Padding.Empty }; }
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
            helperCard = MakeCard(homeBody, helperTitle, out body); body.Controls.Add(helperState); body.Controls.Add(helperDetail); helperDetail.ForeColor = Theme.Muted;
        }
        void DispatchMainAction(string action)
        {
            if (action == "details") { OpenDiagnostics(); return; }
            if (action == "vpn-on") { if (VpnRequested != null) VpnRequested(true); return; }
            if (MainAction != null) MainAction(action);
        }
        void RenderCards(MainScreenView view, MainScreenFacts facts)
        {
            bannerAction = view.Banner.ActionId;
            if (view.Banner.Visible) mainBanner.ShowMessage(view.Banner.Tone, view.Banner.Text, view.Banner.ActionText);
            else mainBanner.HideMessage();
            vpnCard.Visible = view.Vpn.Visible; vpnTitle.Text = view.Vpn.Title;
            vpnState.Text = view.Vpn.State; vpnState.ForeColor = Theme.Ink(view.Vpn.Tone); vpnDetail.Text = view.Vpn.Detail;
            vpnOn = view.Vpn.On; vpnSwitch.Enabled = view.Vpn.SwitchEnabled;
            vpnSwitch.Text = view.Vpn.SwitchText; vpnSwitch.AccessibleDescription = view.Vpn.SwitchText;
            pathLink.Text = diagnosticPathLink.Text = view.Vpn.PathLink;
            pathLink.Enabled = diagnosticPathLink.Enabled = string.IsNullOrEmpty(facts.Operation);
            vpnDnsDetails.Text = MainScreenModel.CleanSecrets(VpnStatus.DnsDetail(facts.Vpn ?? Json.Map(null)));
            vpnDnsDetails.Visible = view.Vpn.Visible && vpnDnsDetails.Text.Length > 0;
            RenderCard(view.Lan, lanCard, lanTitle, lanState, lanDetail);
            lanDetailsText = view.Lan.Detail; lanDetail.Visible = false;
            RenderCard(view.Disk, diskCard, diskTitle, diskState, diskDetail);
            RenderCard(view.Happier, happierCard, happierTitle, happierState, happierDetail);
            RenderCard(view.Helper, helperCard, helperTitle, helperState, helperDetail);
            FitPage(pages["Главная"]);
        }
        static void RenderCard(CardView view, CardPanel card, Label title, Label state, Label detail)
        {
            card.Visible = view.Visible; title.Text = view.Title; state.Text = view.State; state.ForeColor = Theme.Ink(view.Tone); detail.Text = view.Detail;
            detail.Visible = view.Detail.Length > 0;
        }
    }
}
