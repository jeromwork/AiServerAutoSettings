using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Text;

namespace RemoteAgents.Launcher
{
    internal static class LanTickTests
    {
        static int count;
        static void Check(bool value, string name) { if (!value) throw new Exception("LanTick: " + name); count++; }
        [MethodImpl(MethodImplOptions.NoInlining)]
        static Exception Failure(string message)
        {
            try { throw new ArgumentOutOfRangeException("index", message); }
            catch (Exception error) { return error; }
        }
        internal static void Run(string root)
        {
            string home = Path.Combine(root, "lan-tick");
            Directory.CreateDirectory(Path.Combine(home, "status"));
            const string clinic = "{\"profile\":{\"lan\":[{\"name\":\"clinic\",\"testHost\":\"192.168.88.244\",\"testPort\":22,\"share\":{\"subnets\":[\"192.168.87.0/24\",\"192.168.88.0/21\"],\"domains\":[\"eastclinic.ru\",\"*.eastclinic.ru\"],\"dnsServers\":[\"192.168.87.1\",\"192.168.88.1\"],\"enabled\":true}}]}}";
            Files.Atomic(Path.Combine(home, "config.json"), clinic);
            var config = new Configuration(home).Data;
            var transport = ConfigBundle.D("ok", true, "helper", ConfigBundle.D("lanInPort", 17880));
            var request = LanTunNetwork.Request(Json.Map(Json.Get(config, "profile")), Json.Int(Json.Map(Json.Get(transport, "helper")), "lanInPort", 0));
            Check(Json.Str(request, "cmd") == "lan.apply", "reported clinic config follows UpdateLan request path without a helper");
            var lan = HelperLanStatus.Unavailable(config, false, false);
            var network = Json.Map(Json.Array(Json.Get(lan, "networks")).Single());
            Check(Json.Str(network, "state") == "no-helper" && Json.Str(network, "reason").Contains("установите помощник"), "missing helper has actionable LAN state");
            Check(StatusView.Lan(lan).Contains("помощник не установлен"), "tray LAN row explains missing helper");

            // Bootstrap builds the menu with netHelper == null. The first tick adds LAN.
            var initial = TrayMenuModel.Build(config, Json.Map(null), transport, Json.Map(null));
            var after = new[] { new TrayMenuEntry("lan-status", StatusView.Lan(lan), false) }.Concat(initial).ToArray();
            bool reproduced = false;
            var oldItems = initial.ToList();
            try { for (int i = 0; i < after.Length; i++) { if (after[i].Id != "separator") { var unused = oldItems[i]; } } }
            catch (ArgumentOutOfRangeException) { reproduced = true; }
            Check(reproduced, "pre-fix positional menu update reproduces Tick exception on Linux");

            var menu = new TrayMenuState();
            var items = new List<TrayMenuEntry>();
            int rebuilds = 0;
            Action<TrayMenuEntry[]> rebuild = entries => { rebuilds++; items = entries.ToList(); };
            Action<int, TrayMenuEntry> update = (i, entry) => {
                Check(items[i].Id == entry.Id, "menu label stays bound to its original click action");
                items[i] = entry;
            };
            menu.Refresh(initial, rebuild, update);
            for (int i = 0; i < 120; i++) menu.Refresh(after, rebuild, update);
            Check(rebuilds == 2 && items[0].Id == "lan-status", "first helper observation rebuilds once, subsequent ticks stay stable");
            var view = MainScreenModel.Build(new MainScreenFacts { Transport = transport, Lan = lan });
            Check(view.Overall == Tone.Ok && view.Lan.Tone == Tone.Warning && view.Lan.State.Contains("установите помощник"), "healthy transport with missing LAN helper is not red");
            menu.Refresh(initial, rebuild, update);
            Check(rebuilds == 3 && items.Count == initial.Length, "removing LAN rebuilds without stale items");
            var reordered = initial.Reverse().ToArray();
            menu.Refresh(reordered, rebuild, update);
            Check(rebuilds == 4, "same count but changed action order also rebuilds");

            // A new LAN row grows a five-item menu to six before any positional update.
            var five = Enumerable.Range(0, 5).Select(i => new TrayMenuEntry("item-" + i, "Item " + i, true)).ToArray();
            var six = new[] { new TrayMenuEntry("lan-status", StatusView.Lan(lan), false) }.Concat(five).ToArray();
            var growingMenu = new TrayMenuState();
            int builtCount = 0, growingRebuilds = 0, updatedCount = 0;
            Action<TrayMenuEntry[]> grow = entries => { growingRebuilds++; builtCount = entries.Length; };
            Action<int, TrayMenuEntry> boundedUpdate = (i, entry) => {
                Check(i < builtCount, "growing menu never updates beyond the latest rebuild");
                updatedCount++;
            };
            growingMenu.Refresh(five, grow, boundedUpdate);
            growingMenu.Refresh(six, grow, boundedUpdate);
            Check(growingRebuilds == 2 && builtCount == 6 && updatedCount == 11, "five-to-six menu growth rebuilds before updating all items");

            // Literal non-ASCII bytes, not Json.Encode (the portable serializer escapes Cyrillic).
            const string summary = "TUN не включён: помощник не установлен — установите помощник";
            string json = "{\"enabled\":false,\"state\":\"error\",\"summary\":\"" + summary + "\",\"updatedAt\":\"2026-11-13T00:00:00Z\"}";
            foreach (bool bom in new[] { false, true }) {
                File.WriteAllText(Path.Combine(home, "status/vpn.json"), json, new UTF8Encoding(bom));
                Check(Json.Str(VpnStatus.Read(home), "summary") == summary, "VpnStatus preserves literal UTF-8 Cyrillic, BOM=" + bom);
            }

            long now = 0;
            var diagnostics = new TickFailureLog(() => now);
            var journal = new Journal(home);
            var failure = Failure("Index outside collection. token=private-token\r\nnext-line");
            for (int i = 0; i < 120; i++) { now = i * 500; diagnostics.Write(journal, failure); }
            string logFile = Path.Combine(home, "logs/launcher.log");
            var lines = File.ReadAllLines(logFile);
            Check(lines.Length == 1, "identical failures log only once within a minute");
            Check(lines[0].Contains("ArgumentOutOfRangeException") && lines[0].Contains("LanTickTests.Failure") && lines[0].Contains("Index outside collection"), "diagnostic includes exception type, short reason and top frame");
            Check(lines[0].Length <= 300 && !lines[0].Contains("private-token") && !lines[0].Contains("\r"), "bounded one-line diagnostic masks secrets");
            now = 60000; diagnostics.Write(journal, failure);
            diagnostics.Write(journal, new IOException("Another failure"));
            Check(File.ReadAllLines(logFile).Length == 3, "minute boundary permits repeat and another cause logs immediately");
            string safe = TickFailureLog.Describe(Failure("Cannot read C:\\Users\\owner\\private-token\\status.json or /tmp/private-token/data https://host/private-token?key=secret"));
            Check(!safe.Contains("private-token") && !safe.Contains("secret") && !safe.Contains("owner"), "paths and URLs are removed entirely");
            safe = TickFailureLog.Describe(Failure("password=first,second;third\r\npublic info"));
            Check(!safe.Contains("first") && !safe.Contains("second") && !safe.Contains("third"), "punctuation cannot expose secret values");
            Check(TickFailureLog.Describe(Failure(new string('я', 1000))).Length <= 236, "long messages leave room for type and frame");
            diagnostics.Write(journal, Failure(new string('я', 1000)));
            Check(File.ReadAllLines(logFile).All(line => line.Length <= 300), "entire journal line stays within 300 characters including timestamp and event");
            string isolatedHome = Path.Combine(home, "isolated-steps");
            var isolatedJournal = new Journal(isolatedHome);
            var isolated = new TickFailureLog(() => 0);
            int completed = 0;
            bool first = isolated.Run(isolatedJournal, "settings", () => { completed++; });
            bool second = isolated.Run(isolatedJournal, "menu", () => { throw new ArgumentOutOfRangeException("index"); });
            bool third = isolated.Run(isolatedJournal, "status", () => { completed++; });
            Check(first && !second && third && completed == 2, "failed menu step returns false and later status step still runs");
            var isolatedLines = File.ReadAllLines(Path.Combine(isolatedHome, "logs/launcher.log"));
            Check(isolatedLines.Length == 1 && isolatedLines[0].Contains("supervisor.tick.failed step=menu ArgumentOutOfRangeException"), "failed step logs exactly one named exception");

            string stepsHome = Path.Combine(home, "step-deduplication");
            var stepsJournal = new Journal(stepsHome);
            long stepNow = 0;
            var steps = new TickFailureLog(() => stepNow);
            steps.Write(stepsJournal, failure, "menu");
            steps.Write(stepsJournal, failure, "lan");
            string stepsLog = Path.Combine(stepsHome, "logs/launcher.log");
            var stepLines = File.ReadAllLines(stepsLog);
            Check(stepLines.Length == 2 && stepLines[0].Contains("step=menu ") && stepLines[1].Contains("step=lan "), "same exception in different steps logs independently at the same millisecond");
            stepNow = 1000; steps.Write(stepsJournal, failure, "menu");
            Check(File.ReadAllLines(stepsLog).Length == 2, "same step is suppressed after one second");
            stepNow = 61000; steps.Write(stepsJournal, failure, "menu");
            Check(File.ReadAllLines(stepsLog).Length == 3, "same step logs again after sixty-one seconds");
            Console.WriteLine("PASS: " + count + " LAN tick, menu, UTF-8, step isolation and exception diagnostics checks");
        }
    }
}
