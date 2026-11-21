using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.RegularExpressions;

namespace RemoteAgents.Launcher
{
    // Diagnostic commands are gated by the compiled update channel at every entry.
    internal sealed class TransportFaultCommand
    {
        internal const string TestOnly = "--transport-fault: только тестовая сборка";
        internal const int MaxBlipMs = 60000;
        internal readonly string Fault, Tag;
        internal readonly int Ms;
        TransportFaultCommand(string fault, string tag, int ms) { Fault = fault; Tag = tag; Ms = ms; }
        internal static bool IsRequested(string[] args) { return Array.IndexOf(args, "--transport-fault") >= 0; }
        internal static TransportFaultCommand Parse(string[] args, bool isTest)
        {
            if (!isTest) throw new ArgumentException(TestOnly);
            // Only this command and --home are accepted: no ambiguous installer/UI actions.
            var values = new List<string>(args);
            int home = values.IndexOf("--home");
            if (home >= 0) {
                if (home + 1 >= values.Count || values[home + 1].StartsWith("--", StringComparison.Ordinal)) throw Usage();
                values.RemoveRange(home, 2);
            }
            if (values.Count < 3 || values.Count > 4 || values[0] != "--transport-fault") throw Usage();
            string fault = values[1], tag = values[2]; int ms = 0;
            if ((fault != "drop" && fault != "blip" && fault != "clear") ||
                !Regex.IsMatch(tag, @"\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,95}\z") || tag == "unavailable") throw Usage();
            if (fault == "blip") {
                if (values.Count != 4 || !int.TryParse(values[3], NumberStyles.None, CultureInfo.InvariantCulture, out ms) || ms < 1 || ms > MaxBlipMs) throw Usage();
            } else if (values.Count != 3) throw Usage();
            return new TransportFaultCommand(fault, tag, ms);
        }
        static ArgumentException Usage() { return new ArgumentException("--transport-fault drop|clear <tag> или --transport-fault blip <tag> <ms: 1..60000>"); }
        internal static string[] DaemonArguments(string[] args, bool isTest)
        { return args.Concat(new[] { "-UpdateChannel", isTest ? "test" : "main" }).ToArray(); }
        internal void Publish(EventBus bus) { Publish(bus, UpdateChannel.IsTest); }
        internal void Publish(EventBus bus, bool isTest)
        {
            if (!isTest) throw new ArgumentException(TestOnly);
            if (bus == null || bus.Publish(BusTopics.TransportCommand, BusTopics.Sources.Tray,
                "fault", Fault, "tag", Tag, "ms", Ms.ToString(CultureInfo.InvariantCulture)) < 0)
                throw new InvalidOperationException("Шина тестовой программы недоступна");
        }
    }
}
