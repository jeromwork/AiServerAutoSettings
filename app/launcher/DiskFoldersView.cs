using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace RemoteAgents.Launcher
{
    // Shared by the step after networking, the settings tab and the tray's folder command.
    internal sealed class DiskFoldersView : UserControl
    {
        readonly CheckBox all = new CheckBox { Text = "Все папки сервера, включая новые", AutoSize = true };
        readonly TreeView tree = new TreeView { Dock = DockStyle.Fill, HideSelection = false, CheckBoxes = true, ShowNodeToolTips = true, FullRowSelect = true, ShowLines = false, AccessibleName = "На сервере" };
        readonly TreeView computerTree = new TreeView { Dock = DockStyle.Fill, HideSelection = false, CheckBoxes = true, ShowNodeToolTips = true, FullRowSelect = true, ShowLines = false, AccessibleName = "На этом компьютере" };
        readonly LinkLabel localPath = new LinkLabel { AutoSize = true, AccessibleName = "Путь Disk на этом компьютере" };
        readonly ComboBox direction = DirectionBox();
        readonly Label hint = new Label { Text = "Снятие папки останавливает синхронизацию; файлы на компьютере остаются, их можно удалить вручную.", AutoSize = true },
            project = new Label { Text = "Выберите отмеченную папку", AutoSize = true },
            status = new Label { AutoSize = true, AccessibleName = "Статус выбранной папки" },
            changes = new Label { AutoSize = true, ForeColor = Color.DarkGoldenrod },
            applyState = new Label { AutoSize = true, Visible = false, ForeColor = Color.DarkGoldenrod, Text = WindowModel.FoldersInBackground, AccessibleName = "Состояние синхронизации папок" };
        readonly Button open = Button("Открыть в Проводнике"), revert = Button("Откатить мои изменения"), reload = Button("Обновить список"), add = Button("Выбрать папку на компьютере…");
        readonly Button take = Button("← Забрать на компьютер"), send = Button("Отправить на сервер →"), stopSync = Button("Перестать синхронизировать"), navPane = Button("Показать в Проводнике слева");
        readonly Button apply = Button("Синхронизировать выбранные папки"), skip = Button("Пропустить");
        readonly FlowLayoutPanel warning;
        readonly ContextMenuStrip menu = new ContextMenuStrip();
        readonly ToolStripMenuItem remove = new ToolStripMenuItem("Перестать синхронизировать");
        readonly Dictionary<string, ToolStripMenuItem> directionMenu = new Dictionary<string, ToolStripMenuItem>();
        readonly DiskFolderTree folders, computerFolders;
        DiskFolderTree activeFolders;
        readonly Func<string, object, Task<Dictionary<string, object>>> run;
        readonly Func<Func<Task>, Task> mutate;
        readonly Action<string> log;
        internal Func<Task> Apply, Reload;
        internal Func<Task> Skip;
        internal DiskFoldersModel Model { get; private set; }
        internal bool NeedsExternalInventory { get; private set; }
        internal bool Loaded { get { return folders.Loaded; } }
        bool updating, busy; string diskBase = "";
        static Button Button(string text) { return new Button { Text = text, AccessibleName = text, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Padding = new Padding(8, 3, 8, 3) }; }
        static ComboBox DirectionBox() { return new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 260, AccessibleName = "Направление синхронизации" }; }
        static FlowLayoutPanel Flow(params Control[] controls)
        {
            var flow = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, WrapContents = true, Margin = new Padding(0) };
            flow.Controls.AddRange(controls); return flow;
        }
        internal DiskFoldersView(Func<string, object, Task<Dictionary<string, object>>> run, Func<Func<Task>, Task> read, Func<Func<Task>, Task> mutate, Func<bool> isBusy, Action<string> log)
        {
            this.run = run; this.mutate = mutate; this.log = log;
            Dock = DockStyle.Fill; AutoScaleMode = AutoScaleMode.Inherit; Padding = new Padding(8);
            Model = new DiskFoldersModel(new DiskChoice());
            foreach (string d in DiskChoice.Directions) direction.Items.Add(DiskFoldersModel.DirectionText(d));
            all.AccessibleName = all.Text;
            // Compact: buttons and text rows take their natural height, the two trees share only what is left
            // (Percent rows), so every button stays visible from a small window to a maximized 1080p one, at any DPI.
            var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, Padding = new Padding(0, 0, 8, 0) };
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            AddRow(layout, hint);
            var panes = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, Margin = new Padding(0) };
            panes.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50)); panes.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
            panes.RowCount = 3;
            for (int row = 0; row < 3; row++) panes.RowStyles.Add(row < 2 ? new RowStyle(SizeType.AutoSize) : new RowStyle(SizeType.Percent, 100));
            panes.Controls.Add(new Label { Text = "На этом компьютере", AutoSize = true }, 0, 0);
            panes.Controls.Add(new Label { Text = "На сервере", AutoSize = true }, 1, 0);
            panes.Controls.Add(Flow(localPath, navPane), 0, 1); panes.Controls.Add(all, 1, 1);
            panes.Controls.Add(computerTree, 0, 2); panes.Controls.Add(tree, 1, 2);
            AddRow(layout, panes); layout.RowStyles[layout.RowCount - 1] = new RowStyle(SizeType.Percent, 100); panes.Anchor = AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Top | AnchorStyles.Bottom;
            AddRow(layout, Flow(take, send, stopSync));
            AddRow(layout, Flow(add, open, reload));
            AddRow(layout, status); AddRow(layout, project); AddRow(layout, direction);
            direction.Anchor = AnchorStyles.Left | AnchorStyles.Top;
            warning = Flow(changes, revert); AddRow(layout, warning);
            var content = new Panel { Dock = DockStyle.Fill, AutoScroll = true };
            content.Controls.Add(layout);
            var footer = Flow(apply, skip, applyState);
            var frame = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 2, Margin = new Padding(0) };
            frame.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            frame.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            frame.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            frame.Controls.Add(content, 0, 0); frame.Controls.Add(footer, 0, 1);
            Controls.Add(frame);
            bool fitting = false;
            Action fit = () => {
                if (fitting) return; fitting = true;
                try {
                    int width = Math.Max(Font.Height * 8, content.ClientSize.Width - SystemInformation.VerticalScrollBarWidth - layout.Padding.Horizontal);
                    foreach (var label in new[] { hint, project, status, changes, applyState }) label.MaximumSize = new Size(width, 0);
                    int paneWidth = Math.Max(Font.Height * 4, (width - panes.Margin.Horizontal) / 2 - Font.Height);
                    localPath.MaximumSize = all.MaximumSize = new Size(paneWidth, 0);
                    direction.Width = Math.Min(width, DiskChoice.Directions.Max(d => TextRenderer.MeasureText(DiskFoldersModel.DirectionText(d), direction.Font).Width) + SystemInformation.VerticalScrollBarWidth + Font.Height);
                    // A few rows at least; never a minimum that pushes the buttons out of the window.
                    tree.MinimumSize = computerTree.MinimumSize = new Size(0, Font.Height * 3);
                } finally { fitting = false; }
            };
            content.SizeChanged += (s, e) => fit();
            bool fitPending = false;
            layout.Layout += (s, e) => {
                if (fitting || fitPending || !IsHandleCreated) return;
                fitPending = true;
                BeginInvoke((Action)(() => { fitPending = false; if (!IsDisposed) fit(); }));
            };
            folders = new DiskFolderTree(tree, path => run("DiskTree", new { @base = diskBase, path }), read, isBusy, log) { Model = Model, ShowExternal = false, VisiblePath = path => Model.OnServer(path) };
            computerFolders = new DiskFolderTree(computerTree, path => run("DiskTree", new { @base = diskBase, path }), read, isBusy, log) { Model = Model, VisiblePath = path => Model.OnComputer(path) };
            activeFolders = computerFolders;
            folders.LevelLoaded += computerFolders.RememberLevel;
            computerFolders.LevelLoaded += folders.RememberLevel;
            foreach (var pane in new[] { folders, computerFolders }) {
                var current = pane;
                current.SelectionChanged += () => { NeedsExternalInventory = false; RefreshState(); };
                current.Tree.AfterSelect += (sender, e) => { if (!current.Changing) { activeFolders = current; RefreshDirection(); } };
                current.Tree.Enter += (sender, e) => { activeFolders = current; RefreshDirection(); };
                current.Tree.NodeMouseClick += (sender, e) => { if (e.Button == MouseButtons.Right) { activeFolders = current; current.Tree.SelectedNode = e.Node; } };
                current.Tree.ContextMenuStrip = menu;
                WireDrag(current);
            }
            var takeItem = new ToolStripMenuItem(take.Text); takeItem.Click += (sender, e) => Transfer(folders, true);
            var sendItem = new ToolStripMenuItem(send.Text); sendItem.Click += (sender, e) => Transfer(computerFolders, false);
            var openItem = new ToolStripMenuItem(open.Text); openItem.Click += (sender, e) => OpenExplorer(SelectedLocalPath());
            var syncItem = new ToolStripMenuItem(apply.Text); syncItem.Click += async (sender, e) => { if (Apply != null) await Apply(); };
            var chooseItem = new ToolStripMenuItem(add.Text); chooseItem.Click += (sender, e) => AddExternal();
            menu.Items.Add(takeItem); menu.Items.Add(sendItem); menu.Items.Add(remove); menu.Items.Add(syncItem); menu.Items.Add(chooseItem); menu.Items.Add(openItem); menu.Items.Add(new ToolStripSeparator());
            foreach (string value in new[] { DiskChoice.Both, DiskChoice.Receive, DiskChoice.Send }) {
                string d = value; var item = new ToolStripMenuItem(DiskFoldersModel.DirectionText(d));
                item.Click += (sender, e) => ChangeDirection(d); menu.Items.Add(item); directionMenu.Add(d, item);
            }
            menu.Opening += (sender, e) => {
                activeFolders = menu.SourceControl == tree ? folders : computerFolders;
                if (SelectedPath(activeFolders).Length == 0) { e.Cancel = true; return; }
                RefreshDirection(); string d = CurrentDirection();
                foreach (var pair in directionMenu) { pair.Value.Enabled = direction.Enabled; pair.Value.Checked = direction.Enabled && pair.Key == d; }
                takeItem.Enabled = activeFolders == folders && take.Enabled;
                sendItem.Enabled = activeFolders == computerFolders && send.Enabled;
                remove.Enabled = stopSync.Enabled; openItem.Enabled = open.Enabled; syncItem.Enabled = apply.Enabled;
            };
            remove.Click += (sender, e) => StopSelected();
            take.Click += (sender, e) => Transfer(folders, true);
            send.Click += (sender, e) => Transfer(computerFolders, false);
            stopSync.Click += (sender, e) => StopSelected();
            all.CheckedChanged += (sender, e) => {
                if (updating) return;
                NeedsExternalInventory = false; Model.SetMode(all.Checked ? DiskFoldersMode.All : DiskFoldersMode.Selected); RefreshState();
            };
            direction.SelectedIndexChanged += (sender, e) => { if (!updating && direction.SelectedIndex >= 0) ChangeDirection(DiskChoice.Directions[direction.SelectedIndex]); };
            add.Click += (sender, e) => AddExternal();
            open.Click += (sender, e) => OpenExplorer(SelectedLocalPath());
            localPath.LinkClicked += (sender, e) => OpenExplorer(diskBase);
            navPane.Click += async (sender, e) => { if (!busy) await mutate(async () => {
                var result = await run("DiskNavPane", new { @base = diskBase, install = true });
                navPane.Visible = !Json.Bool(result, "ok");
                log(navPane.Visible ? "Значок Disk не установлен. Подробности в журнале Disk." : "Disk показан слева в Проводнике.");
            }); };
            // Apply only stores the choice and starts the background run (a second click queues the newer choice).
            apply.Click += async (sender, e) => { if (Apply != null) await Apply(); };
            skip.Click += async (sender, e) => { if (Skip != null) await Skip(); };
            reload.Click += async (sender, e) => { if (Reload != null) await Reload(); };
            revert.Click += async (sender, e) => await Revert();
            RefreshState();
        }
        static string SelectedPath(DiskFolderTree pane) { return pane.SelectedExternal == null ? pane.SelectedPath : pane.SelectedExternal.Remote; }
        string SelectedLocalPath()
        {
            var entry = activeFolders.SelectedExternal;
            string path = SelectedPath(activeFolders);
            return entry != null ? entry.Path : path.Length == 0 ? "" : Path.Combine(diskBase, path.Replace('/', Path.DirectorySeparatorChar));
        }
        void OpenExplorer(string path)
        {
            if (path.Length == 0) return;
            try { Process.Start(new ProcessStartInfo { FileName = "explorer.exe", Arguments = Files.Quote(path), UseShellExecute = true }); }
            catch (Exception error) { log("Не удалось открыть папку: " + error.Message); }
        }
        void Transfer(DiskFolderTree source, bool takeToComputer)
        {
            try {
                string path = SelectedPath(source);
                if (takeToComputer) Model.TakeToComputer(path); else Model.SendToServer(path);
                NeedsExternalInventory = false;
            } catch (Exception error) { log(error.Message); }
            RefreshState();
        }
        void StopSelected()
        {
            try { Model.StopSynchronizing(SelectedPath(activeFolders)); NeedsExternalInventory = false; }
            catch (Exception error) { log(error.Message); }
            RefreshState();
        }
        sealed class FolderDrag
        {
            internal DiskFoldersView Owner;
            internal DiskFolderTree Source;
            internal string Path;
        }
        void WireDrag(DiskFolderTree pane)
        {
            pane.Tree.AllowDrop = true;
            pane.Tree.ItemDrag += (sender, e) => {
                if (e.Button != MouseButtons.Left) return;
                pane.Tree.SelectedNode = (TreeNode)e.Item; activeFolders = pane;
                string path = SelectedPath(pane); if (path.Length == 0) return;
                pane.Tree.DoDragDrop(new FolderDrag { Owner = this, Source = pane, Path = path }, DragDropEffects.Copy);
            };
            DragEventHandler over = (sender, e) => {
                var data = e.Data.GetData(typeof(FolderDrag)) as FolderDrag;
                e.Effect = data != null && data.Owner == this && data.Source != pane ? DragDropEffects.Copy : DragDropEffects.None;
            };
            pane.Tree.DragEnter += over; pane.Tree.DragOver += over;
            pane.Tree.DragDrop += (sender, e) => {
                var data = e.Data.GetData(typeof(FolderDrag)) as FolderDrag;
                if (data == null || data.Owner != this || data.Source == pane) return;
                try {
                    if (pane == computerFolders) Model.TakeToComputer(data.Path); else Model.SendToServer(data.Path);
                    NeedsExternalInventory = false;
                } catch (Exception error) { log(error.Message); }
                RefreshState();
            };
        }
        internal async Task RefreshNavPane()
        {
            try { var data = await run("DiskNavPane", new { @base = diskBase }); if (!IsDisposed) navPane.Visible = !Json.Bool(data, "ok"); }
            catch (OperationCanceledException) { throw; }
            catch (Exception error) { log("Не удалось проверить значок Disk: " + error.Message); }
        }
        static void AddRow(TableLayoutPanel panel, Control c)
        {
            int row = panel.RowCount++; panel.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            c.Anchor = AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Top;
            panel.Controls.Add(c, 0, row);
        }
        internal void Initialize(DiskChoice choice, string basePath, bool allowSkip, DiskChoice appliedChoice = null, IEnumerable<string> excluded = null)
        {
            NeedsExternalInventory = !choice.Chosen && choice.External.Count == 0;
            diskBase = basePath; localPath.Text = diskBase; localPath.Enabled = diskBase.Length > 0; navPane.Visible = false;
            Model = new DiskFoldersModel(choice, appliedChoice, excluded);
            foreach (var pane in new[] { folders, computerFolders }) { pane.Model = Model; pane.Reset(); }
            activeFolders = computerFolders;
            skip.Visible = allowSkip; computerFolders.RefreshExternal(); ShowLoading(); RefreshState();
        }
        internal void ShowLoading() { foreach (var pane in new[] { folders, computerFolders }) pane.ShowMessage("Загружаю список папок…"); }
        internal void ShowLoadFailed() { foreach (var pane in new[] { folders, computerFolders }) pane.ShowMessage("Список не загружен — нажмите «Обновить список»"); }
        internal void ShowExternalInventory(Dictionary<string, object> data)
        {
            foreach (var item in Json.Array(Json.Get(data, "items"))) {
                var row = Json.Map(item); string path = Json.Str(row, "path");
                var entry = Model.External.FirstOrDefault(e => string.Equals(e.Path, path, StringComparison.OrdinalIgnoreCase));
                if (entry == null && NeedsExternalInventory) { Model.AddExternal(path, Json.Str(row, "remote"), Json.Text(row, "direction", DiskChoice.Both)); entry = Model.External.Last(); }
                if (entry != null && entry.Remote == Json.Str(row, "remote")) Model.ExternalState(entry, Json.Str(row, "state"), Json.Text(row, "direction", DiskChoice.Both));
            }
            NeedsExternalInventory = false; computerFolders.RefreshExternal(); RefreshState();
        }
        internal void AcceptProfile() { NeedsExternalInventory = false; }
        internal void MarkApplied(DiskChoice applied = null) { Model.MarkApplied(ConfigProfile.DiskExclusions(), applied); computerFolders.RefreshExternal(); RefreshState(); }
        internal void AllowSkip(bool value) { skip.Visible = value; }
        internal void ShowTree(Dictionary<string, object> data) { folders.ShowRoot(data); computerFolders.ShowRoot(data); RefreshState(); }
        // value: a Disk run or a folder action is in progress. The view stays enabled — ticks, selection, expansion,
        // scrolling and «Синхронизировать» react at once; only Revert/«Показать в Проводнике» wait, through mutate.
        internal void SetBusy(bool value) { if (busy == value) return; busy = value; RefreshState(); }
        // Footer line under «Синхронизировать»: the background Disk run or its last failure, honestly.
        internal void ShowDiskState(bool running, string failure)
        {
            applyState.Text = running ? WindowModel.FoldersInBackground : failure ?? "";
            applyState.ForeColor = running ? Color.DarkGoldenrod : Color.Firebrick;
            applyState.Visible = applyState.Text.Length > 0;
        }
        void RefreshState()
        {
            updating = true; try { all.Checked = Model.Mode == DiskFoldersMode.All; } finally { updating = false; }
            updating = true;
            try { folders.RefreshProjection(); computerFolders.RefreshProjection(); }
            finally { updating = false; }
            // A failed inventory must not turn an unseen server selection into an empty selection.
            apply.Enabled = (Loaded || Model.Mode != DiskFoldersMode.Selected || Model.ToChoice().Folders.Count > 0 || Model.External.Count > 0);
            RefreshDirection();
        }
        string CurrentDirection() { return Model.DirectionOf(SelectedPath(activeFolders)); }
        void ChangeDirection(string value)
        {
            try {
                bool wasAll = Model.Mode == DiskFoldersMode.All; Model.SetDirection(SelectedPath(activeFolders), value);
                if (wasAll && Model.Mode != DiskFoldersMode.All) log("Выбраны текущие папки. Новые папки сервера можно будет отметить в списке.");
                NeedsExternalInventory = false;
            } catch (Exception error) { log(error.Message); }
            RefreshState();
        }
        void RefreshDirection()
        {
            if (activeFolders == null || updating) return;
            string path = SelectedPath(activeFolders), top = DiskChoice.Project(path); var entry = activeFolders.SelectedExternal;
            bool chosen = entry != null ? Model.IncludesExternal(entry) : top.Length > 0 && (Model.Includes(top) || Model.Partial(top));
            updating = true; try { direction.SelectedIndex = chosen ? Array.IndexOf(DiskChoice.Directions, CurrentDirection()) : -1; } finally { updating = false; }
            project.Text = chosen ? "Направление для «" + (entry == null ? top : entry.Remote) + "»:" : "Выберите отмеченную папку";
            direction.Enabled = chosen;
            status.Text = (entry == null ? "" : entry.Path + " → " + entry.Remote + ". ") + activeFolders.SelectedStatus;
            status.Visible = status.Text.Length > 0; activeFolders.Tree.AccessibleDescription = status.Text;
            take.Enabled = SelectedPath(folders).Length > 0;
            send.Enabled = SelectedPath(computerFolders).Length > 0;
            stopSync.Enabled = path.Length > 0 && (Model.Includes(path) || Model.Partial(path));
            open.Enabled = Directory.Exists(SelectedLocalPath());
            bool localChanges = entry == null && Model.CanRevert(top);
            changes.Text = localChanges ? "В «" + top + "» есть изменения на компьютере: " + Model.Items[top].LocalChanges + ". Они не отправляются на сервер." : "";
            warning.Visible = localChanges; revert.Enabled = !busy;
        }
        protected override void Dispose(bool disposing) { if (disposing) menu.Dispose(); base.Dispose(disposing); }
        void AddExternal()
        {
            using (var picker = new FolderBrowserDialog { Description = "Выберите папку для синхронизации с сервером", ShowNewFolderButton = false }) {
                if (picker.ShowDialog(this) != DialogResult.OK) return;
                using (var dialog = new Form { Text = "Добавить папку", AutoScaleDimensions = new SizeF(96, 96), AutoScaleMode = AutoScaleMode.Dpi, Font = Font,
                    AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, ClientSize = new Size(540, 240), StartPosition = FormStartPosition.CenterParent, FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false }) {
                    var body = new TableLayoutPanel { AutoSize = true, Dock = DockStyle.Top, Padding = new Padding(12), ColumnCount = 1 };
                    body.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
                    var name = new TextBox { Text = Path.GetFileName(picker.SelectedPath.TrimEnd('\\', '/')), Dock = DockStyle.Fill };
                    var mode = DirectionBox(); foreach (string d in DiskChoice.Directions) mode.Items.Add(DiskFoldersModel.DirectionText(d)); mode.SelectedIndex = 0;
                    var ok = Button("Добавить"); var cancel = Button("Отмена"); cancel.DialogResult = DialogResult.Cancel;
                    AddRow(body, new Label { Text = picker.SelectedPath, AutoSize = true, MaximumSize = new Size(470, 0) });
                    AddRow(body, new Label { Text = "Имя папки на сервере:", AutoSize = true }); AddRow(body, name); AddRow(body, mode); AddRow(body, Flow(ok, cancel));
                    dialog.Controls.Add(body); dialog.AcceptButton = ok; dialog.CancelButton = cancel;
                    ok.Click += (s, e) => {
                        try { Model.AddExternal(picker.SelectedPath, name.Text, DiskChoice.Directions[mode.SelectedIndex]); dialog.DialogResult = DialogResult.OK; }
                        catch (Exception error) { MessageBox.Show(dialog, error.Message, "Папка", MessageBoxButtons.OK, MessageBoxIcon.Information); }
                    };
                    if (dialog.ShowDialog(this) == DialogResult.OK) { NeedsExternalInventory = false; computerFolders.RefreshExternal(Model.External.Last()); activeFolders = computerFolders; RefreshState(); }
                }
            }
        }
        async Task Revert()
        {
            if (busy || !Model.CanRevert(SelectedPath(activeFolders))) return;
            string path = DiskChoice.Project(SelectedPath(activeFolders));
            if (MessageBox.Show(this, "Заменить изменения в «" + path + "» версией с сервера? Ваши местные изменения будут потеряны.", "Откатить мои изменения", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning) != DialogResult.OK) return;
            await mutate(async () => {
                var result = await run("DiskRevert", new { path });
                log(Json.Text(result, "summary", Json.Bool(result, "ok") ? "Изменения отменены" : "Не удалось отменить изменения"));
                if (!Json.Bool(result, "ok")) return;
                // Refresh inventory without changing unsaved choices.
                ShowTree(await run("DiskTree", new { @base = diskBase, path = "" }));
            });
        }
    }
}
