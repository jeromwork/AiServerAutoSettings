using System.Text;

namespace RemoteAgents.Launcher
{
    internal struct MainScreenRenderStep { internal bool Render, Layout; }

    // WinForms-free. The tray rebuilds the main screen once a second; controls are touched only when the picture
    // changes, and the page is re-fitted only when something appears or disappears. Covered by PortableTests.
    internal sealed class MainScreenRenderGate
    {
        string content, layout;

        internal void Reset() { content = null; layout = null; }

        internal MainScreenRenderStep Next(MainScreenView view, bool pathEnabled, string dnsDetail)
        {
            dnsDetail = dnsDetail ?? "";
            string l = LayoutKey(view, dnsDetail);
            string c = l + ContentKey(view, pathEnabled, dnsDetail);
            var step = new MainScreenRenderStep { Render = c != content, Layout = l != layout };
            content = c; layout = l;
            return step;
        }

        // What appears or disappears on the page (Label widths do not depend on text, only on the window width).
        static string LayoutKey(MainScreenView view, string dns)
        {
            var b = new StringBuilder();
            Add(b, view.Banner.Visible, view.Vpn.Visible, view.Vpn.Visible && dns.Length > 0,
                view.Lan.Visible, view.Disk.Visible, view.Disk.Detail.Length > 0,
                view.Happier.Visible, view.Happier.Detail.Length > 0, view.Helper.Visible, view.Helper.Detail.Length > 0);
            return b.ToString();
        }

        static string ContentKey(MainScreenView view, bool pathEnabled, string dns)
        {
            var b = new StringBuilder();
            Add(b, view.Banner.Tone, view.Banner.Text, view.Banner.ActionText, view.Banner.ActionId);
            var v = view.Vpn;
            Add(b, v.Title, v.State, v.Tone, v.Detail, v.On, v.SwitchEnabled, v.SwitchText, v.PathLink, pathEnabled, dns);
            foreach (var card in new[] { view.Lan, view.Disk, view.Happier, view.Helper })
                Add(b, card.Title, card.State, card.Tone, card.Detail, card.On, card.SwitchEnabled, card.SwitchText);
            return b.ToString();
        }

        // Length-prefixed parts: no separator can be confused with text.
        static void Add(StringBuilder b, params object[] parts)
        {
            foreach (var part in parts) {
                string text = part == null ? "" : part.ToString();
                b.Append(text.Length).Append(':').Append(text).Append(';');
            }
        }
    }
}
