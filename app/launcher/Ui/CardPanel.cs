using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace RemoteAgents.Launcher
{
    // Paint corners instead of setting Region: child HWNDs retain their rectangular layout at every DPI.
    internal class CardPanel : Panel
    {
        internal int Radius = 8;

        internal CardPanel()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            DoubleBuffered = true;
            BackColor = Theme.Card;
            ForeColor = Theme.Text;
            Font = Theme.Body;
            Padding = new Padding(16, 12, 16, 12);
            AutoSize = true;
            AutoSizeMode = AutoSizeMode.GrowAndShrink;
        }

        protected override void OnPaintBackground(PaintEventArgs e)
        {
            e.Graphics.Clear(Parent == null ? Theme.Window : Parent.BackColor);
            if (ClientSize.Width < 2 || ClientSize.Height < 2) return;
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (var path = Theme.RoundedRectangle(new RectangleF(0.5F, 0.5F, Width - 1F, Height - 1F), Theme.Px(this, Radius)))
            using (var brush = new SolidBrush(BackColor)) e.Graphics.FillPath(brush, path);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            if (ClientSize.Width < 2 || ClientSize.Height < 2) return;
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (var path = Theme.RoundedRectangle(new RectangleF(0.5F, 0.5F, Width - 1F, Height - 1F), Theme.Px(this, Radius)))
            using (var pen = new Pen(Theme.Border)) e.Graphics.DrawPath(pen, path);
        }
    }
}
