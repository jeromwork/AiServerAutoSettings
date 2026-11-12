using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace RemoteAgents.Launcher
{
    internal static class DiskFoldersModelTests
    {
        static int count;
        static void Check(bool ok, string message) { if (!ok) throw new Exception("Folders: " + message); count++; }
        static Dictionary<string, object> Profile(string disk) { return Json.Map(Json.Parse("{\"disk\":" + disk + "}")); }
        static DiskFoldersModel Model(string disk) { return new DiskFoldersModel(DiskChoice.FromProfile(Profile(disk))); }
        static Dictionary<string, object> Level(string rows, bool truncated = false)
        { return Json.Map(Json.Parse("{\"rows\":[" + rows + "],\"truncated\":" + (truncated ? "true" : "false") + "}")); }
        static string Row(string path, string direction = "both", int changes = 0)
        { return "{\"path\":" + Json.Encode(path) + ",\"kind\":\"directory\",\"presence\":\"both\",\"direction\":" + Json.Encode(direction) + ",\"localChanges\":" + changes + "}"; }
        static DiskChoice Roundtrip(DiskFoldersModel model)
        { return DiskChoice.FromProfile(model.ToChoice().WriteTo(new Dictionary<string, object>(), "C:\\Disk")); }
        static bool Refused(Action action) { try { action(); return false; } catch (IOException) { return true; } catch (InvalidDataException) { return true; } }
        internal static void Run()
        {
            var absent = new Dictionary<string, object>();
            var c = DiskChoice.FromProfile(absent); var m = new DiskFoldersModel(c);
            Check(!c.Chosen && m.Mode == DiskFoldersMode.Selected, "missing choice prompts for folders");
            Check(!absent.ContainsKey("disk") && !c.Chosen, "display/skip does not mutate profile or choose empty folders");
            m.SetMode(DiskFoldersMode.None); c = Roundtrip(m);
            Check(c.Chosen && !c.All && c.Folders.Count == 0 && c.External.Count == 0, "explicit none roundtrips as chosen empty array");
            m = Model("{\"folders\":\"all\"}");
            Check(m.Mode == DiskFoldersMode.All && m.Includes("unloaded/deep") && Roundtrip(m).All, "all includes unloaded and future folders");
            m.Level("", Level(Row("Фото") + "," + Row("Работа")));
            m.Level("Фото", Level(Row("Фото/Альбом") + "," + Row("Фото/Скрытое")));
            m.Set("Фото/Альбом", false); c = Roundtrip(m);
            Check(!c.All && c.Paths.SequenceEqual(new[] {"Работа", "Фото/Скрытое"}.OrderBy(x => x, StringComparer.Ordinal)), "unchecking from all preserves sibling and other project");
            Check(m.Partial("Фото") && !m.Includes("Фото/Альбом") && m.Includes("Фото/Скрытое/новое"), "partial and recursive display");
            m = Model("{\"folders\":[{\"path\":\"Фото/Архив/2024\",\"direction\":\"receive\"},\"НетНаСервере/Пока\"]}");
            m.Level("", Level(Row("Фото", "send", 7)));
            c = Roundtrip(m);
            Check(c.Paths.Contains("НетНаСервере/Пока") && c.Paths.Contains("Фото/Архив/2024"), "unloaded and missing selections survive inventory");
            Check(m.Partial("Фото") && m.DirectionOf("Фото/Архив") == DiskChoice.Receive && c.DirectionOf("Фото") == DiskChoice.Receive, "profile direction wins over stale tree metadata");
            Check(m.Items["Фото"].LocalChanges == 7 && m.Items["Фото"].Presence == "both", "receive changes and presence exposed to display");
            m.SetDirection("Фото", DiskChoice.Send);
            Check(Roundtrip(m).Folders.Single(f => f.Path.StartsWith("Фото")).Direction == DiskChoice.Send, "direction applies to top-level project including deep selection");
            m.Set("Фото", true); m.SetDirection("Фото", DiskChoice.Both);
            Check(Roundtrip(m).Folders.Single(f => f.Path == "Фото").Direction == DiskChoice.Both && !Roundtrip(m).Paths.Any(p => p.StartsWith("Фото/")), "parent replaces descendants and both remains simple");
            m = Model("{\"folders\":[\"Фото\"]}"); m.Level("", Level(Row("Фото", "receive", 3)));
            Check(m.DirectionOf("Фото") == DiskChoice.Both, "explicit default direction is not replaced by tree direction");
            m = Model("{}"); m.Level("", Level(Row("Фото", "receive", 3))); m.Set("Фото", true);
            Check(Roundtrip(m).DirectionOf("Фото") == DiskChoice.Receive, "new choice can reuse existing local direction");
            m = Model("{\"folders\":\"all\"}"); m.Level("", Level(Row("Фото") + "," + Row("Работа")));
            m.SetDirection("Фото", DiskChoice.Receive); c = Roundtrip(m);
            Check(!c.All && c.Paths.Length == 2 && c.DirectionOf("Фото") == DiskChoice.Receive && c.DirectionOf("Работа") == DiskChoice.Both, "direction from all serializes a complete explicit choice");
            m.SetMode(DiskFoldersMode.All); m.SetMode(DiskFoldersMode.Selected);
            Check(Roundtrip(m).DirectionOf("Фото") == DiskChoice.Both, "all resets project-specific directions before returning to selective mode");
            m = Model("{\"folders\":\"all\"}"); m.Level("", Level(Row("Фото", "receive")));
            Check(m.DirectionOf("Фото") == DiskChoice.Both && Roundtrip(m).All, "all displays the direction that its profile will actually apply");
            m = Model("{\"folders\":\"all\"}"); m.Level("", Level(Row("Фото"), true));
            Check(Refused(() => m.Set("Фото", false)) && Roundtrip(m).All, "incomplete inventory cannot silently lose folders when unchecking all");
            Check(Refused(() => m.SetDirection("Фото", DiskChoice.Send)) && Roundtrip(m).All, "incomplete all direction edit is refused without loss");
            m.SetMode(DiskFoldersMode.Selected); m.Set("Фото", true);
            Check(Roundtrip(m).Paths.SequenceEqual(new[] {"Фото"}), "explicit selective mode can choose from a truncated list");
            m = Model("{\"folders\":[\"Фото\"]}"); m.Level("Фото", Level(Row("Фото/А"), true));
            Check(Refused(() => m.Set("Фото/А", false)) && Roundtrip(m).Paths.SequenceEqual(new[] {"Фото"}), "partial child edit refuses to lose unlisted siblings");
            m = Model("{\"folders\":[\"Фото\"]}"); m.Level("Фото", Level(Row("Фото/А") + "," + Row("Фото/Б")));
            m.SetMode(DiskFoldersMode.None); m.Set("Фото", true); m.Set("Фото/А", false);
            Check(Roundtrip(m).Paths.SequenceEqual(new[] {"Фото/Б"}), "changing quick mode keeps loaded sibling information");
            m = Model("{\"folders\":[],\"external\":[{\"path\":\"D:\\\\Отчёты\",\"remote\":\"Отчёты\",\"direction\":\"send\"}]}");
            Check(m.Mode == DiskFoldersMode.Selected && Roundtrip(m).External[0].Direction == DiskChoice.Send, "external-only choice roundtrips");
            m.AddExternal("E:\\Фото", "Фото с камеры", DiskChoice.Receive); c = Roundtrip(m);
            Check(c.External.Count == 2 && c.External[1].Remote == "Фото с камеры" && c.External[1].Direction == DiskChoice.Receive, "external path, remote name and direction roundtrip");
            c.External[0].Direction = DiskChoice.Receive;
            Check(m.External[0].Direction == DiskChoice.Send, "export does not alias mutable UI entries");
            Check(Refused(() => m.AddExternal("e:\\фото\\", "Другое", DiskChoice.Both)), "duplicate local path rejected ignoring case and trailing separator");
            Check(Refused(() => m.AddExternal("F:\\Иное", "отчёты", DiskChoice.Both)), "duplicate server name rejected");
            Check(Refused(() => m.AddExternal("F:\\Иное", "../опасно", DiskChoice.Both)), "server name cannot escape a project");
            var profile = Profile("{\"base\":\"D:\\\\Disk\",\"folders\":[],\"extra\":true}"); profile["device"] = "kept";
            var written = m.ToChoice().WriteTo(profile, "X:\\Other");
            Check(Json.Str(Json.Map(written["disk"]), "base") == "D:\\Disk" && Json.Bool(Json.Map(written["disk"]), "extra") && (string)written["device"] == "kept", "profile update preserves base and unrelated settings");
            Check(DiskChoice.FromProfile(profile).External.Count == 0, "profile export leaves source unchanged");
            m.External.RemoveAt(0); Check(Roundtrip(m).External.Count == 1, "stop synchronizing exports removal only");
            m.SetMode(DiskFoldersMode.None); c = Roundtrip(m);
            Check(c.Folders.Count == 0 && c.External.Count == 0 && !c.All && c.Chosen, "none clears disk and external synchronization");
            m.AddExternal("C:\\Пример", "Пример", DiskChoice.Both);
            Check(m.Mode == DiskFoldersMode.Selected && Roundtrip(m).External.Count == 1, "adding external after none re-enables synchronization");
            Check(Refused(() => m.SetDirection("НеОтмечена", DiskChoice.Send)), "cannot change unchecked project direction");
            Check(Refused(() => m.Level("", Level(Row("wrong/level")))), "wrong tree level refused");
            var crlf = Model("{\r\n\"folders\":[{\"path\":\"Фото/Архив\",\"direction\":\"receive\"}]}\r\n");
            Check(Roundtrip(crlf).DirectionOf("Фото") == DiskChoice.Receive, "CRLF profile input supported");
            Console.WriteLine("OK: " + count + " folder display / choice checks (pure model; no WinForms)");
        }
    }
}
