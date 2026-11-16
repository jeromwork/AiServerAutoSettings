using System;
using System.Collections.Generic;
using System.Linq;

namespace RemoteAgents.Launcher
{
    // One server folder to accept right away. Id is the name of a top-level folder in ~/Disk on the server; Path is an
    // absolute Windows path, or "" (then the folder lands in <Disk root>\<Id>). Source is what the config wrote: the id,
    // or the path of an earlier format. Validation and the duplicate check look at it.
    internal sealed class DiskFolder { internal string Id = "", Path = "", Source = ""; }

    // The folders a config asks to accept at installation: profile «disk», docs/CONFIG.md.
    //   "disk": { "base": "C:\\Disk", "folders": [ { "id": "Проект" }, { "id": "Фото", "path": "C:\\Disk\\Фото" } ] }
    // Without «folders» (or with an empty list) nothing is accepted: the server only offers its folders and the person
    // accepts them in Syncthing Tray. Earlier formats are still read and never rejected: "all", "Проект", "Проект/docs",
    // { "path": "Фото", "direction": "receive" } and «external». What no longer exists (all, directions, folders outside
    // Disk, nested paths) is dropped and described in Warnings, in words for the journal.
    internal sealed class DiskChoice
    {
        // As written, one entry per element; earlier formats are mapped to their top-level folder.
        internal readonly List<DiskFolder> Entries = new List<DiskFolder>();
        // Ignored parts of earlier formats.
        internal readonly List<string> Warnings = new List<string>();

        // The folders to accept: one per server folder (the first spelling wins), in the order of the config.
        internal List<DiskFolder> Folders
        {
            get { var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase); return Entries.Where(e => e.Id.Length > 0 && seen.Add(e.Id)).ToList(); }
        }

        // «Проект/docs» -> «Проект»: the server shares top-level folders only.
        internal static string TopLevel(string path) { int slash = (path ?? "").IndexOf('/'); return slash < 0 ? path ?? "" : path.Substring(0, slash); }

        internal static DiskChoice FromProfile(Dictionary<string, object> profile)
        {
            var disk = Json.Map(Json.Get(profile, "disk")); var c = new DiskChoice();
            object folders = Json.Get(disk, "folders");
            if (folders is string)
                c.Warnings.Add("в конфиге disk.folders = «" + folders + "» больше не действует: сервер сам предлагает все свои папки, примите нужные в Syncthing Tray");
            else foreach (object f in Json.Array(folders)) {
                if (f is string) c.Earlier((string)f, "");
                else {
                    var m = Json.Map(f);
                    if (m.ContainsKey("id")) c.Entries.Add(new DiskFolder { Id = Json.Str(m, "id"), Path = Json.Str(m, "path"), Source = Json.Str(m, "id") });
                    else c.Earlier(Json.Str(m, "path"), Json.Str(m, "direction"));
                }
            }
            foreach (object e in Json.Array(Json.Get(disk, "external"))) {
                var m = Json.Map(e);
                c.Warnings.Add("disk.external не поддерживается: папку «" + Json.Str(m, "path") + "» (на сервере «" + Json.Str(m, "remote") + "») разместите непосредственно внутри базы Диска и подключите явно");
            }
            return c;
        }

        internal static bool DirectWindowsChild(string path, string root)
        {
            path = path.Replace('/', '\\').TrimEnd('\\'); root = root.Replace('/', '\\').TrimEnd('\\');
            int slash = path.LastIndexOf('\\');
            return slash >= 0 && string.Equals(path.Substring(0, slash), root, StringComparison.OrdinalIgnoreCase);
        }
        void Earlier(string path, string direction)
        {
            string id = TopLevel(path);
            Entries.Add(new DiskFolder { Id = id, Source = path });
            if (path.Contains("/")) AddWarning("путь «" + path + "» из disk.folders заменён папкой «" + id + "»: принимается вся папка верхнего уровня");
            if (direction.Length > 0 && direction != "both") AddWarning("направление «" + direction + "» папки «" + id + "» из disk.folders больше не действует: настройте его в Syncthing Tray");
        }
        void AddWarning(string text) { if (!Warnings.Contains(text)) Warnings.Add(text); }
    }
}
