using System;
using System.Reflection;
using System.Runtime.CompilerServices;
namespace RemoteAgents.Launcher
{
    // Keep the read-only PE/overlay smoke entry independent of WinForms and user HOME.
    internal static class EntryPoint
    {
        [STAThread] static int Main(string[] args)
        {
            if(args.Length==1 && args[0]=="--selftest-invite-overlay") {
                try { InvitationOverlay.Read(Assembly.GetExecutingAssembly().Location);return 0; }
                catch { return 2; }
            }
            return Start(args);
        }
        [MethodImpl(MethodImplOptions.NoInlining)] static int Start(string[] args) { return Program.Run(args); }
    }
}
