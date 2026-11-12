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
        readonly TreeView tree = new TreeView { Dock = DockStyle.Fill, HideSelection = false, CheckBoxes = true, ShowNodeToolTips = true, FullRowSelect = true, ShowLines = false, AccessibleName = "Папки синхронизации" };
        readonly ComboBox direction = DirectionBox();
        readonly Label hint = new Label { Text = "Снятие папки останавливает синхронизацию; файлы на компьютере остаются, их можно удалить вручную.", AutoSize = true },
            localPath = new Label { AutoSize = true },
            project = new Label { Text = "Выберите отмеченную папку", AutoSize = true },
            status = new Label { AutoSize = true, AccessibleName = "Статус выбранной папки" },
            changes = new Label { AutoSize = true, ForeColor = Color.DarkGoldenrod };
        readonly Button open = Button("Открыть папку"), revert = Button("Откатить мои изменения"), reload = Button("Обновить список"), add = Button("Добавить папку с компьютера…");
        readonly Button apply = Button("Применить"), skip = Button("Пропустить");
        readonly FlowLayoutPanel warning;
        readonly ContextMenuStrip menu = new ContextMenuStrip();
        readonly ToolStripMenuItem remove = new ToolStripMenuItem("Перестать синхронизировать");
        readonly Dictionary<string, ToolStripMenuItem> directionMenu = new Dictionary<string, ToolStripMenuItem>();
        readonly DiskFolderTree folders;
        readonly Func<string, object, Task<Dictionary<string, object>>> run;
        readonly Func<Func<Task>, Task> mutate;
        readonly Action<string> log;
        internal Func<Task> Apply, Reload;
        internal Func<Task> Skip;
        internal DiskFoldersModel Model { get; private set; }
        internal bool NeedsExternalInventory { get; private set; }
        internal bool Loaded { get { return folders.Loaded; } }
        bool updating, busy; string diskBase = "";
        static Button Button(string text) { return new Button { Text = text, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Padding = new Padding(8, 3, 8, 3) }; }
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
            // Auto-sized controls, a growing tree and a scrolling body keep the footer reachable at high DPI.
            var layout = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, ColumnCount = 1, Padding = new Padding(0, 0, 8, 0) };
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            AddRow(layout, hint);
            var location = new TableLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, ColumnCount = 2, Margin = new Padding(0) };
            location.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); location.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            localPath.Anchor = AnchorStyles.Left | AnchorStyles.Right; location.Controls.Add(localPath, 0, 0); location.Controls.Add(open, 1, 0);
            AddRow(layout, location); AddRow(layout, all);
            var columns = new TableLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, ColumnCount = 2, Margin = new Padding(0) };
            columns.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 44)); columns.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 56));
            columns.Controls.Add(new Label { Text = "Папка", AutoSize = true }, 0, 0); columns.Controls.Add(new Label { Text = "Статус", AutoSize = true }, 1, 0);
            AddRow(layout, columns);
            AddRow(layout, tree);
            AddRow(layout, Flow(add, reload));
            AddRow(layout, status); AddRow(layout, project); AddRow(layout, direction); direction.Anchor = AnchorStyles.Left | AnchorStyles.Top;
            warning = Flow(changes, revert); AddRow(layout, warning);
            var content = new Panel { Dock = DockStyle.Fill, AutoScroll = true };
            content.Controls.Add(layout);
            var footer = Flow(apply, skip); footer.Dock = DockStyle.Bottom;
            Controls.Add(content); Controls.Add(footer);
            bool fitting = false;
            Action fit = () => {
                if (fitting) return; fitting = true;
                try {
                    int width = Math.Max(80, content.ClientSize.Width - SystemInformation.VerticalScrollBarWidth - layout.Padding.Horizontal - 12);
                    foreach (var label in new[] { hint, project, status, changes }) label.MaximumSize = new Size(width, 0);
                    localPath.MaximumSize = new Size(Math.Max(40, width - open.GetPreferredSize(Size.Empty).Width - 12), 0);
                    direction.Width = Math.Min(width, DiskChoice.Directions.Max(d => TextRenderer.MeasureText(DiskFoldersModel.DirectionText(d), direction.Font).Width) + SystemInformation.VerticalScrollBarWidth + 16);
                    // Font-relative minimum, not an absolute pixel row: scales with the inherited DPI/font.
                    tree.MinimumSize = new Size(0, tree.Font.Height * 10);
                    tree.Height = Math.Max(tree.MinimumSize.Height, content.ClientSize.Height - (layout.Height - tree.Height));
                } finally { fitting = false; }
            };
            content.SizeChanged += (s, e) => fit();
            bool fitPending = false;
            layout.Layout += (s, e) => {
                if (fitting || fitPending || !IsHandleCreated) return;
                fitPending = true;
                BeginInvoke((Action)(() => { fitPending = false; if (!IsDisposed) fit(); }));
            };
            folders = new DiskFolderTree(tree, path => run("DiskTree", new { @base = diskBase, path }), read, isBusy, log) { Model = Model };
            folders.SelectionChanged += () => { NeedsExternalInventory = false; RefreshState(); };
            tree.AfterSelect += (s, e) => RefreshDirection();
            tree.NodeMouseClick += (s, e) => { if (e.Button == MouseButtons.Right) tree.SelectedNode = e.Node; };
            foreach (string value in new[] { DiskChoice.Both, DiskChoice.Receive, DiskChoice.Send }) {
                string d = value; var item = new ToolStripMenuItem(DiskFoldersModel.DirectionText(d));
                item.Click += (s, e) => ChangeDirection(d); menu.Items.Add(item); directionMenu.Add(d, item);
            }
            menu.Items.Add(new ToolStripSeparator()); menu.Items.Add(remove); tree.ContextMenuStrip = menu;
            menu.Opening += (s, e) => {
                if (busy || folders.SelectedPath.Length == 0 && folders.SelectedExternal == null) { e.Cancel = true; return; }
                RefreshDirection(); string d = CurrentDirection();
                foreach (var pair in directionMenu) { pair.Value.Enabled = direction.Enabled; pair.Value.Checked = direction.Enabled && pair.Key == d; }
                remove.Visible = folders.SelectedExternal != null; remove.Enabled = remove.Visible && Model.IncludesExternal(folders.SelectedExternal);
            };
            remove.Click += (s, e) => { if (folders.SelectedExternal != null) { Model.SetExternal(folders.SelectedExternal, false); NeedsExternalInventory = false; RefreshState(); } };
            all.CheckedChanged += (s, e) => {
                if (updating) return;
                NeedsExternalInventory = false; Model.SetMode(all.Checked ? DiskFoldersMode.All : DiskFoldersMode.Selected); RefreshState();
            };
            direction.SelectedIndexChanged += (s, e) => { if (!updating && direction.SelectedIndex >= 0) ChangeDirection(DiskChoice.Directions[direction.SelectedIndex]); };
            add.Click += (s, e) => AddExternal();
            open.Click += (s, e) => {
                try { Process.Start(new ProcessStartInfo { FileName = "explorer.exe", Arguments = "\"" + diskBase + "\"", UseShellExecute = true }); }
                catch (Exception error) { log("Не удалось открыть папку: " + error.Message); }
            };
            apply.Click += async (s, e) => { if (!busy && Apply != null) await Apply(); };
            skip.Click += async (s, e) => { if (!busy && Skip != null) await Skip(); };
            reload.Click += async (s, e) => { if (!busy && Reload != null) await Reload(); };
            revert.Click += async (s, e) => await Revert();
            RefreshState();
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
            diskBase = basePath; localPath.Text = "Disk: " + diskBase; open.Enabled = diskBase.Length > 0;
            Model = new DiskFoldersModel(choice, appliedChoice, excluded); folders.Model = Model; folders.Loaded = false; tree.Nodes.Clear();
            skip.Visible = allowSkip; folders.RefreshExternal(); RefreshState();
        }
        internal void ShowExternalInventory(Dictionary<string, object> data)
        {
            foreach (var item in Json.Array(Json.Get(data, "items"))) {
                var row = Json.Map(item); string path = Json.Str(row, "path");
                var entry = Model.External.FirstOrDefault(e => string.Equals(e.Path, path, StringComparison.OrdinalIgnoreCase));
                if (entry == null && NeedsExternalInventory) { Model.AddExternal(path, Json.Str(row, "remote"), Json.Text(row, "direction", DiskChoice.Both)); entry = Model.External.Last(); }
                if (entry != null && entry.Remote == Json.Str(row, "remote")) Model.ExternalState(entry, Json.Str(row, "state"), Json.Text(row, "direction", DiskChoice.Both));
            }
            NeedsExternalInventory = false; folders.RefreshExternal(); RefreshState();
        }
        internal void AcceptProfile() { NeedsExternalInventory = false; }
        internal void MarkApplied() { Model.MarkApplied(ConfigProfile.DiskExclusions()); folders.RefreshExternal(); RefreshState(); }
        internal void AllowSkip(bool value) { skip.Visible = value; }
        internal void ShowTree(Dictionary<string, object> data) { folders.ShowRoot(data); RefreshState(); }
        internal void SetBusy(bool value) { busy = value; Enabled = !value; if (!value) RefreshState(); }
        void RefreshState()
        {
            updating = true; try { all.Checked = Model.Mode == DiskFoldersMode.All; } finally { updating = false; }
            folders.RefreshChecks(); tree.Enabled = Loaded || Model.ExternalRows.Any();
            // A failed inventory must not turn an unseen server selection into an empty selection.
            apply.Enabled = !busy && (Loaded || Model.Mode != DiskFoldersMode.Selected || Model.ToChoice().Folders.Count > 0 || Model.External.Count > 0);
            RefreshDirection();
        }
        string CurrentDirection() { return folders.SelectedExternal != null ? folders.SelectedExternal.Direction : Model.DirectionOf(folders.SelectedPath); }
        void ChangeDirection(string value)
        {
            try {
                if (folders.SelectedExternal != null) { if (!Model.IncludesExternal(folders.SelectedExternal)) return; folders.SelectedExternal.Direction = value; }
                else {
                    bool wasAll = Model.Mode == DiskFoldersMode.All; Model.SetDirection(folders.SelectedPath, value);
                    if (wasAll && Model.Mode != DiskFoldersMode.All) log("Выбраны текущие папки. Новые папки сервера можно будет отметить в списке.");
                }
                NeedsExternalInventory = false;
            } catch (Exception error) { log(error.Message); }
            RefreshState();
        }
        void RefreshDirection()
        {
            if (folders == null) return;
            string top = DiskChoice.Project(folders.SelectedPath); var entry = folders.SelectedExternal;
            bool chosen = entry != null ? Model.IncludesExternal(entry) : top.Length > 0 && (Model.Includes(top) || Model.Partial(top));
            updating = true; try { direction.SelectedIndex = chosen ? Array.IndexOf(DiskChoice.Directions, CurrentDirection()) : -1; } finally { updating = false; }
            project.Text = chosen ? "Направление для «" + (entry == null ? top : entry.Remote) + "»:" : "Выберите отмеченную папку";
            direction.Enabled = chosen;
            status.Text = (entry == null ? "" : entry.Path + " → " + entry.Remote + ". ") + folders.SelectedStatus;
            status.Visible = status.Text.Length > 0; tree.AccessibleDescription = status.Text;
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
                    if (dialog.ShowDialog(this) == DialogResult.OK) { NeedsExternalInventory = false; folders.RefreshExternal(Model.External.Last()); RefreshState(); }
                }
            }
        }
        async Task Revert()
        {
            if (busy || !Model.CanRevert(folders.SelectedPath)) return;
            string path = DiskChoice.Project(folders.SelectedPath);
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
