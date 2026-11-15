using System;
using System.Collections.Generic;

namespace RemoteAgents.Launcher
{
    // Same colour language as the tray icon: grey = off, green = ok, yellow = partial, red = no connection.
    internal enum Tone { Off, Ok, Warning, Error }

    // Raw facts for the main screen, gathered by the tray from the same fresh status/*.json files as the menu and tooltip.
    // No WinForms here: the model is covered by PortableTests.
    internal sealed class MainScreenFacts
    {
        internal bool IsVpnProduct;                                                        // Product.IsVpn (RemoteVPN build)
        internal Dictionary<string, object> Transport = new Dictionary<string, object>();  // status/transport.json (maxAge 15 s)
        internal Dictionary<string, object> Vpn = new Dictionary<string, object>();        // status/vpn.json (maxAge 15 s)
        internal Dictionary<string, object> Control = new Dictionary<string, object>();    // status/control.json (maxAge 30 s), the bridge
        internal Dictionary<string, object> Health = new Dictionary<string, object>();     // ServerHealthView.Read(home)
        internal bool VpnInstalled;          // a "vpn" component exists in the definition
        internal bool VpnWanted;             // profile.vpn.enabled / the user's intent
        internal bool VpnBusy;               // enable/disable is in progress (actionBusy around CheckVpn/DisableVpn)
        internal string VpnError = "";       // last enable/disable failure in plain words, "" when none
        internal bool DiskEnabled;           // the "disk" component is enabled
        internal string DiskSummary = "";    // TrayContext disk summary, e.g. "Диск: синхронизирован" (DiskTraySession.Summary texts)
        internal int DiskFolders = -1;       // number of server folders, -1 = unknown
        internal int DiskServerOnly = -1;    // folders kept only on the server, -1 = unknown
        internal bool HappierVisible;        // HappierAccountModel.Visible
        internal bool HappierHasKey;         // HappierAccountModel.HasKey
        internal string HappierLabel = "";   // HappierAccountModel.Label
        internal bool HappierConfirmed;      // state/happier-account.json ok
        internal string HappierUrl = "";     // usable web address, "" when not configured
        internal string Operation = "";      // MutationConflict() text, "" when idle
    }

    internal sealed class CardView
    {
        internal string Title = "", State = "", Detail = "";
        internal Tone Tone;
        internal bool Visible = true;
    }

    internal sealed class VpnCardView
    {
        internal string Title = "VPN", State = "", Detail = "";
        internal Tone Tone;
        internal bool Visible = true;
        internal bool On;                    // switch position
        internal bool SwitchEnabled = true;  // false while busy or another operation runs
        internal string SwitchText = "";     // "Вкл" / "Выкл" / "Включается…" / "Выключается…"
        internal string PathLink = "Авто ▾"; // the path chooser link text ("Авто ▾" or the pinned path title + " ▾")
    }

    internal sealed class BannerView
    {
        internal bool Visible;
        internal Tone Tone;
        internal string Text = "";           // plain words, no technical terms
        internal string ActionText = "";     // one button, "" when none
        internal string ActionId = "";       // "retry" | "vpn-on" | "open-disk" | "open-sync" | "details" | ""
    }

    internal sealed class MainScreenView
    {
        internal Tone Overall;               // must match the tray icon colour for the same facts
        internal BannerView Banner = new BannerView();
        internal VpnCardView Vpn = new VpnCardView();
        internal CardView Disk = new CardView { Title = "Диск" };
        internal CardView Happier = new CardView { Title = "Happier" };
        internal CardView Helper = new CardView { Title = "Помощник" };
    }

    internal static class MainScreenModel
    {
        internal static MainScreenView Build(MainScreenFacts facts)
        { throw new NotImplementedException(); }

        // Plain-text diagnostics for «Скопировать отчёт»: statuses, paths, versions — never keys, passwords or tokens.
        internal static string Report(MainScreenFacts facts, string technical)
        { throw new NotImplementedException(); }
    }
}
