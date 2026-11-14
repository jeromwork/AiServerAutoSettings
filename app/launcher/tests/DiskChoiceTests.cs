using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace RemoteAgents.Launcher
{
    // disk.folders: the server folders a config asks to accept at installation (docs/CONFIG.md «Диск»).
    internal static class DiskChoiceTests
    {
        static int count;
        static void Check(bool ok, string label) { if (!ok) throw new Exception("DiskChoice: " + label); count++; }
        static Dictionary<string, object> D(params object[] pairs) { return ConfigBundle.D(pairs); }
        static Dictionary<string, object> Profile(object disk) { return D("kind", "remoteagents-config", "schema", 1, "disk", disk); }
        static Dictionary<string, object> Parse(object disk) { return ConfigBundle.Parse(Json.Encode(Profile(disk))).Profile; }
        static void Reject(object disk, string label, string reason = null)
        {
            try { Parse(disk); } catch (InvalidDataException ex) { Check(reason == null || ex.Message.Contains(reason), label + " reason: " + ex.Message); return; }
            throw new Exception("DiskChoice accepted " + label);
        }
        static void Accept(object disk, string label)
        {
            try { Parse(disk); count++; } catch (InvalidDataException ex) { throw new Exception("DiskChoice refused " + label + ": " + ex.Message); }
        }
        internal static void Run()
        {
            count = 0;
            var empty = new Dictionary<string, object>();
            // The format: names of server folders, each with an optional absolute path on this computer.
            var entries = new object[] { D("id", "Проект"), D("id", "Фото", "path", "D:\\Фото") };
            var p = Parse(D("base", "C:\\Disk", "folders", entries));
            var choice = DiskChoice.FromProfile(p);
            Check(choice.Folders.Select(f => f.Id).SequenceEqual(new[] { "Проект", "Фото" }) && choice.Folders[0].Path == "" && choice.Folders[1].Path == "D:\\Фото" && choice.Warnings.Count == 0, "ids and optional paths, nothing to warn about");
            // The request of the wizard's Disk step; Install-RemoteDisk.ps1 -AcceptFile reads the same [{ id, path? }].
            var request = ConfigRequests.Disk(p, "ignored");
            var rows = Json.Array(request["folders"]).Select(Json.Map).ToArray();
            Check(Json.Str(request, "base") == "C:\\Disk" && !Json.Bool(request, "reconnect"), "request base and reconnect");
            Check(rows.Length == 2 && Json.Str(rows[0], "id") == "Проект" && !rows[0].ContainsKey("path") && Json.Str(rows[1], "id") == "Фото" && Json.Str(rows[1], "path") == "D:\\Фото", "request folders are [{ id, path? }]");
            Check(!request.ContainsKey("paths") && !request.ContainsKey("directions") && !request.ContainsKey("external"), "no field of the earlier request survives");
            var accept = Json.Map(Json.Parse(Json.Encode(new Dictionary<string, object> { { "folders", request["folders"] } })));
            Check(Json.Array(Json.Get(accept, "folders")).Length == 2, "the folders list alone is the AcceptFile document");
            // Switching servers must not offer old local data (including paths outside the old Disk root) to the new peer.
            string beforeReconnect = Json.Encode(p);
            var reconnect = ConfigRequests.Disk(p, "C:\\Disk-new", true);
            Check(Json.Bool(reconnect, "reconnect") && Json.Str(reconnect, "base") == "C:\\Disk-new", "reconnect uses the newly chosen root, not the old profile base");
            Check(reconnect.Count == 2 && !reconnect.ContainsKey("folders"), "reconnect accepts neither old ids nor absolute folder paths");
            Check(Json.Encode(p) == beforeReconnect && ConfigRequests.Disk(p, "ignored").ContainsKey("folders"), "building a reconnect request does not mutate the stored folder choice or ordinary apply");
            // No folders: nothing is accepted, the server only offers its folders in Syncthing Tray.
            foreach (var none in new object[] { D("base", "C:\\Disk"), D("folders", new object[0]), D() }) {
                var noRequest = ConfigRequests.Disk(Parse(none), "C:\\Default");
                Check(!noRequest.ContainsKey("folders") && noRequest.Count == 2, "no folders -> no folders field (nothing accepted)");
            }
            Check(Json.Str(ConfigRequests.Disk(empty, "C:\\Default"), "base") == "C:\\Default", "base falls back to the installed or default root");
            // Earlier formats are read with warnings and never refused.
            var earlier = new object[] { "A", D("path", "B/docs", "direction", "send"), D("path", "B/src", "direction", "send"), D("path", "C", "direction", "receive"), "B" };
            var external = new object[] { D("path", "D:\\Reports", "remote", "Reports", "direction", "send") };
            var old = Parse(D("base", "C:\\Disk", "folders", earlier, "external", external));
            var oldChoice = DiskChoice.FromProfile(old);
            Check(oldChoice.Folders.Select(f => f.Id).SequenceEqual(new[] { "A", "B", "C" }), "earlier paths become their top-level folders, merged");
            Check(oldChoice.Warnings.Count(w => w.Contains("«B/docs»") && w.Contains("«B»")) == 1 && oldChoice.Warnings.Count(w => w.Contains("«B/src»")) == 1, "each nested path is reported once");
            Check(oldChoice.Warnings.Count(w => w.Contains("направление «send»") && w.Contains("«B»")) == 1 && oldChoice.Warnings.Any(w => w.Contains("направление «receive»") && w.Contains("«C»")), "ignored directions are reported once per folder");
            Check(oldChoice.Warnings.Any(w => w.Contains("disk.external") && w.Contains("D:\\Reports") && w.Contains("«Reports»") && w.Contains("Syncthing Tray")), "external folders are reported");
            var oldRequest = ConfigRequests.Disk(old, "x");
            Check(Json.Array(oldRequest["folders"]).Length == 3 && !oldRequest.ContainsKey("external") && !oldRequest.ContainsKey("directions"), "earlier config gives the same kind of request");
            Check(oldChoice.Warnings.All(w => !w.Contains("\n")), "warnings are single lines for the journal");
            var all = Parse(D("folders", "all"));
            Check(DiskChoice.FromProfile(all).Folders.Count == 0 && DiskChoice.FromProfile(all).Warnings.Single().Contains("«all»") && !ConfigRequests.Disk(all, "C:\\Disk").ContainsKey("folders"), "\"all\" is ignored with a warning, nothing is accepted");
            Accept(D("base", "D:\\Disk", "external", new[] { D("path", "d:/Disk/Reports", "remote", "Reports") }), "earlier external inside the root (ignored now)");
            Accept(D("external", new[] { D("path", "D:\\Reports", "remote", "Reports"), D("path", "D:\\Reports\\Child", "remote", "Other") }), "earlier overlapping external (ignored now)");
            Accept(D("folders", new object[] { "B", D("path", "b/docs", "direction", "send") }), "earlier mixed directions (ignored now)");
            // The Disk section follows the server: Syncthing is installed and paired even without a folder list.
            var serverOnly = Json.Map(Json.Parse("{\"server\":{\"address\":\"203.0.113.10\"}}"));
            Check(ConfigSections.Present(serverOnly, ConfigSections.Disk) && ConfigSections.Present(Profile(D("folders", new object[0])), ConfigSections.Disk), "a server or a disk section describes the Disk");
            Check(!ConfigSections.Present(empty, ConfigSections.Disk) && !ConfigSections.Present(Json.Map(Json.Parse("{\"device\":{\"name\":\"x\"}}")), ConfigSections.Disk), "no server and no disk section: the Disk stays as it is");
            var optOut = Json.Map(Json.Parse("{\"server\":{\"address\":\"203.0.113.10\"},\"disk\":{\"folders\":[{\"id\":\"A\"}]},\"components\":{\"disk\":{\"enabled\":false}}}"));
            Check(!ConfigSections.Present(optOut, ConfigSections.Disk) && !ConfigPlan.Build(optOut, new Dictionary<string, string>(), new Dictionary<string, bool>()).Contains(ConfigSections.Disk), "components.disk.enabled=false opts out of the Disk");
            ((Dictionary<string, object>)Json.Map(optOut["components"])["disk"])["enabled"] = true;
            Check(ConfigSections.Present(optOut, ConfigSections.Disk), "components.disk.enabled=true keeps the Disk");
            Check(ConfigPlan.Build(serverOnly, new Dictionary<string, string>(), new Dictionary<string, bool>()).Contains(ConfigSections.Disk), "a first apply of a server-only config installs the Disk");
            var changedFolders = Parse(D("folders", new object[] { D("id", "A") }));
            Check(ConfigSections.Hash(changedFolders, ConfigSections.Disk) != ConfigSections.Hash(Parse(D("folders", new object[] { D("id", "B") })), ConfigSections.Disk), "a changed folder list re-applies only the Disk");
            // SyncFromSettings: the root chosen in the step-by-step wizard follows; accepted folders are never invented.
            var updated = ConfigProfile.SyncFromSettings(p, empty, "E:\\Disk", "", "");
            Check(Json.Str(Json.Map(updated["disk"]), "base") == "E:\\Disk" && DiskChoice.FromProfile(updated).Folders.Select(f => f.Id).SequenceEqual(new[] { "Проект", "Фото" }), "settings change the root and keep the folders");
            Check(!ConfigProfile.SyncFromSettings(serverOnly, empty, "E:\\Disk", "", "").ContainsKey("disk"), "settings do not invent a disk section");
            // Validation.
            Reject(D("folders", "none"), "only the \"all\" string");
            Reject(D("folders", new object[] { D("path", "B", "direction", "SEND") }), "direction enum of the earlier format");
            Reject(D("folders", new object[] { D("path", "B", "extra", true) }), "unknown earlier folder field");
            Reject(D("folders", new object[] { D("id", "A", "extra", true) }), "unknown folder field");
            Reject(D("folders", new object[] { D("direction", "both") }), "id required");
            Reject(D("folders", new object[] { D("id", "A"), D("id", "a") }), "same folder spelled in another case", "Повторяющиеся");
            Reject(D("folders", new object[] { D("id", "A"), D("id", "A") }), "same id twice", "Повторяющиеся");
            Reject(D("folders", new object[] { "A", D("id", "A") }), "an id and the earlier spelling of the same folder", "Повторяющиеся");
            Reject(D("folders", new object[] { "B", D("path", "b") }), "earlier case duplicate", "Повторяющиеся");
            foreach (string id in new[] { "A/B", "..", "A..B", "bad.", "bad ", "CON", "nul.txt", "A:B", "A\\B", "-start" })
                Reject(D("folders", new object[] { D("id", id) }), "folder id " + id);
            Reject(D("folders", new object[] { "B/../file" }), "earlier traversal");
            Reject(D("folders", new object[] { "CON" }), "earlier reserved project");
            foreach (string path in new[] { "relative", "D:relative", "\\rooted", "D:\\Disk\\..\\Reports", "\\\\?\\D:\\Reports", "D:\\NUL", "D:\\Reports:stream" })
                Reject(D("folders", new object[] { D("id", "A", "path", path) }), "folder path " + path);
            Reject(D("base", "D:\\Disk", "folders", new object[] { D("id", "A", "path", "d:/Disk") }), "path equal to the Disk root", "корень Disk");
            Reject(D("base", "D:\\Disk\\Work", "folders", new object[] { D("id", "A", "path", "D:\\Disk") }), "path above the Disk root", "корень Disk");
            Accept(D("base", "D:\\Disk", "folders", new object[] { D("id", "A", "path", "d:/Disk/A") }), "a path inside the Disk root");
            Reject(D("folders", new object[] { D("id", "A", "path", "D:\\X"), D("id", "B", "path", "d:/x/Y") }), "overlapping paths", "Пересекающиеся");
            Accept(D("folders", new object[] { D("id", "A", "path", "\\\\server\\share\\A"), D("id", "B", "path", "D:\\") }), "UNC and a drive root");
            Reject(D("external", new[] { D("path", "D:\\Reports") }), "earlier external without remote");
            Reject(D("external", new[] { D("path", "D:\\Reports", "remote", "Reports", "direction", "bad") }), "earlier external direction");
            // A stored profile in the earlier format: re-parsing it never fails and never turns into a conflict.
            string home = Path.Combine(Path.GetTempPath(), "disk-choice-" + Guid.NewGuid().ToString("N"));
            try {
                ConfigBundle.Store(home, ConfigBundle.Parse(Json.Encode(Profile(D("base", "C:\\Disk", "folders", new object[] { "A", "B/docs" })))), null);
                Check(ConfigBundle.Conflicts(home, ConfigBundle.Parse(Json.Encode(Profile(D("folders", new object[] { D("id", "C") }))))).Length == 0, "other or fewer folders never conflict: they only list what to accept");
                Check(ConfigBundle.Conflicts(home, ConfigBundle.Parse(Json.Encode(Profile(D("folders", new object[0]))))).Length == 0, "an empty list never conflicts");
                Check(ConfigBundle.Conflicts(home, ConfigBundle.Parse(Json.Encode(Profile(D("base", "D:\\Other"))))).Single().StartsWith("disk:"), "another Disk root still conflicts");
            } finally { if (Directory.Exists(home)) Directory.Delete(home, true); }
            Console.WriteLine("PASS: DiskChoice: " + count + " checks (disk.folders format, earlier formats with warnings, request, plan, validation, conflicts)");
        }
    }
}
