using System;
using System.Windows.Forms;

namespace RemoteAgents.Launcher
{
    internal sealed partial class ConfigWindow
    {
        Button rollbackPrevious;
        internal void SetPreviousRollback(TrayMenuEntry entry, Action rollback)
        {
            if (rollbackPrevious == null) {
                rollbackPrevious = new Button { AutoSize = true, Visible = false };
                rollbackPrevious.Click += (s, e) => rollback();
                serviceActions.Controls.Add(rollbackPrevious);
            }
            rollbackPrevious.Visible = entry != null;
            if (entry != null) { rollbackPrevious.Text = entry.Text; rollbackPrevious.Enabled = entry.Enabled; }
        }
    }
}
