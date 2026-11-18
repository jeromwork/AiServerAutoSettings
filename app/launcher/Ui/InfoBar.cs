using System;
using System.Drawing;
using System.Windows.Forms;

namespace RemoteAgents.Launcher
{
    internal class InfoBar : Panel
    {
        readonly Label glyph, message;
        readonly Button action;
        readonly LinkLabel details;
        bool hasAction, arranging;

        internal event EventHandler ActionClicked = delegate { };
        internal event EventHandler DetailsClicked = delegate { };

        internal InfoBar()
        {
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint |
                ControlStyles.ResizeRedraw, true);
            Font = Theme.Body;
            BackColor = Theme.Fill(Tone.Off);
            ForeColor = Theme.Text;
            Padding = new Padding(12);
            AutoSize = true;
            AutoSizeMode = AutoSizeMode.GrowAndShrink;
            glyph = new Label { AutoSize = true, UseMnemonic = false, Font = Theme.Title };
            message = new Label { AutoSize = false, UseMnemonic = false, Margin = Padding.Empty };
            action = new Button { AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
                UseVisualStyleBackColor = true, Padding = new Padding(8, 3, 8, 3), Visible = false };
            details = new LinkLabel { AutoSize = true, Text = "Подробнее", LinkColor = Theme.Accent,
                ActiveLinkColor = Theme.Accent, VisitedLinkColor = Theme.Accent, TabStop = true };
            action.Click += delegate { OnAction(); };
            details.LinkClicked += delegate { OnDetails(); };
            Controls.AddRange(new Control[] { glyph, message, action, details });
            action.TabIndex = 0;
            details.TabIndex = 1;
            Visible = false;
        }

        internal void ShowMessage(Tone tone, string text, string actionText)
        {
            if (BackColor == Theme.Fill(tone) && glyph.Text == Theme.Glyph(tone)
                && message.Text == (text ?? "") && action.Text == (actionText ?? "")) { Visible = true; return; }
            SuspendLayout();
            BackColor = Theme.Fill(tone);
            glyph.ForeColor = Theme.Ink(tone);
            glyph.Text = Theme.Glyph(tone);
            message.Text = text ?? "";
            AccessibleName = message.Text;
            hasAction = !string.IsNullOrWhiteSpace(actionText);
            action.Text = actionText ?? "";
            action.Visible = hasAction;
            Visible = true;
            ResumeLayout(true);
            PerformLayout();
        }

        internal void HideMessage() { Visible = false; }
        protected void OnAction() { ActionClicked(this, EventArgs.Empty); }
        protected void OnDetails() { DetailsClicked(this, EventArgs.Empty); }

        public override Size GetPreferredSize(Size proposedSize)
        {
            if (message == null) return base.GetPreferredSize(proposedSize);
            int width = proposedSize.Width;
            if (width <= 0 || width == int.MaxValue) width = Width > 0 ? Width : Theme.Px(this, 360);
            return new Size(width, Arrange(width, false));
        }

        protected override void OnLayout(LayoutEventArgs e)
        {
            if (message == null || arranging) return;
            arranging = true;
            try {
                base.OnLayout(e);
                int height = Arrange(ClientSize.Width, true);
                if (AutoSize && Height != height) Height = height;
            } finally { arranging = false; }
        }

        // Keep the action on the right when possible; at narrow widths move it below the message.
        // Width always constrains the Label, so long Russian messages grow vertically rather than clip.
        int Arrange(int width, bool apply)
        {
            int gap = Theme.Px(this, 8);
            int glyphWidth = Theme.Px(this, 24);
            int available = Math.Max(1, width - Padding.Horizontal);
            Size glyphSize = glyph.GetPreferredSize(Size.Empty);
            Size linkSize = details.GetPreferredSize(Size.Empty);
            Size actionSize = hasAction ? action.GetPreferredSize(Size.Empty) : Size.Empty;
            int rightWidth = Math.Max(linkSize.Width, actionSize.Width);
            bool stacked = available - glyphWidth - gap * 2 - rightWidth < Theme.Px(this, 120);
            int textWidth = Math.Max(1, available - glyphWidth - gap - (stacked ? 0 : rightWidth + gap));
            Size textSize = TextRenderer.MeasureText(message.Text.Length == 0 ? " " : message.Text,
                message.Font, new Size(textWidth, int.MaxValue),
                TextFormatFlags.WordBreak | TextFormatFlags.TextBoxControl | TextFormatFlags.NoPrefix);
            // The same height for GetPreferredSize (apply=false) and OnLayout (apply=true); a difference made every
            // parent layout shrink the bar and OnLayout grow it back — the visible jump below the banner.
            int textHeight = Math.Max(textSize.Height, message.GetPreferredSize(new Size(textWidth, 0)).Height);
            int rightHeight = linkSize.Height + (hasAction ? actionSize.Height + gap : 0);
            int mainHeight = Math.Max(glyphSize.Height, textHeight);
            int rightTop = Padding.Top;
            int height;
            if (stacked) {
                rightTop += mainHeight + gap;
                height = Padding.Vertical + mainHeight + gap + rightHeight;
            } else height = Padding.Vertical + Math.Max(mainHeight, rightHeight);

            if (apply) {
                glyph.Location = new Point(Padding.Left, Padding.Top);
                message.SetBounds(Padding.Left + glyphWidth + gap, Padding.Top, textWidth, textHeight);
                int rightX = Math.Max(Padding.Left, width - Padding.Right - rightWidth);
                if (hasAction) {
                    action.SetBounds(rightX, rightTop, Math.Min(actionSize.Width, available), actionSize.Height);
                    rightTop += actionSize.Height + gap;
                }
                details.Location = new Point(Math.Max(Padding.Left, width - Padding.Right - linkSize.Width), rightTop);
            }
            return height;
        }

        protected override void OnDpiChangedAfterParent(EventArgs e)
        { base.OnDpiChangedAfterParent(e); PerformLayout(); }
    }
}
