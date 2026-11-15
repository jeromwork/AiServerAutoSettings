using System;
using System.Drawing;
using System.Windows.Forms;

namespace RemoteAgents.Launcher
{
    internal class Expander : Panel
    {
        readonly Button header;
        string title = "";
        bool expanded;
        internal readonly Panel Body = new Panel();
        internal event EventHandler ExpandedChanged = delegate { };

        internal string Title
        {
            get { return title; }
            set { title = value ?? ""; UpdateHeader(); }
        }

        internal bool Expanded
        {
            get { return expanded; }
            set {
                if (expanded == value) return;
                expanded = value;
                Body.Visible = value;
                UpdateHeader();
                PerformLayout();
                ExpandedChanged(this, EventArgs.Empty);
            }
        }

        internal Expander()
        {
            DoubleBuffered = true;
            Font = Theme.Body;
            BackColor = Theme.Window;
            ForeColor = Theme.Text;
            AutoSize = true;
            AutoSizeMode = AutoSizeMode.GrowAndShrink;
            Body.Dock = DockStyle.Top;
            Body.AutoSize = true;
            Body.AutoSizeMode = AutoSizeMode.GrowAndShrink;
            Body.Padding = new Padding(12, 0, 0, 0);
            Body.Visible = false;
            header = new Button { Dock = DockStyle.Top, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
                TextAlign = ContentAlignment.MiddleLeft, FlatStyle = FlatStyle.Flat, Font = Theme.Title,
                Padding = new Padding(4, 8, 4, 8), UseMnemonic = false, TabStop = true };
            header.FlatAppearance.BorderSize = 0;
            header.FlatAppearance.MouseOverBackColor = Theme.Border;
            header.FlatAppearance.MouseDownBackColor = Color.FromArgb(215, 215, 215);
            header.Click += delegate { Expanded = !Expanded; };
            // Native Button provides Tab, Space, Enter and a focus cue.
            Controls.Add(Body);
            Controls.Add(header);
            UpdateHeader();
        }

        void UpdateHeader()
        {
            if (header == null) return;
            header.Text = (Expanded ? "▾ " : "▸ ") + title;
            header.AccessibleName = title;
            header.AccessibleDescription = Expanded ? "Развёрнуто. Свернуть раздел" : "Свёрнуто. Развернуть раздел";
        }
    }
}
