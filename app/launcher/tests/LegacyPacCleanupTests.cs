using System;
using System.IO;
using System.Reflection;
using System.Runtime.ExceptionServices;
namespace RemoteAgents.Launcher
{
    internal static class LegacyPacCleanupTests
    {
        sealed class Browser : ILegacyPacBrowser
        {
            public string Pac { get; set; }
            public void SetPac(string value) { Pac = value; }
        }
        internal static void Run()
        {
            string home = Path.Combine(Path.GetTempPath(), "legacy-pac-" + Guid.NewGuid().ToString("N"));
            string file = Path.Combine(home, "state", "lan-pac.json");
            const string url = "http://127.0.0.1:17880/owned/proxy.pac";
            try {
                var browser = new Browser { Pac = url };
                Action<bool, string> save = (hadPrevious, previous) => Files.Atomic(file, Json.Encode(new { url, hadPrevious, previous }));
                save(true, "http://previous.example/proxy"); LegacyPacCleanup.Recover(home, browser);
                if (browser.Pac != "http://previous.example/proxy" || File.Exists(file)) throw new Exception("previous setting not restored");
                browser.Pac = url; save(true, ""); LegacyPacCleanup.Recover(home, browser);
                if (browser.Pac != "") throw new Exception("empty setting not restored");
                browser.Pac = url; save(false, ""); LegacyPacCleanup.Recover(home, browser);
                if (browser.Pac != null || File.Exists(file)) throw new Exception("absent setting not restored");
                browser.Pac = "http://foreign.example/proxy"; save(true, "previous"); LegacyPacCleanup.Recover(home, browser);
                if (browser.Pac != "http://foreign.example/proxy" || File.Exists(file)) throw new Exception("foreign setting changed");
                Files.Atomic(file, Json.Encode(new { url = "http://foreign.example/proxy.pac", hadPrevious = false }));
                bool rejected = false; try { LegacyPacCleanup.Recover(home, browser); } catch (InvalidDataException) { rejected = true; }
                if (!rejected || browser.Pac != "http://foreign.example/proxy") throw new Exception("invalid ownership accepted");
                Console.WriteLine("PASS: LegacyPacCleanup");
            } finally { if (Directory.Exists(home)) Directory.Delete(home, true); }
        }
        // -p:LanTests=true includes helper setup/protocol regressions alongside the LAN suites.
        static int Main(string[] args) { Run(); LanTunTests.Run(); LanHostsTests.Run(); NetHelperTests.Run(); return 0; }
    }
    internal static class Stage6PortableEntry
    {
        static int Main(string[] args)
        {
            if (args.Length == 0 || !args[0].StartsWith("--", StringComparison.Ordinal)) { LegacyPacCleanupTests.Run(); LanTickTests.Run(args.Length == 0 ? Path.GetTempPath() : args[0]); }
            try { return (int)typeof(LanTunTests).GetMethod("Main", BindingFlags.Static | BindingFlags.NonPublic).Invoke(null, new object[] { args }); }
            catch (TargetInvocationException ex) { ExceptionDispatchInfo.Capture(ex.InnerException).Throw(); throw; }
        }
    }
}
