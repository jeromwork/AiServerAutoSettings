using System;
using System.Drawing;
using System.Windows.Forms;

namespace RemoteAgents.Launcher
{
    // Shared by the main window and preview; no update status label or flow layout.
    internal sealed class MainWindowHeader : TableLayoutPanel
    {
        sealed class SingleLineTitle : Label
        {
            protected override void OnPaint(PaintEventArgs e)
            {
                TextRenderer.DrawText(e.Graphics, Text, Font, ClientRectangle, ForeColor,
                    TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter |
                    TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
            }
        }

        readonly Label title = new SingleLineTitle {
            AutoSize = false, AutoEllipsis = true, UseMnemonic = false,
            Font = Theme.Big, Anchor = AnchorStyles.Left | AnchorStyles.Right, Margin = Padding.Empty
        };
        internal readonly Button BackButton = Button("← Назад", "Назад");
        internal readonly Button UpdateButton = Button(UpdateButtonModel.IdleButtonText, "Проверить обновления");
        internal readonly Button SettingsButton = Button("⚙", "Настройки");
        bool home = true;

        internal MainWindowHeader()
        {
            Dock = DockStyle.Top; AutoSize = true; AutoSizeMode = AutoSizeMode.GrowAndShrink;
            ColumnCount = 4; RowCount = 1; Margin = Padding.Empty;
            ColumnStyles.Add(new ColumnStyle(SizeType.Absolute));
            ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            ColumnStyles.Add(new ColumnStyle(SizeType.Absolute));
            ColumnStyles.Add(new ColumnStyle(SizeType.Absolute));
            RowStyles.Add(new RowStyle(SizeType.Absolute));
            Controls.Add(BackButton, 0, 0); Controls.Add(title, 1, 0);
            Controls.Add(UpdateButton, 2, 0); Controls.Add(SettingsButton, 3, 0);
            UpdateButton.Visible = false;
            DpiChangedAfterParent += (s, e) => ApplyMetrics();
            ShowPage(Product.Name, true);
        }

        static Button Button(string text, string accessibleName)
        {
            return new Button { Text = text, AccessibleName = accessibleName, AutoSize = false,
                AutoEllipsis = true, Anchor = AnchorStyles.Right, Margin = Padding.Empty };
        }

        internal void ShowPage(string text, bool isHome)
        {
            title.Text = text; home = isHome;
            BackButton.Visible = !home; SettingsButton.Visible = home;
            ApplyMetrics();
        }

        void ApplyMetrics()
        {
            SuspendLayout();
            int height = Theme.Px(this, MainWindowHeaderMetrics.ControlHeight);
            int gap = Theme.Px(this, MainWindowHeaderMetrics.Gap);
            Padding = new Padding(Theme.Px(this, MainWindowHeaderMetrics.HorizontalPadding), Theme.Px(this, 8),
                Theme.Px(this, MainWindowHeaderMetrics.HorizontalPadding), Theme.Px(this, 8));
            FixSize(UpdateButton, Theme.Px(this, MainWindowHeaderMetrics.UpdateWidth), height);
            FixSize(SettingsButton, Theme.Px(this, MainWindowHeaderMetrics.SettingsWidth), height);
            FixSize(BackButton, Theme.Px(this, MainWindowHeaderMetrics.BackWidth), height);
            // Account for the actual font too, so the product name cannot be squeezed at any DPI.
            int titleWidth = Math.Max(Theme.Px(this, MainWindowHeaderMetrics.TitleWidth),
                TextRenderer.MeasureText(Product.Name, title.Font, Size.Empty, TextFormatFlags.SingleLine).Width);
            title.MinimumSize = new Size(titleWidth, height); title.Height = height;
            ColumnStyles[0].Width = home ? 0 : BackButton.Width + gap;
            ColumnStyles[2].Width = UpdateButton.Width + gap;
            ColumnStyles[3].Width = home ? SettingsButton.Width + gap : 0;
            RowStyles[0].Height = height;
            MinimumSize = new Size(Padding.Horizontal + titleWidth + (int)ColumnStyles[0].Width +
                (int)ColumnStyles[2].Width + (int)ColumnStyles[3].Width, Padding.Vertical + height);
            ResumeLayout(true);
        }

        static void FixSize(Control control, int width, int height)
        {
            control.MinimumSize = control.MaximumSize = control.Size = new Size(width, height);
        }
    }
}
