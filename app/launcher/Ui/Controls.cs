using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace RemoteAgents.Launcher
{
    internal static class Theme
    {
        internal static readonly Color Window = Color.FromArgb(243, 243, 243);
        internal static readonly Color Card = Color.White;
        internal static readonly Color Border = Color.FromArgb(229, 229, 229);
        internal static readonly Color Text = Color.FromArgb(27, 27, 27);
        internal static readonly Color Muted = Color.FromArgb(96, 96, 96);
        internal static readonly Color Accent = Color.FromArgb(0, 103, 192);

        // Shared for the process lifetime: controls borrow these fonts, they do not dispose them.
        static readonly Font bodyFont = new Font("Segoe UI", 9F);
        static readonly Font titleFont = new Font("Segoe UI Semibold", 11F);
        static readonly Font bigFont = new Font("Segoe UI Semibold", 14F);
        internal static Font Body { get { return bodyFont; } }
        internal static Font Title { get { return titleFont; } }
        internal static Font Big { get { return bigFont; } }

        internal static int Px(Control c, int logical)
        { return (int)System.Math.Round(logical * (c == null ? 96 : c.DeviceDpi) / 96.0); }

        internal static Color Fill(Tone tone)
        {
            switch (tone) {
                case Tone.Ok: return Color.FromArgb(223, 246, 221);
                case Tone.Warning: return Color.FromArgb(255, 244, 206);
                case Tone.Error: return Color.FromArgb(253, 231, 233);
                default: return Color.FromArgb(235, 235, 235);
            }
        }

        internal static Color Ink(Tone tone)
        {
            switch (tone) {
                case Tone.Ok: return Color.FromArgb(15, 123, 15);
                case Tone.Warning: return Color.FromArgb(157, 93, 0);
                case Tone.Error: return Color.FromArgb(196, 43, 28);
                default: return Muted;
            }
        }

        internal static string Glyph(Tone tone)
        {
            switch (tone) {
                case Tone.Ok: return "✔";
                case Tone.Warning: return "⚠";
                case Tone.Error: return "✖";
                default: return "○";
            }
        }

        internal static GraphicsPath RoundedRectangle(RectangleF bounds, float radius)
        {
            var path = new GraphicsPath();
            float diameter = System.Math.Min(System.Math.Max(0, radius * 2), System.Math.Min(bounds.Width, bounds.Height));
            if (diameter <= 0) path.AddRectangle(bounds);
            else {
                path.AddArc(bounds.Left, bounds.Top, diameter, diameter, 180, 90);
                path.AddArc(bounds.Right - diameter, bounds.Top, diameter, diameter, 270, 90);
                path.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0, 90);
                path.AddArc(bounds.Left, bounds.Bottom - diameter, diameter, diameter, 90, 90);
                path.CloseFigure();
            }
            return path;
        }
    }
}
