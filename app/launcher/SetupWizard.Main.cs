using System;
using System.Drawing;
namespace RemoteAgents.Launcher
{
    internal sealed partial class SetupWizard
    {
        internal Func<string> MutationConflict;
        internal Action SettingsApplied;
        internal bool IsApplying { get { return busy; } }
        internal void RebindBundle(string current) { bundle = current; }
        internal void OpenSection(int section) { if (!busy) SelectPage(section); }
        internal void PrepareEmbedded()
        {
            close.Visible = false;
            // Existing pages use a 780 px canvas. The host scrolls it on small screens/high DPI.
            AutoScroll = true; MinimumSize = Size; Location = Point.Empty;
        }
        internal void CancelEmbedded() { if (IsDisposed || resourcesDisposed) return; closingRequested = true; operationTimer.Stop(); pollCancellation.Cancel(); if (stepCancellation != null) stepCancellation.Cancel(); }
    }
}
