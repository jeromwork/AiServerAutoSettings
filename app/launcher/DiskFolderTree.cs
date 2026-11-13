using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace RemoteAgents.Launcher
{
    // A lazy pane with a separately painted status column. The saved allowlist remains authoritative.
    internal sealed class DiskFolderTree
    {
        internal readonly TreeView Tree;
        internal DiskTreeSelection Selection = new DiskTreeSelection(new string[0]);
        internal bool Changing { get; private set; }
        internal bool Loaded;
        internal bool ShowExternal = true;
        internal Func<string, bool> VisiblePath;
        readonly Dictionary<string, Dictionary<string, object>> levels = new Dictionary<string, Dictionary<string, object>>(StringComparer.Ordinal);
        internal event Action<string, Dictionary<string, object>> LevelLoaded;
        internal DiskFoldersModel Model;
        readonly Func<string, Task<Dictionary<string, object>>> level;
        readonly Func<Func<Task>, Task> guard; readonly Func<bool> busy; readonly Action<string> append;
        readonly Dictionary<TreeNode, DiskFolderInfo> rows = new Dictionary<TreeNode, DiskFolderInfo>();
        readonly Dictionary<TreeNode, string> statuses = new Dictionary<TreeNode, string>();
        TreeNode externalRoot;
        internal event Action SelectionChanged;
        internal DiskFolderTree(TreeView tree, Func<string, Task<Dictionary<string, object>>> level, Func<Func<Task>, Task> guard, Func<bool> busy, Action<string> append)
        {
            Tree = tree; this.level = level; this.guard = guard; this.busy = busy; this.append = append;
            Tree.CheckBoxes = true; Tree.DrawMode = TreeViewDrawMode.OwnerDrawText;
            Tree.DrawNode += DrawNode;
            Tree.Resize += (s, e) => Tree.Invalidate();
            Tree.FontChanged += (s, e) => SetRowHeight(); SetRowHeight();
            Tree.BeforeCheck += (s, e) => { if (!Changing && (busy() || e.Node.Tag == null || e.Node.Tag is string && ((string)e.Node.Tag).Length == 0)) e.Cancel = true; };
            Tree.AfterCheck += (a, e) => {
                if (Changing) return;
                try {
                    var entry = e.Node.Tag as DiskExternalChoice;
                    if (entry != null) Model.SetExternal(entry, e.Node.Checked);
                    else {
                        string path = e.Node.Tag as string;
                        if (!string.IsNullOrEmpty(path)) { if (Model == null) Selection.Set(path, e.Node.Checked); else Model.Set(path, e.Node.Checked); }
                    }
                } catch (Exception error) { append(error.Message); }
                RefreshChecks(); if (SelectionChanged != null) SelectionChanged();
            };
            Tree.BeforeExpand += async (a, e) => {
                if (!(e.Node.Tag is string) || e.Node.Nodes.Count != 1 || e.Node.Nodes[0].Tag != null) return;
                e.Cancel = true; if (busy()) return;
                var node = e.Node; await guard(async () => { await LoadChildren(node); node.Expand(); });
            };
        }
        void SetRowHeight() { Tree.ItemHeight = Math.Max(Tree.Font.Height + 8, SystemInformation.MenuCheckSize.Height + 4); }
        void DrawNode(object sender, DrawTreeNodeEventArgs e)
        {
            bool selected = (e.State & TreeNodeStates.Selected) != 0;
            Color back = selected ? (Tree.Focused ? SystemColors.Highlight : SystemColors.Control) : Tree.BackColor;
            Color fore = selected && Tree.Focused ? SystemColors.HighlightText : e.Node.ForeColor;
            if (fore.IsEmpty) fore = Tree.ForeColor;
            int split = Math.Max(e.Bounds.Left + 24, Tree.ClientSize.Width * 44 / 100);
            var area = new Rectangle(e.Bounds.Left, e.Bounds.Top, Math.Max(0, Tree.ClientSize.Width - e.Bounds.Left), e.Bounds.Height);
            using (var brush = new SolidBrush(back)) e.Graphics.FillRectangle(brush, area);
            string status; bool hasStatus = statuses.TryGetValue(e.Node, out status);
            var nameArea = new Rectangle(area.Left, area.Top, Math.Max(0, (hasStatus ? split - 8 : area.Right) - area.Left), area.Height);
            var flags = TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter;
            TextRenderer.DrawText(e.Graphics, e.Node.Text, Tree.Font, nameArea, fore, flags);
            if (hasStatus) {
                var statusArea = new Rectangle(split, area.Top, Math.Max(0, area.Right - split - 4), area.Height);
                TextRenderer.DrawText(e.Graphics, status, Tree.Font, statusArea, selected && Tree.Focused ? fore : Tree.ForeColor, flags);
            }
            if (selected && Tree.Focused) ControlPaint.DrawFocusRectangle(e.Graphics, area, fore, back);
        }
        static IEnumerable<TreeNode> All(TreeNodeCollection nodes) { foreach (TreeNode n in nodes) { yield return n; foreach (var child in All(n.Nodes)) yield return child; } }
        internal string SelectedPath { get { return Tree.SelectedNode == null ? "" : Tree.SelectedNode.Tag as string ?? ""; } }
        internal DiskExternalChoice SelectedExternal { get { return Tree.SelectedNode == null ? null : Tree.SelectedNode.Tag as DiskExternalChoice ?? (Model == null ? null : Model.ExternalFor(SelectedPath)); } }
        internal string SelectedStatus { get { string value; return Tree.SelectedNode != null && statuses.TryGetValue(Tree.SelectedNode, out value) ? value : ""; } }
        internal void RefreshChecks()
        {
            bool wasChanging = Changing; Changing = true;
            try {
                statuses.Clear();
                foreach (var n in All(Tree.Nodes)) {
                    var entry = n.Tag as DiskExternalChoice;
                    if (entry != null) {
                        n.Checked = Model.IncludesExternal(entry);
                        n.Text = n.Name + (n.Checked && entry.Direction != DiskChoice.Both ? "  " + DiskFoldersModel.DirectionHint(entry.Direction) : "");
                        statuses[n] = Model.ExternalStatus(entry);
                        n.ToolTipText = entry.Path + " → " + entry.Remote + "\n" + statuses[n];
                        continue;
                    }
                    string path = n.Tag as string; DiskFolderInfo info;
                    if (string.IsNullOrEmpty(path) || !rows.TryGetValue(n, out info)) { n.Checked = false; continue; }
                    bool partial = Model == null ? Selection.Partial(path) : Model.Partial(path);
                    n.Checked = Model == null ? Selection.Includes(path) : Model.Includes(path);
                    string d = Model == null ? DiskChoice.Both : Model.DirectionOf(path);
                    n.Text = n.Name + ((n.Checked || partial) && d != DiskChoice.Both ? "  " + DiskFoldersModel.DirectionHint(d) : "");
                    statuses[n] = Model == null ? DiskFoldersModel.FolderStatus(n.Checked, info.Presence, false, d, info.Truncated, false) : Model.Status(path);
                    if (partial) statuses[n] = "Часть вложенных папок отмечена. " + statuses[n];
                    n.ForeColor = partial ? Color.DarkOrange : SystemColors.WindowText;
                    n.ToolTipText = path + "\n" + statuses[n] + (d == DiskChoice.Both ? "" : "\n" + DiskFoldersModel.DirectionText(d));
                }
                Tree.Invalidate();
            } finally { Changing = wasChanging; }
        }
        internal void RefreshExternal(DiskExternalChoice select = null)
        {
            if (Model == null) { RefreshChecks(); return; }
            bool wasChanging = Changing; Changing = true;
            try {
                var selected = select ?? SelectedExternal;
                if (externalRoot != null) externalRoot.Remove(); externalRoot = null;
                var entries = ShowExternal ? Model.ExternalRows.ToArray() : new DiskExternalChoice[0];
                if (entries.Length > 0) {
                    externalRoot = new TreeNode("С этого компьютера"); Tree.Nodes.Add(externalRoot);
                    foreach (var entry in entries) {
                        var node = new TreeNode(entry.Remote) { Name = entry.Remote, Tag = entry };
                        externalRoot.Nodes.Add(node); if (entry == selected) Tree.SelectedNode = node;
                    }
                    externalRoot.Expand();
                }
                RefreshChecks();
            } finally { Changing = wasChanging; }
        }
        void AddLevel(Dictionary<string, object> union, TreeNode parent, bool observe = true)
        {
            string prefix = parent == null ? "" : (string)parent.Tag;
            var children = new List<TreeNode>();
            if (observe) { levels[prefix] = union; if (Model != null) Model.Level(prefix, union); }
            foreach (var r in Json.Array(Json.Get(union, "rows"))) {
                var row = Json.Map(r); string path = Json.Str(row, "path"); int slash = path.LastIndexOf('/');
                if ((slash < 0 ? "" : path.Substring(0, slash)) != prefix) throw new InvalidDataException("Сервер вернул другой уровень дерева");
                if (VisiblePath != null && !VisiblePath(path)) continue;
                var n = new TreeNode(slash < 0 ? path : path.Substring(slash + 1)) { Tag = path };
                if (slash < 0 && Json.Str(row, "kind") == "file") { n.Tag = ""; n.Text += " — поместите в папку проекта для синхронизации"; }
                n.Name = n.Text;
                rows[n] = new DiskFolderInfo { Path = path, Presence = Json.Str(row, "presence"), Truncated = Json.Bool(union, "truncated") };
                if (Json.Str(row, "kind") == "directory" && Json.Bool(row, "hasChildren")) n.Nodes.Add(new TreeNode("Загрузка при раскрытии…"));
                children.Add(n);
            }
            Selection.Level(prefix, children.Where(n => n.Tag is string && ((string)n.Tag).Length > 0).Select(n => (string)n.Tag), Json.Bool(union, "truncated"));
            var target = parent == null ? Tree.Nodes : parent.Nodes;
            target.Clear(); target.AddRange(children.ToArray());
            if (parent == null) RefreshExternal(); else if (observe) RefreshChecks();
            if (observe && Json.Bool(union, "truncated")) append("Показана часть большой папки. Отметка папки включает скрытые элементы. Для частичного выбора снимите всю папку, затем отметьте нужные видимые элементы.");
        }
        internal void Reset()
        {
            Loaded = false; levels.Clear(); rows.Clear(); statuses.Clear(); externalRoot = null;
            Changing = true; try { Tree.Nodes.Clear(); } finally { Changing = false; }
        }
        internal void ShowRoot(Dictionary<string, object> data, IEnumerable<string> preset = null)
        {
            Loaded = false; levels.Clear(); rows.Clear(); statuses.Clear(); externalRoot = null;
            if (Model == null) Selection = new DiskTreeSelection(preset ?? Json.Strings(Json.Get(Json.Map(Json.Get(data, "selection")), "paths")));
            Changing = true; try { AddLevel(Json.Map(Json.Get(data, "union")), null); Loaded = true; } finally { Changing = false; }
            append("Папки загружены. Вложенные папки появятся при раскрытии. Наличие в обоих местах ещё не означает, что передача завершена.");
        }
        internal void RememberLevel(string path, Dictionary<string, object> union)
        { levels[path] = union; RefreshProjection(); }
        internal void RefreshProjection()
        {
            Dictionary<string, object> root;
            if (!levels.TryGetValue("", out root)) { RefreshExternal(); return; }
            string selected = SelectedPath; var entry = SelectedExternal;
            var expanded = new HashSet<string>(All(Tree.Nodes).Where(n => n.IsExpanded && n.Tag is string).Select(n => (string)n.Tag));
            bool wasChanging = Changing; Changing = true; Tree.BeginUpdate();
            try {
                rows.Clear(); statuses.Clear(); externalRoot = null;
                AddLevel(root, null, false);
                Action<TreeNode> fill = null;
                fill = node => {
                    string path = node.Tag as string; Dictionary<string, object> data;
                    // Root files carry an empty tag; only real folders get a cached level, otherwise the root would nest into itself.
                    if (!string.IsNullOrEmpty(path) && levels.TryGetValue(path, out data)) {
                        AddLevel(data, node, false);
                    }
                    foreach (TreeNode child in node.Nodes) fill(child);
                    if (path != null && expanded.Contains(path)) node.Expand();
                    if (!string.IsNullOrEmpty(path) && path == selected || entry != null && node.Tag == entry) Tree.SelectedNode = node;
                };
                foreach (TreeNode node in Tree.Nodes) fill(node);
                RefreshChecks();
            } finally { Tree.EndUpdate(); Changing = wasChanging; }
        }
        async Task LoadChildren(TreeNode parent)
        {
            var data = await level((string)parent.Tag);
            Changing = true; try { AddLevel(Json.Map(Json.Get(data, "union")), parent); } finally { Changing = false; }
            // A projection rebuilt during the request detached this node: rebuild so the visible copy gets the loaded level.
            if (parent.TreeView == null) RefreshProjection();
            if (LevelLoaded != null) LevelLoaded((string)parent.Tag, Json.Map(Json.Get(data, "union")));
            string rejected = Json.Str(data, "unsupportedName");
            if (rejected.Length > 0) append("Имя «" + rejected + "» не подходит для сервера (допустимы буквы, цифры, пробел, точка, _ и -). Переименуйте папку, чтобы синхронизировать её; показано только локальное содержимое.");
        }
    }
}
