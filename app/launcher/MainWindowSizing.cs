using System;
using System.Drawing;

namespace RemoteAgents.Launcher
{
    // Outer window bounds throughout: the non-client frame must fit the work area too.
    internal sealed class MainWindowSizing
    {
        Size? compactSize;
        Size automaticSize;
        int compactDpi, automaticDpi;

        internal void UserResized() { compactSize = null; }

        internal Rectangle ForPage(Rectangle current, Size required, bool compact, int dpi, Rectangle workArea)
        {
            // Also respect a resize made outside the native sizing loop (e.g. Windows Snap).
            // A DPI transition scales the HWND itself; that is not a user resize.
            if (compactSize.HasValue && dpi == automaticDpi && current.Size != automaticSize) UserResized();
            Size desired = current.Size;
            if (compact) {
                if (compactSize.HasValue) desired = Scale(compactSize.Value, dpi / (double)compactDpi);
                compactSize = null;
            } else {
                desired = new Size(Math.Max(current.Width, required.Width), Math.Max(current.Height, required.Height));
                var fitted = Constrain(new Rectangle(current.Location, desired), workArea);
                if (fitted.Size != current.Size && !compactSize.HasValue) { compactSize = current.Size; compactDpi = dpi; }
            }
            var result = Constrain(new Rectangle(current.Location, desired), workArea);
            automaticSize = result.Size; automaticDpi = dpi;
            return result;
        }

        static Size Scale(Size size, double scale)
        { return new Size((int)Math.Round(size.Width * scale), (int)Math.Round(size.Height * scale)); }

        internal static Rectangle Constrain(Rectangle bounds, Rectangle area)
        {
            int width = Math.Min(bounds.Width, area.Width), height = Math.Min(bounds.Height, area.Height);
            return new Rectangle(Math.Max(area.Left, Math.Min(bounds.Left, area.Right - width)),
                Math.Max(area.Top, Math.Min(bounds.Top, area.Bottom - height)), width, height);
        }
    }
}
