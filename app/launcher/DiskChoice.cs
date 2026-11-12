using System;
using System.Collections.Generic;
using System.Linq;

namespace RemoteAgents.Launcher
{
    // The owner's folder choice: profile «disk» (docs/CONFIG.md). One model for the config engine, the folder window and the tray.
    //   folders: "all" | [ "Проект", "Проект/docs", { "path": "Фото", "direction": "receive" } ]
    //   external: [ { "path": "D:\\Work\\Отчёты", "remote": "Отчёты", "direction": "send" } ]   (folders outside Disk, this computer only)
    // direction belongs to a top-level project on THIS computer: both | send (только отправлять) | receive (только забирать).
    // No «disk» section or no «folders» = not chosen yet: the program shows the folder step instead of guessing.
    internal sealed class DiskFolderChoice { internal string Path = ""; internal string Direction = DiskChoice.Both; }
    internal sealed class DiskExternalChoice { internal string Path = ""; internal string Remote = ""; internal string Direction = DiskChoice.Both; }
    internal sealed class DiskChoice
    {
        internal const string Both = "both", Send = "send", Receive = "receive";
        internal static readonly string[] Directions = { Both, Send, Receive };
        internal bool Chosen;
        internal bool All;
        internal List<DiskFolderChoice> Folders = new List<DiskFolderChoice>();
        internal List<DiskExternalChoice> External = new List<DiskExternalChoice>();

        internal static string Project(string path) { int slash = (path ?? "").IndexOf('/'); return slash < 0 ? path ?? "" : path.Substring(0, slash); }
        static string Direction(string value) { return Directions.Contains(value) ? value : Both; }

        internal static DiskChoice FromProfile(Dictionary<string, object> profile)
        {
            var disk = Json.Map(Json.Get(profile, "disk")); var c = new DiskChoice();
            object folders = Json.Get(disk, "folders");
            c.Chosen = disk.ContainsKey("folders");
            if (folders is string) c.All = string.Equals((string)folders, "all", StringComparison.Ordinal);
            else foreach (object f in Json.Array(folders)) {
                if (f is string) c.Folders.Add(new DiskFolderChoice { Path = (string)f });
                else { var m = Json.Map(f); c.Folders.Add(new DiskFolderChoice { Path = Json.Str(m, "path"), Direction = Direction(Json.Str(m, "direction")) }); }
            }
            foreach (object e in Json.Array(Json.Get(disk, "external"))) {
                var m = Json.Map(e);
                c.External.Add(new DiskExternalChoice { Path = Json.Str(m, "path"), Remote = Json.Str(m, "remote"), Direction = Direction(Json.Str(m, "direction")) });
            }
            return c;
        }

        // Paths for the RemoteDisk allowlist: "." means everything.
        internal string[] Paths { get { return All ? new[] { "." } : Folders.Select(f => f.Path).ToArray(); } }
        internal string DirectionOf(string path)
        {
            string project = Project(path);
            var hit = Folders.FirstOrDefault(f => string.Equals(Project(f.Path), project, StringComparison.OrdinalIgnoreCase) && f.Direction != Both);
            return hit == null ? Both : hit.Direction;
        }

        // A new profile with «disk.folders»/«disk.external» replaced; other «disk» fields (base) are kept. Strings stay strings
        // when the direction is «both», so simple configs stay simple.
        internal Dictionary<string, object> WriteTo(Dictionary<string, object> profile, string diskBase)
        {
            var p = new Dictionary<string, object>(profile); var disk = new Dictionary<string, object>(Json.Map(Json.Get(p, "disk")));
            if (!disk.ContainsKey("base") && !string.IsNullOrEmpty(diskBase)) disk["base"] = diskBase;
            if (All) disk["folders"] = "all";
            else disk["folders"] = Folders.Select(f => f.Direction == Both ? (object)f.Path
                : new Dictionary<string, object> { { "path", f.Path }, { "direction", f.Direction } }).ToArray();
            if (External.Count > 0) disk["external"] = External.Select(e => (object)new Dictionary<string, object> { { "path", e.Path }, { "remote", e.Remote }, { "direction", e.Direction } }).ToArray();
            else disk.Remove("external");
            p["disk"] = disk; return p;
        }
    }
}
