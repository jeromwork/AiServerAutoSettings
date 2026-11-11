using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace RemoteAgents.Launcher
{
    // The saved allowlist is authoritative even when none of its descendants has been loaded.
    internal sealed class DiskTreeSelection
    {
        readonly HashSet<string> paths;
        readonly Dictionary<string, string[]> levels = new Dictionary<string, string[]>(StringComparer.Ordinal);
        readonly HashSet<string> truncated = new HashSet<string>(StringComparer.Ordinal);
        internal DiskTreeSelection(IEnumerable<string> selected) { paths = new HashSet<string>(selected, StringComparer.Ordinal); }
        static bool Within(string path, string parent) { return path == parent || path.StartsWith(parent + "/", StringComparison.Ordinal); }
        internal bool Includes(string path) { return paths.Any(p => Within(path, p)); }
        internal bool Partial(string path) { return !Includes(path) && paths.Any(p => Within(p, path)); }
        internal string[] Paths { get { return paths.Where(p => !paths.Any(a => a != p && Within(p, a))).OrderBy(p => p, StringComparer.Ordinal).ToArray(); } }
        internal void Level(string parent, IEnumerable<string> children, bool incomplete)
        { levels[parent] = children.ToArray(); if (incomplete) truncated.Add(parent); else truncated.Remove(parent); }
        internal void Set(string path, bool value)
        {
            if (value) {
                if (Includes(path)) return;
                paths.RemoveWhere(p => Within(p, path)); paths.Add(path); return;
            }
            var replacement = new List<string>();
            foreach (string ancestor in paths.Where(p => p != path && Within(path, p))) {
                string current = ancestor;
                while (current != path) {
                    string[] children;
                    if (truncated.Contains(current) || !levels.TryGetValue(current, out children))
                        throw new IOException("Список папки неполный. Снимите отметку со всей папки, затем отметьте нужные видимые элементы. Скрытые элементы останутся исключены.");
                    string next = children.FirstOrDefault(p => Within(path, p));
                    if (next == null) throw new IOException("Путь отсутствует в загруженном уровне; обновите дерево");
                    replacement.AddRange(children.Where(p => p != next)); current = next;
                }
            }
            paths.RemoveWhere(p => Within(p, path) || Within(path, p));
            foreach (string p in replacement) paths.Add(p);
        }
    }
}
