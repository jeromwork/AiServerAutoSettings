using System;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;

namespace RemoteAgents.Launcher
{
    internal static class TransportFaultTests
    {
        static int count;
        static void Check(bool ok, string message) { if (!ok) throw new Exception(message); count++; }
        static void Reject(string[] args, bool isTest, string message = null)
        {
            try { TransportFaultCommand.Parse(args, isTest); }
            catch (ArgumentException ex) { Check(message == null || ex.Message == message, "fixed rejection message"); return; }
            throw new Exception("Invalid/channel-rejected command accepted");
        }
        public static int Main()
        {
            foreach (string fault in new[] { "drop", "blip", "clear", "unknown" }) {
                Reject(new[] { "--transport-fault", fault, "p0", "5000" }, false, TransportFaultCommand.TestOnly);
            }
            Reject(new[] { "--transport-fault" }, false, TransportFaultCommand.TestOnly);
            Check(!UpdateChannel.IsTest, "micro-suite exercises the real Main build gate");
            Check(!TransportBusBridge.IsAllowedOutgoing(BusTopics.TransportCommand), "Main bridge blocks all command publications");
            Check(TransportBusBridge.FormatOutgoing(BusTopics.TransportCommand, null) == null, "Main cannot format command frame");
            Check(TransportBusBridge.IsAllowedOutgoing(BusTopics.TransportCommand, true), "Test bridge command allowlist");
            foreach (string fault in new[] { "drop", "clear" }) {
                var parsed = TransportFaultCommand.Parse(new[] { "--home", "/unused", "--transport-fault", fault, "p_0-1" }, true);
                Check(parsed.Fault == fault && parsed.Tag == "p_0-1" && parsed.Ms == 0, "Test command fields");
            }
            var blip = TransportFaultCommand.Parse(new[] { "--transport-fault", "blip", "p0", "5000" }, true);
            Check(blip.Ms == 5000, "blip duration");
            foreach (string[] bad in new[] {
                new[] { "--transport-fault", "blip", "p0" },
                new[] { "--transport-fault", "blip", "p0", "0" },
                new[] { "--transport-fault", "blip", "p0", "60001" },
                new[] { "--transport-fault", "blip", "p0", "9999999999999999999" },
                new[] { "--transport-fault", "blip", "p0", "-1" },
                new[] { "--transport-fault", "drop", "p0", "100" },
                new[] { "--transport-fault", "clear", "unavailable" },
                new[] { "--transport-fault", "drop", "token=secret-value" },
                new[] { "--transport-fault", "drop", "p0\nforged" },
                new[] { "--transport-fault", "drop", "p0", "--exit" },
                new[] { "--transport-fault", "drop", "p0", "--home" },
                new[] { "--transport-fault", "what", "p0" }
            }) Reject(bad, true);
            using (var bus = new EventBus(manualDispatch: true)) {
                int seen = 0; bus.Subscribe(BusTopics.TransportCommand, e => seen++);
                try { blip.Publish(bus); throw new Exception("Main published Test-parsed command"); }
                catch (ArgumentException ex) { Check(ex.Message == TransportFaultCommand.TestOnly, "Main publish gate"); }
                bus.DrainOnce(); Check(seen == 0, "Main generated no event");
                BusEvent received = null; bus.Subscribe(BusTopics.TransportCommand, e => received = e);
                blip.Publish(bus, true); bus.DrainOnce();
                Check(seen == 1 && received.Get("fault") == "blip" && received.Get("tag") == "p0" && received.Get("ms") == "5000", "Test publishes the exact scalar bus command");
            }
            Check(TransportFaultCommand.DaemonArguments(new[] { "-File", "daemon.ps1" }, false).SequenceEqual(new[] { "-File", "daemon.ps1", "-UpdateChannel", "main" }), "Main explicitly passes its channel");
            Check(TransportFaultCommand.DaemonArguments(new string[0], true).SequenceEqual(new[] { "-UpdateChannel", "test" }), "Test explicitly passes its channel");
            Wiring();
            NetHelperVersionTests.Run();
            Console.WriteLine("TransportFaultTests PASS (" + count + " assertions)"); return 0;
        }
        static void Wiring([CallerFilePath] string caller = "")
        {
            string root = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(caller), "../../.."));
            string program = File.ReadAllText(Path.Combine(root, "app/launcher/Program.cs"));
            Check(program.IndexOf("TransportFaultCommand.Parse(args, UpdateChannel.IsTest)", StringComparison.Ordinal) < program.IndexOf("string watchUpdate", StringComparison.Ordinal), "channel rejected before startup/IPC/home mutation");
            string tray = File.ReadAllText(Path.Combine(root, "app/launcher/TrayContext.cs"));
            Check(tray.Contains("TransportFaultCommand.Parse(read.Result, UpdateChannel.IsTest)") && tray.Contains("fault.Publish(bus)"), "IPC receiver channel gate and bus dispatch");
            string supervisor = File.ReadAllText(Path.Combine(root, "app/launcher/Supervisor.cs"));
            Check(supervisor.Contains("TransportFaultCommand.DaemonArguments(busArgs, UpdateChannel.IsTest)"), "actual process channel forwarding");
            Check(!WindowModel.ShouldShow(new[] { "--transport-fault", "drop", "p0" }), "fault command opens no UI/installer");
        }
    }
}
