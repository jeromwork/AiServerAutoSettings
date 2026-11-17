using System;
using System.IO;
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
        static int Main(string[] args) { Run(); return 0; }
    }
}
