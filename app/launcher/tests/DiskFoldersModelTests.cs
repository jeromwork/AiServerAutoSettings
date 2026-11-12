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
        static void StatusChecks()
        {
            const string both = "✓ На компьютере и на сервере", copies = "Не синхронизируется; копии на компьютере и сервере";
            const string local = "🖥 Только на этом компьютере (не синхронизируется)", server = "☁ Только на сервере";
            const string download = "↓ Будет скачана", downloading = "⟳ Скачивается", upload = "↑ Будет отправлена", uploading = "⟳ Отправляется";
            const string noDownload = "☁ На сервере; получение отключено", noUpload = "🖥 На компьютере; отправка отключена";
            const string incompleteLocal = "Обнаружена на компьютере; список неполный", incompleteServer = "Обнаружена на сервере; список неполный";
            const string unknown = "Наличие не проверено", incompleteUnknown = "Наличие не проверено; список неполный";
            const string removal = "Перестанет синхронизироваться; файлы на компьютере останутся";
            // Independent truth table: columns both/send/receive before Apply, then both/send/receive after success.
            var expected = new Dictionary<string, string[]> {
                { "True/both/False", new[] { both, both, both, both, both, both } },
                { "True/local/False", new[] { upload, upload, noUpload, uploading, uploading, noUpload } },
                { "True/server/False", new[] { download, noDownload, download, downloading, noDownload, downloading } },
                { "True//False", new[] { unknown, unknown, unknown, unknown, unknown, unknown } },
                { "False/both/False", new[] { copies, copies, copies, copies, copies, copies } },
                { "False/local/False", new[] { local, local, local, local, local, local } },
                { "False/server/False", new[] { server, server, server, server, server, server } },
                { "False//False", new[] { unknown, unknown, unknown, unknown, unknown, unknown } },
                { "True/both/True", new[] { both, both, both, both, both, both } },
                { "True/local/True", new[] { incompleteLocal, incompleteLocal, incompleteLocal, incompleteLocal, incompleteLocal, incompleteLocal } },
                { "True/server/True", new[] { incompleteServer, incompleteServer, incompleteServer, incompleteServer, incompleteServer, incompleteServer } },
                { "True//True", new[] { incompleteUnknown, incompleteUnknown, incompleteUnknown, incompleteUnknown, incompleteUnknown, incompleteUnknown } },
                { "False/both/True", new[] { copies, copies, copies, copies, copies, copies } },
                { "False/local/True", new[] { incompleteLocal, incompleteLocal, incompleteLocal, incompleteLocal, incompleteLocal, incompleteLocal } },
                { "False/server/True", new[] { incompleteServer, incompleteServer, incompleteServer, incompleteServer, incompleteServer, incompleteServer } },
                { "False//True", new[] { incompleteUnknown, incompleteUnknown, incompleteUnknown, incompleteUnknown, incompleteUnknown, incompleteUnknown } }
            };
            foreach (bool check in new[] { false, true }) foreach (string presence in new[] { "both", "local", "server", "" })
            foreach (bool truncated in new[] { false, true }) foreach (bool applied in new[] { false, true })
            for (int d = 0; d < DiskChoice.Directions.Length; d++) foreach (bool wasChecked in new[] { false, true }) {
                string key = check + "/" + presence + "/" + truncated;
                string want = !check && wasChecked ? removal : expected[key][(applied ? 3 : 0) + d];
                Check(DiskFoldersModel.FolderStatus(check, presence, applied, DiskChoice.Directions[d], truncated, wasChecked) == want,
                    "status matrix " + key + "/applied=" + applied + "/" + DiskChoice.Directions[d] + "/previous=" + wasChecked);
            }
            Check(DiskFoldersModel.FolderStatus(true, "both", true, DiskChoice.Receive, false, true, "syncing") == downloading, "observed progress wins over existence of both directories");
            Check(DiskFoldersModel.FolderStatus(true, "local", true, DiskChoice.Send, true, true, "syncing") == uploading, "observed progress works with incomplete presence");
            Check(DiskFoldersModel.FolderStatus(true, "server", false, DiskChoice.Receive, false, false, "syncing") == download, "stale progress cannot confirm an unapplied selection");
            Check(DiskFoldersModel.DirectionHint(DiskChoice.Both) == "" && DiskFoldersModel.DirectionHint(DiskChoice.Receive) == "↓ только забирать" && DiskFoldersModel.DirectionHint(DiskChoice.Send) == "↑ только отправлять", "only one-way directions have a tree hint");

            var m = Model("{\"folders\":[]}");
            m.Level("", Level(Row("Фото").Replace("both", "server")));
            Check(m.Status("Фото") == server, "unchecked server folder occupies no local space");
            m.Set("Фото", true); Check(m.Status("Фото") == download, "checking only stages download");
            Check(m.Status("Фото") == download, "saving or failed apply does not advance status");
            m.MarkApplied(); Check(m.Status("Фото") == downloading, "successful apply advances pending transfer");
            m.Level("", Level(Row("Фото"))); Check(m.Status("Фото") == both, "presence refresh ends directory transfer indicator");
            m.Set("Фото", false); Check(m.Status("Фото") == removal, "unchecking promises to preserve files");
            m.Set("Фото", true); Check(m.Status("Фото") == both, "rechecking cancels removal");
            m.Set("Фото", false); m.MarkApplied(); Check(m.Status("Фото") == copies, "applied deselection no longer says will stop and acknowledges retained files");
            m.Set("Фото", true); m.MarkApplied(); m.Level("Фото", Level(Row("Фото/А").Replace("both", "server") + "," + Row("Фото/Б")));
            Check(m.Status("Фото/А") == downloading, "applied parent includes lazy descendants");
            m.Set("Фото/А", false); Check(m.Status("Фото") == both && m.Partial("Фото"), "partial parent does not claim the whole folder will stop");
            m.Set("Фото", true);
            m.SetDirection("Фото", DiskChoice.Send); Check(m.Status("Фото/А") == noDownload, "one-way edit cannot promise forbidden download");
            m.SetDirection("Фото", DiskChoice.Receive); Check(m.Status("Фото/А") == download, "changed direction requires another successful apply");
            m.MarkApplied(); Check(m.Status("Фото/А") == downloading, "new direction confirmed on apply");
            m.Level("Фото", Level(Row("Фото/А").Replace("both", "server"), true)); Check(m.Status("Фото/А") == incompleteServer, "incomplete inventory cannot prove absence");
            m.Level("Фото", Level(Row("Фото/А").Replace("both", "server"))); Check(m.Status("Фото/А") == downloading, "complete refresh clears uncertainty");
            m.Level("", Level(Row("Фото", "receive", 2))); Check(m.CanRevert("Фото/А"), "receive local changes expose warning for selected descendant");
            m.SetDirection("Фото", DiskChoice.Both); Check(!m.CanRevert("Фото"), "both suppresses receive-only warning even with stale localChanges");
            m.SetDirection("Фото", DiskChoice.Send); Check(!m.CanRevert("Фото"), "send suppresses receive-only warning");
            m.SetDirection("Фото", DiskChoice.Receive); m.Set("Фото", false); Check(!m.CanRevert("Фото"), "unchecked folder cannot revert");
            m.Set("Фото", true); m.Level("", Level(Row("Фото", "receive", 0))); Check(!m.CanRevert("Фото"), "no local changes means no warning");

            m.AddExternal("D:\\Camera", "Камера", DiskChoice.Both); var e = m.External.Single();
            Check(m.ExternalStatus(e) == "Будет подключена к синхронизации", "new external does not invent remote presence");
            m.MarkApplied(); Check(m.ExternalStatus(e) == "Подключена; состояние передачи неизвестно", "apply alone cannot prove external completion");
            m.ExternalState(e, "syncing"); Check(m.ExternalStatus(e) == downloading, "existing DiskExternal progress is displayed");
            e.Direction = DiskChoice.Send; Check(m.ExternalStatus(e) == "Будет подключена к синхронизации", "direction edit ignores stale external progress");
            e.Direction = DiskChoice.Both;
            m.ExternalState(e, "idle"); Check(m.ExternalStatus(e) == "✓ Подключена к синхронизации", "idle external does not claim that all bytes match");
            m.ExternalState(e, "paused"); Check(m.ExternalStatus(e) == "Синхронизация приостановлена", "paused external status");
            m.ExternalState(e, "detached"); Check(m.ExternalStatus(e) == "Будет подключена к синхронизации", "detached external can be reattached");
            m.SetExternal(e, false); Check(m.ExternalStatus(e) == removal && !Roundtrip(m).External.Any() && m.ExternalRows.Single() == e, "external uncheck stages removal but keeps a reversible tree row");
            m.SetExternal(e, true); Check(Roundtrip(m).External.Single().Path == e.Path && m.ExternalRows.Count() == 1, "external recheck cancels staged removal");
            m.SetMode(DiskFoldersMode.All); m.SetMode(DiskFoldersMode.Selected); Check(m.IncludesExternal(e), "all-server toggle does not remove external folders");
            m.SetExternal(e, false); m.MarkApplied(); Check(!m.ExternalRows.Any(), "confirmed external removal hides empty computer branch");
        }
        static void ReviewRegressions()
        {
            foreach (bool truncated in new[] { false, true }) {
                var m = Model("{\"folders\":[{\"path\":\"Фото/Архив\",\"direction\":\"receive\"},\"Невидимый/Путь\"]}");
                m.Level("", Level(Row("Фото") + "," + Row("Работа"), truncated));
                string before = Json.Encode(m.ToChoice().WriteTo(new Dictionary<string, object>(), "C:\\Disk"));
                m.SetMode(DiskFoldersMode.All);
                Check(m.ToChoice().All && m.DirectionOf("Фото") == DiskChoice.Both, "all applies both temporarily");
                // A refresh in All must not overwrite the saved manual directions or unloaded paths.
                m.Level("", Level(Row("Фото", "send") + "," + Row("Работа"), truncated));
                m.SetMode(DiskFoldersMode.Selected);
                Check(Json.Encode(m.ToChoice().WriteTo(new Dictionary<string, object>(), "C:\\Disk")) == before,
                    "all toggle restores exact manual subtrees and directions, truncated=" + truncated);
            }
            var fresh = Model("{\"folders\":[]}");
            fresh.Level("", Level(Row("Фото").Replace("both", "server")));
            fresh.Set("Фото", true); fresh.Set("Фото", false);
            Check(fresh.Status("Фото") == "☁ Только на сервере", "cancelled uncommitted check never stages a disconnection");
            fresh.SetMode(DiskFoldersMode.All); fresh.SetMode(DiskFoldersMode.Selected);
            Check(fresh.Status("Фото") == "☁ Только на сервере", "cancelled all never stages a disconnection");
            var external = Model("{\"folders\":\"all\",\"external\":[{\"path\":\"D:\\\\Фото\",\"remote\":\"Фото\",\"direction\":\"send\"}]}");
            external.Level("", Level(Row("Фото").Replace("both", "server") + "," + Row("Работа")));
            var entry = external.External.Single();
            Check(external.DirectionOf("Фото") == DiskChoice.Send, "server alias uses external direction even in All");
            Check(external.ExternalFor("фото/Архив") == entry && external.Includes("фото/Архив"), "external aliases resolve project names case-insensitively for lazy children");
            external.SetDirection("Фото", DiskChoice.Receive);
            Check(entry.Direction == DiskChoice.Receive && Roundtrip(external).External.Single().Direction == DiskChoice.Receive && external.Mode == DiskFoldersMode.All,
                "server alias changes the actual external choice without expanding All");
            external.MarkApplied(); external.ExternalState(entry, "syncing");
            Check(external.Status("Фото") == external.ExternalStatus(entry), "server and external aliases share observed status");
            external.Set("Фото", false);
            Check(!external.Includes("Фото") && !external.IncludesExternal(entry) && !external.Partial("Фото") && external.Mode == DiskFoldersMode.All,
                "unchecking server alias disables external only and overrides All");
            Check(external.Status("Фото") == external.ExternalStatus(entry) && external.Status("Фото").Contains("Перестанет"), "both rows show pending removal");
            external.SetExternal(entry, true);
            Check(external.Includes("Фото") && external.DirectionOf("Фото") == DiskChoice.Receive, "external alias rechecks server alias without losing direction");
            external.SetExternal(entry, false); external.MarkApplied();
            Check(!external.Includes("Фото") && !external.Status("Фото").Contains("Скачивается") && !external.Status("Фото").Contains("Перестанет"),
                "applied external removal remains excluded from All without claiming an imminent stop");
            // An inventory outage / missing applied hash must not hide the handler's confirmed exclusion.
            var withoutInventory = Model("{\"folders\":\"all\",\"external\":[{\"path\":\"D:\\\\Фото\",\"remote\":\"Фото\",\"direction\":\"send\"}]}");
            withoutInventory.Level("", Level(Row("Фото").Replace("both", "server")));
            withoutInventory.SetExternal(withoutInventory.External.Single(), false);
            withoutInventory.MarkApplied(new[] { "Фото" });
            Check(!withoutInventory.Includes("Фото") && withoutInventory.Status("Фото") == "☁ Только на сервере", "actual exclusion wins without a previous inventory or hash");
            var cancelledExternal = Model("{\"folders\":\"all\"}");
            cancelledExternal.AddExternal("D:\\Фото", "Фото", DiskChoice.Send);
            cancelledExternal.SetExternal(cancelledExternal.External.Single(), false);
            cancelledExternal.MarkApplied(new string[0]);
            Check(cancelledExternal.Includes("Фото"), "cancelled external addition does not invent an exclusion");
            external.SetMode(DiskFoldersMode.Selected);
            Check(!Roundtrip(external).Paths.Contains("Фото"), "leaving All cannot implicitly reconnect the excluded external project");
        }
        static void RestartRegressions()
        {
            string home = Path.Combine(Path.GetTempPath(), "folders-restart-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(home);
            try {
                var profile = Profile("{\"folders\":[{\"path\":\"Фото\",\"direction\":\"receive\"},{\"path\":\"Работа\",\"direction\":\"send\"}]}");
                ConfigProfile.Update(home, p => p["disk"] = profile["disk"]);
                Action<DiskFoldersModel, string, string> verify = (model, photo, work) => {
                    model.Level("", Level(Row("Фото", "receive").Replace("\"presence\":\"both\"", "\"presence\":\"server\"") + "," +
                        Row("Работа", "send").Replace("\"presence\":\"both\"", "\"presence\":\"local\"")));
                    Check(model.Status("Фото") == photo && model.Status("Работа") == work, "restart status: " + photo + "/" + work);
                };
                Func<DiskFoldersModel> reopen = () => {
                    var p = ConfigProfile.Load(home);
                    return new DiskFoldersModel(DiskChoice.FromProfile(p), ConfigProfile.AppliedDiskChoice(home, p));
                };
                verify(reopen(), "↓ Будет скачана", "↑ Будет отправлена");
                ConfigProfile.MarkApplied(home, ConfigSections.Disk, ConfigSections.Hash(profile, ConfigSections.Disk));
                verify(reopen(), "⟳ Скачивается", "⟳ Отправляется");
                var confirmed = reopen(); verify(confirmed, "⟳ Скачивается", "⟳ Отправляется"); confirmed.Set("Фото", false);
                Check(confirmed.Status("Фото").Contains("Перестанет"), "confirmed selection stages removal after restart");
                ConfigProfile.Update(home, p => p["disk"] = Profile("{\"folders\":[\"Фото\",\"Работа\"]}")["disk"]);
                verify(reopen(), "↓ Будет скачана", "↑ Будет отправлена");
                ConfigProfile.MarkApplied(home, ConfigSections.Disk, null);
                var unconfirmed = reopen(); verify(unconfirmed, "↓ Будет скачана", "↑ Будет отправлена"); unconfirmed.Set("Фото", false);
                Check(unconfirmed.Status("Фото") == "☁ Только на сервере", "unapplied saved selection does not invent a previous connection");
                ConfigProfile.Update(home, p => p["disk"] = Profile("{\"folders\":\"all\"}")["disk"]);
                ConfigProfile.MarkApplied(home, ConfigSections.Disk, ConfigSections.Hash(ConfigProfile.Load(home), ConfigSections.Disk));
                var diskHome = Path.Combine(home, "disk"); Directory.CreateDirectory(diskHome);
                Files.Atomic(Path.Combine(diskHome, "server.txt"), "peer-a\n");
                Json.Write(Path.Combine(diskHome, "external-exclusions.json"), new { schema = 1, peer = "peer-a", names = new[] { "Фото" } });
                var all = ConfigProfile.Load(home);
                var excluded = new DiskFoldersModel(DiskChoice.FromProfile(all), ConfigProfile.AppliedDiskChoice(home, all), ConfigProfile.DiskExclusions(diskHome));
                excluded.Level("", Level(Row("Фото").Replace("both", "server") + "," + Row("Работа")));
                Check(!excluded.Includes("Фото") && excluded.Status("Фото") == "☁ Только на сервере" && excluded.Includes("Работа"), "restart respects removed external exclusion in All");
                excluded.Set("Фото", true);
                Check(!excluded.ToChoice().All && excluded.Includes("Фото") && excluded.Status("Фото") == "↓ Будет скачана", "explicit reconnect under Disk stays pending until apply");
                Files.Atomic(Path.Combine(diskHome, "server.txt"), "peer-b\n");
                Check(ConfigProfile.DiskExclusions(diskHome).Length == 0, "another server does not inherit external exclusions");
            } finally { Directory.Delete(home, true); }
        }
        internal static void Run()
        {
            ReviewRegressions(); RestartRegressions();
            StatusChecks();
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
            Check(Roundtrip(m).DirectionOf("Фото") == DiskChoice.Receive, "all toggle restores project-specific directions");
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
