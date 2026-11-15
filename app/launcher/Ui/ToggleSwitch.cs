using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace RemoteAgents.Launcher
{
    internal class ToggleSwitch : Control
    {
        bool isChecked, busy, keyPressed;
        internal event EventHandler Toggled = delegate { };

        internal bool Checked
        {
            get { return isChecked; }
            set {
                if (isChecked == value) return;
                isChecked = value;
                Invalidate();
                AccessibilityNotifyClients(AccessibleEvents.StateChange, -1);
            }
        }

        internal bool Busy
        {
            get { return busy; }
            set {
                if (busy == value) return;
                busy = value;
                Cursor = busy || !Enabled ? Cursors.Default : Cursors.Hand;
                Invalidate();
                AccessibilityNotifyClients(AccessibleEvents.StateChange, -1);
            }
        }

        internal ToggleSwitch()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw |
                ControlStyles.SupportsTransparentBackColor | ControlStyles.Selectable, true);
            SetStyle(ControlStyles.StandardDoubleClick, false);
            BackColor = Color.Transparent;
            Font = Theme.Body;
            Size = new Size(50, 28);
            TabStop = true;
            Cursor = Cursors.Hand;
            AccessibleRole = AccessibleRole.CheckButton;
        }

        protected void OnToggled()
        {
            if (Enabled && !Busy) Toggled(this, EventArgs.Empty);
        }

        protected override void OnClick(EventArgs e)
        {
            if (!Enabled || Busy) return;
            base.OnClick(e);
            OnToggled();
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left && Enabled && !Busy) Focus();
            base.OnMouseDown(e);
        }

        protected override bool IsInputKey(Keys keyData)
        {
            Keys key = keyData & Keys.KeyCode;
            return key == Keys.Space || key == Keys.Enter || base.IsInputKey(keyData);
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            base.OnKeyDown(e);
            if (e.KeyCode != Keys.Space && e.KeyCode != Keys.Enter) return;
            e.Handled = true;
            e.SuppressKeyPress = true;
            if (keyPressed) return;
            keyPressed = true;
            OnClick(EventArgs.Empty);
        }

        protected override void OnKeyUp(KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Space || e.KeyCode == Keys.Enter) {
                keyPressed = false;
                e.Handled = true;
            }
            base.OnKeyUp(e);
        }

        protected override void OnGotFocus(EventArgs e) { base.OnGotFocus(e); Invalidate(); }
        protected override void OnLostFocus(EventArgs e) { keyPressed = false; base.OnLostFocus(e); Invalidate(); }
        protected override void OnEnabledChanged(EventArgs e)
        {
            base.OnEnabledChanged(e);
            Cursor = Busy || !Enabled ? Cursors.Default : Cursors.Hand;
            Invalidate();
        }
        protected override void OnTextChanged(EventArgs e)
        {
            base.OnTextChanged(e);
            AccessibleName = Text;
            AccessibilityNotifyClients(AccessibleEvents.NameChange, -1);
        }
        protected override void OnDpiChangedAfterParent(EventArgs e)
        { base.OnDpiChangedAfterParent(e); Invalidate(); }

        public override Size GetPreferredSize(Size proposedSize)
        { return new Size(Theme.Px(this, 50), Theme.Px(this, 28)); }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            float width = Math.Min(Theme.Px(this, 44), ClientSize.Width - Theme.Px(this, 6));
            float height = Math.Min(Theme.Px(this, 22), ClientSize.Height - Theme.Px(this, 6));
            if (width <= 0 || height <= 0) return;
            var track = new RectangleF((Width - width) / 2, (Height - height) / 2, width, height);
            Color background = Parent == null ? Theme.Window : Parent.BackColor;
            if (background.A != 255) background = Theme.Window;
            Color fill = !Enabled ? Theme.Border : Checked ? Theme.Accent : background;
            Color outline = !Enabled ? Theme.Border : Checked ? Theme.Accent : Theme.Muted;
            Color knob = !Enabled ? Color.FromArgb(160, 160, 160) : Checked ? Color.White : Theme.Muted;
            if (Busy) {
                fill = Blend(fill, background);
                outline = Blend(outline, background);
                knob = Blend(knob, background);
            }
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (var path = Theme.RoundedRectangle(track, height / 2))
            using (var brush = new SolidBrush(fill))
            using (var pen = new Pen(outline, Math.Max(1, Theme.Px(this, 1)))) {
                e.Graphics.FillPath(brush, path);
                e.Graphics.DrawPath(pen, path);
            }
            float inset = Theme.Px(this, 3);
            float diameter = Math.Max(1, height - inset * 2);
            float x = Checked ? track.Right - inset - diameter : track.Left + inset;
            using (var brush = new SolidBrush(knob))
                e.Graphics.FillEllipse(brush, x, track.Top + inset, diameter, diameter);
            if (Focused && ShowFocusCues)
                ControlPaint.DrawFocusRectangle(e.Graphics, Rectangle.Inflate(Rectangle.Round(track), Theme.Px(this, 2), Theme.Px(this, 2)), Theme.Text, background);
        }

        static Color Blend(Color color, Color background)
        { return Color.FromArgb((color.R + background.R) / 2, (color.G + background.G) / 2, (color.B + background.B) / 2); }

        protected override AccessibleObject CreateAccessibilityInstance()
        { return new SwitchAccessibleObject(this); }

        sealed class SwitchAccessibleObject : ControlAccessibleObject
        {
            readonly ToggleSwitch owner;
            internal SwitchAccessibleObject(ToggleSwitch owner) : base(owner) { this.owner = owner; }
            public override AccessibleRole Role { get { return AccessibleRole.CheckButton; } }
            public override AccessibleStates State {
                get {
                    var state = base.State;
                    if (owner.Checked) state |= AccessibleStates.Checked;
                    if (owner.Busy) state |= AccessibleStates.Busy | AccessibleStates.Unavailable;
                    return state;
                }
            }
            public override string DefaultAction { get { return "Переключить"; } }
            public override void DoDefaultAction() { owner.OnClick(EventArgs.Empty); }
        }
    }
}
