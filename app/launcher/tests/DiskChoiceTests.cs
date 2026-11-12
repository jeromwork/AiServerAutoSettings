using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace RemoteAgents.Launcher
{
    internal static class DiskChoiceTests
    {
        static int count;
        static void Check(bool ok, string label) { if (!ok) throw new Exception("DiskChoice: " + label); count++; }
        static Dictionary<string, object> Profile(object disk) { return ConfigBundle.D("kind", "remoteagents-config", "schema", 1, "disk", disk); }
        static Dictionary<string, object> Parse(object disk) { return ConfigBundle.Parse(Json.Encode(Profile(disk))).Profile; }
        static void Reject(object disk, string label, string reason = null)
        {
            try { Parse(disk); } catch (InvalidDataException ex) { Check(reason == null || ex.Message.Contains(reason), label + " reason: " + ex.Message); return; }
            throw new Exception("DiskChoice accepted " + label);
        }
        internal static void Run()
        {
            count = 0;
            var empty = new Dictionary<string, object>();
            Check(!ConfigSections.DiskChosen(empty), "absent is not chosen");
            Check(!DiskChoice.FromProfile(Parse(ConfigBundle.D("base", "C:\\Disk"))).Chosen, "base alone is not chosen");
            Check(!ConfigSections.Present(Profile(ConfigBundle.D("base", "C:\\Disk")), ConfigSections.Disk), "base alone has no Disk section");
            var none = Parse(ConfigBundle.D("folders", new object[0]));
            Check(ConfigSections.DiskChosen(none) && ConfigSections.Present(none, ConfigSections.Disk), "explicit none is a Disk section");
            Check(ConfigPlan.Build(none, new Dictionary<string,string>(), new Dictionary<string,bool>()).SequenceEqual(new[]{ConfigSections.Disk}), "explicit none planned");
            var all = Parse(ConfigBundle.D("folders", "all"));
            Check(DiskChoice.FromProfile(all).All && DiskChoice.FromProfile(all).Paths.SequenceEqual(new[]{"."}), "all to allowlist");
            Check(Json.Str(Json.Map(DiskChoice.FromProfile(all).WriteTo(all, "")["disk"]), "folders") == "all", "all roundtrip");
            Check(DiskChoice.FromProfile(Parse(ConfigBundle.D("base", "C:\\Disk", "external", new[]{ConfigBundle.D("path", "D:\\", "remote", "Drive")}))).External.Count == 1, "absolute drive root accepted outside Disk");
            var entries = new object[]{"A", ConfigBundle.D("path", "B/docs", "direction", "send"), ConfigBundle.D("path", "B/src", "direction", "send"), ConfigBundle.D("path", "C", "direction", "receive")};
            var external = new object[]{ConfigBundle.D("path", "D:\\Reports", "remote", "Reports", "direction", "send")};
            var p = Parse(ConfigBundle.D("base", "C:\\Disk", "folders", entries, "external", external));
            var choice = DiskChoice.FromProfile(p);
            Check(choice.Chosen && choice.DirectionOf("B/other") == "send" && choice.DirectionOf("C") == "receive" && choice.DirectionOf("A") == "both", "direction is project-wide");
            var roundtrip = DiskChoice.FromProfile(Parse(Json.Map(choice.WriteTo(p, "ignored")["disk"])));
            Check(roundtrip.Paths.SequenceEqual(choice.Paths) && roundtrip.External.Single().Path == "D:\\Reports" && roundtrip.External.Single().Direction == "send", "choice roundtrip preserves external");
            var request = ConfigRequests.Disk(p, "ignored", null);
            Check(Json.Strings(request["paths"]).SequenceEqual(choice.Paths) && Json.Str(request, "base") == "C:\\Disk", "request paths/base");
            Check(Json.Map(request["directions"]).Count == 2 && Json.Str(Json.Map(request["directions"]), "B") == "send", "request directions omits both");
            Check(Json.Str(Json.Map(Json.Array(request["external"])[0]), "direction") == "send" && !Json.Bool(request, "reconnect"), "request external/reconnect");
            Check(Json.Strings(ConfigRequests.Disk(all, "C:\\Disk", null)["paths"]).Single() == ".", "all request");
            Check(Json.Strings(ConfigRequests.Disk(empty, "C:\\Disk", new[]{"old"})["paths"]).Single() == "old", "unchosen legacy fallback");
            var updated = DiskChoice.FromProfile(ConfigProfile.WithFolders(p, new[]{"B/new", "A"}, "ignored"));
            Check(updated.DirectionOf("B/new") == "send" && updated.External.Count == 1, "WithFolders preserves directions and external");
            updated = DiskChoice.FromProfile(ConfigProfile.SyncFromSettings(p, empty, "E:\\Disk", new[]{"C", "B"}, "", ""));
            Check(updated.DirectionOf("C") == "receive" && updated.DirectionOf("B") == "send" && updated.External.Count == 1, "settings preserve directions/external");
            Check(DiskChoice.FromProfile(ConfigProfile.WithFolders(p, new[]{"."}, "")).All, "settings all becomes all");
            var externalOnly = Parse(ConfigBundle.D("external", external));
            Check(!ConfigSections.DiskChosen(externalOnly) && ConfigSections.Present(externalOnly, ConfigSections.Disk), "external alone planned, folders still unchosen");
            Check(!DiskChoice.FromProfile(DiskChoice.FromProfile(externalOnly).WriteTo(externalOnly, "")).Chosen, "write preserves unchosen state");
            Reject(ConfigBundle.D("folders", "none"), "only all string accepted");
            Reject(ConfigBundle.D("folders", new object[]{ConfigBundle.D("path", "B", "direction", "SEND")}), "direction enum");
            Reject(ConfigBundle.D("folders", new object[]{ConfigBundle.D("path", "B", "extra", true)}), "unknown folder field");
            Reject(ConfigBundle.D("folders", new object[]{ConfigBundle.D("direction", "both")}), "path required");
            Reject(ConfigBundle.D("folders", new object[]{"B", ConfigBundle.D("path", "b/docs", "direction", "send")}), "mixed direction", "Разные направления");
            Reject(ConfigBundle.D("folders", new object[]{"B", ConfigBundle.D("path", "b")}), "case duplicate");
            Reject(ConfigBundle.D("folders", new object[]{"B/../file"}), "traversal");
            Reject(ConfigBundle.D("folders", new object[]{"CON"}), "reserved project");
            foreach (string path in new[]{"relative", "D:relative", "\\rooted", "D:\\Disk\\..\\Reports", "\\\\?\\D:\\Reports", "D:\\NUL", "D:\\Reports:stream"})
                Reject(ConfigBundle.D("external", new[]{ConfigBundle.D("path", path, "remote", "Reports")}), "external path " + path);
            foreach (string remote in new[]{"A/B", "bad..name", "bad.", "CON", "A:send"})
                Reject(ConfigBundle.D("external", new[]{ConfigBundle.D("path", "D:\\Reports", "remote", remote)}), "external remote " + remote);
            Reject(ConfigBundle.D("base", "D:\\Disk", "external", new[]{ConfigBundle.D("path", "d:/Disk/Reports", "remote", "Reports")}), "external inside base", "корнем Disk");
            Reject(ConfigBundle.D("external", new[]{ConfigBundle.D("path", "D:\\Reports", "remote", "Reports", "extra", 1)}), "external unknown field");
            Reject(ConfigBundle.D("external", new[]{ConfigBundle.D("path", "D:\\Reports")}), "external remote required");
            Reject(ConfigBundle.D("external", new[]{ConfigBundle.D("path", "D:\\Reports", "remote", "Reports", "direction", "bad")}), "external direction");
            Reject(ConfigBundle.D("external", new[]{ConfigBundle.D("path", "D:\\Reports", "remote", "Reports"), ConfigBundle.D("path", "D:\\Reports\\Child", "remote", "Other")}), "external overlap");
            Reject(ConfigBundle.D("folders", new[]{"Reports"}, "external", external), "external project direction conflict", "Разные направления");
            Check(DiskChoice.FromProfile(Parse(ConfigBundle.D("external", new[]{ConfigBundle.D("path", "\\\\server\\share\\Reports", "remote", "Reports")}))).External.Count == 1, "UNC accepted");
            string home = Path.Combine(Path.GetTempPath(), "disk-choice-" + Guid.NewGuid().ToString("N"));
            try {
                ConfigBundle.Store(home, ConfigBundle.Parse(Json.Encode(Profile(ConfigBundle.D("folders", new[]{"A", "B/docs"})))), null);
                Check(ConfigBundle.Conflicts(home, ConfigBundle.Parse(Json.Encode(Profile(ConfigBundle.D("folders", "all"))))).Length == 0, "expanding to all has no removal conflict");
                Check(ConfigBundle.Conflicts(home, ConfigBundle.Parse(Json.Encode(Profile(ConfigBundle.D("folders", new[]{ConfigBundle.D("path", "A", "direction", "send"), ConfigBundle.D("path", "B", "direction", "receive")}))))).Length == 0, "objects cover old paths");
                ConfigBundle.Store(home, ConfigBundle.Parse(Json.Encode(Profile(ConfigBundle.D("folders", "all")))), new[]{"disk"});
                Check(ConfigBundle.Conflicts(home, ConfigBundle.Parse(Json.Encode(Profile(ConfigBundle.D("folders", new object[0]))))).Single().Contains("все проекты"), "all to none removal conflict");
            } finally { if (Directory.Exists(home)) Directory.Delete(home, true); }
            Console.WriteLine("PASS: DiskChoice: " + count + " checks (parse, roundtrip, plan, request, conflicts)");
        }
    }
}
