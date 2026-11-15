using System;
using System.Drawing;

namespace RemoteAgents.Launcher
{
    internal static class MainWindowSizingTests
    {
        static int count;
        static void Check(bool condition, string name)
        { if (!condition) throw new Exception("Main window sizing: " + name); count++; }

        internal static void Run()
        {
            foreach (int dpi in new[] { 96, 144, 192 }) {
                int scale = dpi / 48;
                var area = new Rectangle(-1920, 30, 1920, 1200);
                var compact = new Rectangle(-800, 100, 210 * scale, 300 * scale);
                var wizard = new Size(390 * scale + 34, 230 * scale + 90);
                var model = new MainWindowSizing();
                var wide = model.ForPage(compact, wizard, false, dpi, area);
                Check(wide.Width >= wizard.Width && wide.Height >= wizard.Height, "DPI-scaled canvas and frame fit at " + dpi);
                Check(area.Contains(wide), "including negative monitor origin and taskbar at " + dpi);
                // Navigation between wide pages must retain the original compact size.
                wide = model.ForPage(wide, new Size(260 * scale + 34, 400), false, dpi, area);
                Check(model.ForPage(wide, Size.Empty, true, dpi, area).Size == compact.Size, "compact size restored at " + dpi);
                var smallArea = new Rectangle(0, 0, 800, 600);
                model = new MainWindowSizing();
                wide = model.ForPage(new Rectangle(700, 500, 420, 500), wizard, false, dpi, smallArea);
                Check(smallArea.Contains(wide), "limited working area contains entire window at " + dpi);
            }
            var desktop = new Rectangle(0, 0, 2400, 1600);
            var original = new Rectangle(100, 100, 436, 639);
            var required = new Size(820, 620);
            var sizing = new MainWindowSizing();
            var expanded = sizing.ForPage(original, required, false, 96, desktop);
            var moved = new Rectangle(new Point(200, 150), expanded.Size);
            Check(sizing.ForPage(moved, Size.Empty, true, 96, desktop).Size == original.Size, "moving the window preserves restoration");
            expanded = sizing.ForPage(original, required, false, 96, desktop);
            var manual = new Rectangle(expanded.Location, new Size(900, 700));
            Check(sizing.ForPage(manual, Size.Empty, true, 96, desktop) == manual, "Snap or external resize preserves the user's size");
            expanded = sizing.ForPage(original, required, false, 96, desktop);
            sizing.UserResized();
            Check(sizing.ForPage(expanded, Size.Empty, true, 96, desktop) == expanded, "explicit resize cancels restoration even at the same final size");
            expanded = sizing.ForPage(original, required, false, 96, desktop);
            var scaled = new Rectangle(100, 100, expanded.Width * 2, expanded.Height * 2);
            Check(sizing.ForPage(scaled, Size.Empty, true, 192, desktop).Size == new Size(original.Width * 2, original.Height * 2), "DPI change scales the remembered compact size");
            var alreadyWide = new Rectangle(20, 20, 1000, 800);
            expanded = sizing.ForPage(alreadyWide, required, false, 96, desktop);
            Check(expanded == alreadyWide && sizing.ForPage(expanded, Size.Empty, true, 96, desktop) == alreadyWide, "sufficient user size stays unchanged");
            Console.WriteLine("PASS: " + count + " main window sizing checks");
        }
    }
}
