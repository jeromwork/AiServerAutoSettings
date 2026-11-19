using System.Windows.Forms;

namespace RemoteAgents.Launcher
{
    // Double-buffered containers: a page/stack relayout repaints its background off-screen (no flash).
    internal class BufferedFlowPanel : FlowLayoutPanel
    { internal BufferedFlowPanel() { DoubleBuffered = true; } }

    internal class BufferedPanel : Panel
    { internal BufferedPanel() { DoubleBuffered = true; } }
}
