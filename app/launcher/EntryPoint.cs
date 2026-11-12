using System;
using System.Runtime.CompilerServices;
namespace RemoteAgents.Launcher
{
    // Thin entry: Program.Run is JIT-compiled only when needed (WinForms stays out of Main).
    internal static class EntryPoint
    {
        [STAThread] static int Main(string[] args)
        {
            return Start(args);
        }
        [MethodImpl(MethodImplOptions.NoInlining)] static int Start(string[] args) { return Program.Run(args); }
    }
}
