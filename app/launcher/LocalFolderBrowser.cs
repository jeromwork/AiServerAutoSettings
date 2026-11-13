using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace RemoteAgents.Launcher
{
    // «Весь компьютер»: drives and folders of THIS computer, listed lazily on a background thread, no server requests.
    // Choosing a folder goes through DiskFoldersView (the same «Добавить папку» dialog and DiskChoice.External).
    internal sealed class LocalFolderBrowser
    {
        internal readonly TreeView Tree = new TreeView { Dock = DockStyle.Fill, HideSelection = false, CheckBoxes = true, ShowNodeToolTips = true, FullRowSelect = true, ShowLines = false, AccessibleName = "Весь компьютер" };
        internal readonly TabControl Tabs = new TabControl { Dock = DockStyle.Fill, AccessibleName = "На этом компьютере" };
        readonly TabPage diskPage = new TabPage("Папка Disk"), computerPage = new TabPage("Весь компьютер");
        readonly ILocalFileSystem fs;
        readonly Func<DiskFoldersModel> model; readonly Func<string> diskBase; readonly Func<bool> busy;
        readonly string[] system;
        readonly Dictionary<TreeNode, LocalFolderState> states = new Dictionary<TreeNode, LocalFolderState>();
        readonly HashSet<TreeNode> loading = new HashSet<TreeNode>();
        bool loaded, changing; int generation;
        internal event Action<string> SendRequested, StopRequested;
        internal event Action SelectionChanged;
        sealed class LocalDrag { internal LocalFolderBrowser Owner; internal string Path; }
        internal LocalFolderBrowser(TreeView diskTree, TreeView sizeSource, ILocalFileSystem fs, Func<DiskFoldersModel> model, Func<string> diskBase, Func<bool> busy)
        {
            this.fs = fs; this.model = model; this.diskBase = diskBase; this.busy = busy; system = SystemFolders();
            diskPage.Controls.Add(diskTree); computerPage.Controls.Add(Tree);
            Tabs.TabPages.Add(diskPage); Tabs.TabPages.Add(computerPage);
            // The tab pane follows the server tree, whose height DiskFoldersView fits to the window in font units.
            sizeSource.SizeChanged += (s, e) => { Tabs.MinimumSize = sizeSource.MinimumSize; Tabs.Height = sizeSource.Height; };
            Tabs.SelectedIndexChanged += (s, e) => { if (Active) EnsureLoaded(); if (SelectionChanged != null) SelectionChanged(); };
            Tree.DrawMode = TreeViewDrawMode.OwnerDrawText; Tree.DrawNode += DrawNode;
            Tree.Resize += (s, e) => Tree.Invalidate();
            Tree.FontChanged += (s, e) => SetRowHeight(); SetRowHeight();
            Tree.BeforeExpand += (s, e) => Load(e.Node);
            Tree.BeforeCheck += (s, e) => {
                if (changing) return;
                LocalFolderState state;
                if (busy() || !states.TryGetValue(e.Node, out state) || !state.Checked && !state.Choosable) e.Cancel = true;
            };
            Tree.AfterCheck += (s, e) => {
                if (changing) return;
                string path = e.Node.Tag as string; bool value = e.Node.Checked;
                Tree.SelectedNode = e.Node; RefreshChecks();
                // The dialog opens after the checkbox event has finished.
                Tree.BeginInvoke((Action)(() => { var handler = value ? SendRequested : StopRequested; if (handler != null && path != null) handler(path); }));
            };
            Tree.AfterSelect += (s, e) => { if (!changing && SelectionChanged != null) SelectionChanged(); };
            Tree.Enter += (s, e) => { if (SelectionChanged != null) SelectionChanged(); };
            Tree.NodeMouseClick += (s, e) => { if (e.Button == MouseButtons.Right) Tree.SelectedNode = e.Node; };
            Tree.ItemDrag += (s, e) => {
                var node = e.Item as TreeNode; if (busy() || e.Button != MouseButtons.Left || node == null) return;
                Tree.SelectedNode = node; if (!CanSend) return;
                Tree.DoDragDrop(new LocalDrag { Owner = this, Path = SelectedPath }, DragDropEffects.Copy);
            };
        }
        internal static string[] SystemFolders()
        {
            var list = new List<string>();
            foreach (var f in new[] { Environment.SpecialFolder.Windows, Environment.SpecialFolder.ProgramFiles, Environment.SpecialFolder.ProgramFilesX86 }) {
                try { string p = Environment.GetFolderPath(f); if (p.Length > 0) list.Add(p); } catch (Exception) { }
            }
            return list.ToArray();
        }
        internal string[] SystemRoots { get { return system; } }
        internal bool Active { get { return Tabs.SelectedTab == computerPage; } }
        internal string SelectedPath { get { return Tree.SelectedNode == null ? "" : Tree.SelectedNode.Tag as string ?? ""; } }
        internal LocalFolderState SelectedState { get { LocalFolderState s; return Tree.SelectedNode != null && states.TryGetValue(Tree.SelectedNode, out s) ? s : null; } }
        internal bool CanSend { get { var s = SelectedState; return s != null && s.Choosable; } }
        internal string SelectedDescription
        {
            get {
                var s = SelectedState; if (s == null) return "";
                string reason = !s.Choosable && !s.Checked && s.Reason.Length > 0 && s.Reason != s.Status ? ". " + s.Reason : "";
                return SelectedPath + (s.Status.Length > 0 ? ": " + s.Status : "") + reason;
            }
        }
        // Drops from this tree onto the server pane. Subscribed after the pane's own handlers, so this decision wins for LocalDrag.
        internal void AcceptDrops(TreeView target)
        {
            DragEventHandler over = (s, e) => { var d = e.Data.GetData(typeof(LocalDrag)) as LocalDrag; if (d != null && d.Owner == this) e.Effect = busy() ? DragDropEffects.None : DragDropEffects.Copy; };
            target.DragEnter += over; target.DragOver += over;
            target.DragDrop += (s, e) => {
                var d = e.Data.GetData(typeof(LocalDrag)) as LocalDrag;
                if (d != null && d.Owner == this && !busy() && SendRequested != null) SendRequested(d.Path);
            };
        }
        void SetRowHeight() { Tree.ItemHeight = Math.Max(Tree.Font.Height + 8, SystemInformation.MenuCheckSize.Height + 4); }
        internal void Reset()
        {
            generation++; loaded = false; loading.Clear(); states.Clear();
            changing = true; try { Tree.Nodes.Clear(); } finally { changing = false; }
            if (Active) EnsureLoaded();
        }
        internal async void EnsureLoaded()
        {
            if (loaded) return; loaded = true; int current = generation;
            var waiting = new TreeNode("Загрузка…") { ForeColor = SystemColors.GrayText };
            changing = true; try { Tree.Nodes.Clear(); Tree.Nodes.Add(waiting); } finally { changing = false; }
            string profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            LocalListing drives;
            try { drives = await Task.Run(() => LocalFolders.Drives(fs)); }
            catch (Exception error) { drives = new LocalListing { Error = "Список дисков недоступен: " + error.Message }; }
            if (current != generation || Tree.IsDisposed) return;
            var roots = new List<TreeNode>();
            if (profile.Length > 0) roots.Add(Folder("Папка пользователя (" + profile + ")", profile));
            roots.AddRange(drives.Folders.Select(d => Folder(d.Name, d.Path)));
            if (drives.Error.Length > 0) roots.Add(Info(drives.Error));
            changing = true; Tree.BeginUpdate();
            try { Tree.Nodes.Clear(); Tree.Nodes.AddRange(roots.ToArray()); } finally { Tree.EndUpdate(); changing = false; }
            RefreshChecks();
        }
        static TreeNode Folder(string text, string path)
        {
            var node = new TreeNode(text) { Name = text, Tag = path };
            node.Nodes.Add(Info("Загрузка…"));
            return node;
        }
        static TreeNode Info(string text) { return new TreeNode(text) { Name = text, ForeColor = SystemColors.GrayText }; }
        // Expands immediately with «Загрузка…»; the listing runs on a worker thread and replaces it when ready.
        async void Load(TreeNode node)
        {
            string path = node.Tag as string;
            if (path == null || loading.Contains(node) || node.Nodes.Count != 1 || node.Nodes[0].Tag != null || node.Nodes[0].Text != "Загрузка…") return;
            loading.Add(node); int current = generation;
            LocalListing listing;
            try { listing = await Task.Run(() => LocalFolders.List(fs, path)); }
            catch (Exception error) { listing = new LocalListing { Error = "Папка недоступна: " + error.Message }; }
            loading.Remove(node);
            if (current != generation || node.TreeView != Tree) return;
            var children = listing.Folders.Select(f => Folder(f.Name, f.Path)).ToList();
            if (listing.Error.Length > 0) children.Add(Info(listing.Error));
            if (listing.Truncated) children.Add(Info("Показаны первые " + LocalFolders.Limit + " папок"));
            changing = true; Tree.BeginUpdate();
            try { node.Nodes.Clear(); node.Nodes.AddRange(children.ToArray()); } finally { Tree.EndUpdate(); changing = false; }
            RefreshChecks();
        }
        static IEnumerable<TreeNode> All(TreeNodeCollection nodes) { foreach (TreeNode n in nodes) { yield return n; foreach (var c in All(n.Nodes)) yield return c; } }
        // Pure and cheap: states come from the in-memory choice, never from the disk or the server.
        internal void RefreshChecks()
        {
            var m = model(); string root = diskBase();
            bool was = changing; changing = true;
            try {
                states.Clear();
                foreach (var n in All(Tree.Nodes)) {
                    string path = n.Tag as string; if (path == null) continue;
                    var s = LocalFolders.State(m, path, root, system); states[n] = s;
                    n.Checked = s.Checked;
                    n.ForeColor = s.Partial ? Color.DarkOrange : !s.Checked && !s.Choosable ? SystemColors.GrayText : SystemColors.WindowText;
                    n.ToolTipText = path + (s.Status.Length > 0 ? "\n" + s.Status : "") + (!s.Choosable && !s.Checked && s.Reason.Length > 0 && s.Reason != s.Status ? "\n" + s.Reason : "");
                }
                Tree.Invalidate();
            } finally { changing = was; }
        }
        void DrawNode(object sender, DrawTreeNodeEventArgs e)
        {
            bool selected = (e.State & TreeNodeStates.Selected) != 0;
            Color back = selected ? (Tree.Focused ? SystemColors.Highlight : SystemColors.Control) : Tree.BackColor;
            Color fore = selected && Tree.Focused ? SystemColors.HighlightText : e.Node.ForeColor;
            if (fore.IsEmpty) fore = Tree.ForeColor;
            var area = new Rectangle(e.Bounds.Left, e.Bounds.Top, Math.Max(0, Tree.ClientSize.Width - e.Bounds.Left), e.Bounds.Height);
            using (var brush = new SolidBrush(back)) e.Graphics.FillRectangle(brush, area);
            LocalFolderState state; string status = states.TryGetValue(e.Node, out state) ? state.Status : "";
            int split = Math.Max(e.Bounds.Left + Tree.Font.Height * 2, Tree.ClientSize.Width * 50 / 100);
            var flags = TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter;
            var nameArea = new Rectangle(area.Left, area.Top, Math.Max(0, (status.Length > 0 ? split - Tree.Font.Height / 2 : area.Right) - area.Left), area.Height);
            TextRenderer.DrawText(e.Graphics, e.Node.Text, Tree.Font, nameArea, fore, flags);
            if (status.Length > 0) TextRenderer.DrawText(e.Graphics, status, Tree.Font, new Rectangle(split, area.Top, Math.Max(0, area.Right - split - 4), area.Height), selected && Tree.Focused ? fore : SystemColors.GrayText, flags);
            if (selected && Tree.Focused) ControlPaint.DrawFocusRectangle(e.Graphics, area, fore, back);
        }
    }
}
