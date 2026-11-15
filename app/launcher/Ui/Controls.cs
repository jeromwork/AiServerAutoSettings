using System;
using System.Drawing;
using System.Windows.Forms;

namespace RemoteAgents.Launcher
{
    // Contract stubs for the new main window controls; the bodies are filled in by the "controls" stream.
    internal static class Theme
    {
        internal static readonly Color Window = Color.FromArgb(243, 243, 243);
        internal static readonly Color Card = Color.White;
        internal static readonly Color Border = Color.FromArgb(229, 229, 229);
        internal static readonly Color Text = Color.FromArgb(27, 27, 27);
        internal static readonly Color Muted = Color.FromArgb(96, 96, 96);
        internal static readonly Color Accent = Color.FromArgb(0, 103, 192);
        internal static Font Body { get { return new Font("Segoe UI", 9F); } }
        internal static Font Title { get { return new Font("Segoe UI Semibold", 11F); } }
        internal static Font Big { get { return new Font("Segoe UI Semibold", 14F); } }
        internal static Color Fill(Tone tone) { return Card; }     // banner/badge background for a tone
        internal static Color Ink(Tone tone) { return Text; }      // foreground/glyph colour for a tone
        internal static string Glyph(Tone tone) { return ""; }     // ✔ / ⚠ / ✖ / ○
    }

    // Flat white card with rounded corners, 1px border and inner padding; AutoSize follows its content.
    internal class CardPanel : Panel
    {
        internal int Radius = 8;
        internal CardPanel() { BackColor = Theme.Card; Padding = new Padding(16, 12, 16, 12); }
    }

    // Large on/off switch. User clicks raise Toggled (the switch does not flip itself: the owner sets Checked from state).
    internal class ToggleSwitch : Control
    {
        bool isChecked, busy;
        internal event EventHandler Toggled = delegate { };
        internal bool Checked { get { return isChecked; } set { isChecked = value; Invalidate(); } }
        internal bool Busy { get { return busy; } set { busy = value; Invalidate(); } }   // shows progress, ignores clicks
        internal ToggleSwitch() { Size = new Size(56, 28); }
        protected void OnToggled() { Toggled(this, EventArgs.Empty); }
    }

    // One InfoBar-like strip: tone colour, glyph, text, one action button and «Подробнее».
    internal class InfoBar : Panel
    {
        internal event EventHandler ActionClicked = delegate { };
        internal event EventHandler DetailsClicked = delegate { };
        internal void ShowMessage(Tone tone, string text, string actionText) { Visible = true; }
        internal void HideMessage() { Visible = false; }
        protected void OnAction() { ActionClicked(this, EventArgs.Empty); }
        protected void OnDetails() { DetailsClicked(this, EventArgs.Empty); }
    }

    // Collapsible section: clickable header «▸ Title» / «▾ Title»; Body holds the content and is hidden when collapsed.
    internal class Expander : Panel
    {
        internal readonly Panel Body = new Panel();
        internal event EventHandler ExpandedChanged = delegate { };
        internal string Title { get; set; }
        internal bool Expanded { get { return Body.Visible; } set { Body.Visible = value; ExpandedChanged(this, EventArgs.Empty); } }
    }

    // Windows 11: dark/light title bar, rounded corners and Mica; silently nothing on Windows 10 and older.
    internal static class WindowChrome
    {
        internal static void Apply(Form form, bool dark = false, bool mica = true) { }
    }
}
