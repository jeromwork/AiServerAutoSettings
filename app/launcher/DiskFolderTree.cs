using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace RemoteAgents.Launcher
{
    // The lazy Disk tree «только на сервере / только здесь / в обоих», shared by the step-by-step wizard and the config
    // window. Levels come from the DiskTree action on expand; the saved allowlist (DiskTreeSelection) stays authoritative.
    internal sealed class DiskFolderTree
    {
        internal readonly TreeView Tree;
        internal DiskTreeSelection Selection = new DiskTreeSelection(new string[0]);
        internal bool Changing { get; private set; }
        internal bool Loaded;
        // path -> DiskTree result for that level ("" = root). The owner runs the action (and its busy guard).
        readonly Func<string, Task<Dictionary<string, object>>> level;
        readonly Func<Func<Task>, Task> guard; readonly Func<bool> busy; readonly Action<string> append;
        internal event Action SelectionChanged;
        internal DiskFolderTree(TreeView tree, Func<string, Task<Dictionary<string, object>>> level, Func<Func<Task>, Task> guard, Func<bool> busy, Action<string> append)
        {
            Tree = tree; this.level = level; this.guard = guard; this.busy = busy; this.append = append; Tree.CheckBoxes = true;
            Tree.AfterCheck += (a, e) => {
                if (Changing) return; string path = Convert.ToString(e.Node.Tag);
                try { if (path.Length > 0) Selection.Set(path, e.Node.Checked); } catch (Exception error) { append(error.Message); }
                RefreshChecks(); if (SelectionChanged != null) SelectionChanged();
            };
            Tree.BeforeExpand += async (a, e) => {
                if (e.Node.Nodes.Count != 1 || e.Node.Nodes[0].Tag != null) return; e.Cancel = true; if (busy()) return;
                var node = e.Node; await guard(async () => { await LoadChildren(node); node.Expand(); });
            };
        }
        static IEnumerable<TreeNode> All(TreeNodeCollection nodes) { foreach (TreeNode n in nodes) { yield return n; foreach (var child in All(n.Nodes)) yield return child; } }
        void MarkPartial() { foreach (var n in All(Tree.Nodes)) if (n.Tag != null) n.ForeColor = Selection.Partial((string)n.Tag) ? Color.DarkOrange : SystemColors.WindowText; }
        internal void RefreshChecks()
        {
            Changing = true;
            try { foreach (var n in All(Tree.Nodes)) n.Checked = n.Tag != null && Convert.ToString(n.Tag).Length > 0 && Selection.Includes((string)n.Tag); MarkPartial(); }
            finally { Changing = false; }
        }
        void AddLevel(Dictionary<string, object> union, TreeNode parent)
        {
            string prefix = parent == null ? "" : (string)parent.Tag;
            var children = new List<TreeNode>();
            foreach (var r in Json.Array(Json.Get(union, "rows"))) {
                var row = Json.Map(r); string path = Json.Str(row, "path"), presence = Json.Str(row, "presence"); int slash = path.LastIndexOf('/');
                string actualParent = slash < 0 ? "" : path.Substring(0, slash);
                if (actualParent != prefix) throw new InvalidDataException("Сервер вернул другой уровень дерева");
                string mark = presence == "both" ? "в обоих" : presence == "local" ? "только здесь" : "только на сервере";
                if (Json.Bool(union, "truncated")) mark = presence == "both" ? "в обоих" : "обнаружено " + (presence == "local" ? "здесь" : "на сервере") + " (список неполный)";
                var n = new TreeNode((slash < 0 ? path : path.Substring(slash + 1)) + " — " + mark) { Tag = path };
                if (slash < 0 && Json.Str(row, "kind") == "file") { n.Tag = ""; n.Text += " — поместите в папку проекта для синхронизации"; }
                if (Json.Str(row, "kind") == "directory" && Json.Bool(row, "hasChildren")) n.Nodes.Add(new TreeNode("Загрузка при раскрытии…"));
                children.Add(n);
            }
            Selection.Level(prefix, children.Where(n => Convert.ToString(n.Tag).Length > 0).Select(n => (string)n.Tag), Json.Bool(union, "truncated"));
            var target = parent == null ? Tree.Nodes : parent.Nodes;
            target.Clear(); target.AddRange(children.ToArray()); RefreshChecks();
            if (Json.Bool(union, "truncated")) append("Показана часть большой папки. Отметка папки включает скрытые элементы. Для частичного выбора снимите всю папку, затем отметьте нужные видимые элементы.");
        }
        // Root level from a DiskTree result. preset (folders from the config) replaces the saved selection.
        internal void ShowRoot(Dictionary<string, object> data, IEnumerable<string> preset = null)
        {
            Loaded = false;
            Selection = new DiskTreeSelection(preset ?? Json.Strings(Json.Get(Json.Map(Json.Get(data, "selection")), "paths")));
            Changing = true; try { AddLevel(Json.Map(Json.Get(data, "union")), null); Loaded = true; } finally { Changing = false; }
            append("Загружен корень Disk. Дети папки загружаются при раскрытии. Наличие в обоих местах не подтверждает совпадение содержимого.");
        }
        async Task LoadChildren(TreeNode parent)
        {
            var data = await level((string)parent.Tag);
            Changing = true; try { AddLevel(Json.Map(Json.Get(data, "union")), parent); } finally { Changing = false; }
            string rejected = Json.Str(data, "unsupportedName");
            if (rejected.Length > 0) append("Имя «" + rejected + "» не подходит для сервера (допустимы буквы, цифры, пробел, точка, _ и -). Переименуйте папку, чтобы синхронизировать её; показано только локальное содержимое.");
        }
    }
}
