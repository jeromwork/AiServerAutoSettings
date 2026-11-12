using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace RemoteAgents.Launcher
{
    // The same control is hosted by onboarding, the settings tab and the small tray window.
    internal sealed class DiskFoldersView : UserControl
    {
        readonly RadioButton all = new RadioButton { Text = "Все папки сервера", AutoSize = true },
            selected = new RadioButton { Text = "Выбрать папки", AutoSize = true },
            none = new RadioButton { Text = "Не синхронизировать", AutoSize = true };
        readonly TreeView tree = new TreeView { Dock = DockStyle.Fill, HideSelection = false, Height = 180, CheckBoxes = true, ShowNodeToolTips = true };
        readonly ComboBox direction = DirectionBox(), externalDirection = DirectionBox();
        readonly Label project = new Label { Text = "Выберите отмеченную папку", AutoSize = true }, changes = new Label { AutoSize = true, ForeColor = Color.DarkGoldenrod };
        readonly Button revert = Button("Откатить мои изменения"), reload = Button("Обновить список"), add = Button("Добавить папку…"), remove = Button("Перестать синхронизировать");
        readonly Button apply = Button("Применить"), skip = Button("Пропустить");
        readonly ListView external = new ListView { View = View.Details, FullRowSelect = true, HideSelection = false, MultiSelect = false, ShowItemToolTips = true, Height = 104, Dock = DockStyle.Fill };
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
        static ComboBox DirectionBox() { return new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 252 }; }
        static FlowLayoutPanel Flow(params Control[] controls)
        {
            var flow = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, WrapContents = true, Margin = new Padding(0) };
            flow.Controls.AddRange(controls); return flow;
        }
        internal DiskFoldersView(Func<string, object, Task<Dictionary<string, object>>> run, Func<Func<Task>, Task> read, Func<Func<Task>, Task> mutate, Func<bool> isBusy, Action<string> log)
        {
            this.run = run; this.mutate = mutate; this.log = log;
            Dock = DockStyle.Fill; AutoScroll = false; AutoScaleMode = AutoScaleMode.Inherit; Padding = new Padding(8);
            Model = new DiskFoldersModel(new DiskChoice());
            foreach (string d in DiskChoice.Directions) { direction.Items.Add(DiskFoldersModel.DirectionText(d)); externalDirection.Items.Add(DiskFoldersModel.DirectionText(d)); }
            var layout = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, ColumnCount = 1, Padding = new Padding(0, 0, 8, 0) };
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            var quick = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, FlowDirection = FlowDirection.TopDown, WrapContents = false };
            quick.Controls.AddRange(new Control[] { all, selected, none });
            AddRow(layout, quick);
            AddRow(layout, new Label { Text = "Папки на сервере и в Disk", AutoSize = true, Font = new Font(Font, FontStyle.Bold) });
            AddRow(layout, tree, 180);
            AddRow(layout, project); AddRow(layout, Flow(direction, reload));
            AddRow(layout, changes); AddRow(layout, Flow(revert));
            AddRow(layout, new Label { Text = "Папки с этого компьютера", AutoSize = true, Font = new Font(Font, FontStyle.Bold) });
            external.Columns.Add("Папка на компьютере", 260); external.Columns.Add("Имя на сервере", 160); external.Columns.Add("Направление", 220);
            AddRow(layout, external, 104); AddRow(layout, Flow(add, remove)); AddRow(layout, Flow(externalDirection));
            var keepFiles = new Label { Text = "Если перестать синхронизировать папку, файлы останутся на компьютере и на сервере.", AutoSize = true, MaximumSize = new Size(570, 0) };
            AddRow(layout, keepFiles);
            var content = new Panel { Dock = DockStyle.Fill, AutoScroll = true };
            content.Controls.Add(layout);
            var footer = Flow(apply, skip); footer.Dock = DockStyle.Bottom;
            Controls.Add(content); Controls.Add(footer);
            content.SizeChanged += (s, e) => {
                int width = Math.Max(120, content.ClientSize.Width - SystemInformation.VerticalScrollBarWidth - layout.Padding.Horizontal - 12);
                foreach (var label in new[] { project, changes, keepFiles }) label.MaximumSize = new Size(width, 0);
            };
            folders = new DiskFolderTree(tree, path => run("DiskTree", new { @base = diskBase, path }), read, isBusy, log) { Model = Model };
            folders.SelectionChanged += () => { NeedsExternalInventory = false; RefreshState(); };
            tree.AfterSelect += (s, e) => RefreshDirection();
            all.CheckedChanged += (s, e) => ChangeMode(all, DiskFoldersMode.All);
            selected.CheckedChanged += (s, e) => ChangeMode(selected, DiskFoldersMode.Selected);
            none.CheckedChanged += (s, e) => ChangeMode(none, DiskFoldersMode.None);
            direction.SelectedIndexChanged += (s, e) => {
                if (updating || direction.SelectedIndex < 0 || tree.SelectedNode == null) return;
                try {
                    bool wasAll = Model.Mode == DiskFoldersMode.All;
                    Model.SetDirection(Convert.ToString(tree.SelectedNode.Tag), DiskChoice.Directions[direction.SelectedIndex]);
                    if (wasAll && Model.Mode != DiskFoldersMode.All) log("Выбраны текущие папки. Новые папки сервера можно будет отметить в списке.");
                } catch (Exception error) { log(error.Message); }
                RefreshState();
            };
            external.SelectedIndexChanged += (s, e) => RefreshExternalDirection();
            externalDirection.SelectedIndexChanged += (s, e) => {
                if (updating || external.SelectedIndices.Count == 0 || externalDirection.SelectedIndex < 0) return;
                int i = external.SelectedIndices[0]; Model.External[i].Direction = DiskChoice.Directions[externalDirection.SelectedIndex]; RefreshExternal(i);
            };
            add.Click += (s, e) => AddExternal();
            remove.Click += (s, e) => {
                if (external.SelectedIndices.Count == 0) return;
                NeedsExternalInventory = false; Model.External.RemoveAt(external.SelectedIndices[0]); RefreshExternal(); RefreshState();
                log("После «Применить» папка перестанет синхронизироваться. Файлы останутся.");
            };
            apply.Click += async (s, e) => { if (!busy && Apply != null) await Apply(); };
            skip.Click += async (s, e) => { if (!busy && Skip != null) await Skip(); };
            reload.Click += async (s, e) => { if (!busy && Reload != null) await Reload(); };
            revert.Click += async (s, e) => await Revert();
            RefreshState();
        }
        static void AddRow(TableLayoutPanel panel, Control c, int height = 0)
        {
            int row = panel.RowCount++; panel.RowStyles.Add(height == 0 ? new RowStyle(SizeType.AutoSize) : new RowStyle(SizeType.Absolute, height));
            c.Anchor = AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Top;
            panel.Controls.Add(c, 0, row);
        }
        internal void Initialize(DiskChoice choice, string basePath, bool allowSkip)
        {
            NeedsExternalInventory = !choice.Chosen && choice.External.Count == 0;
            diskBase = basePath; Model = new DiskFoldersModel(choice); folders.Model = Model; folders.Loaded = false; tree.Nodes.Clear();
            skip.Visible = allowSkip; RefreshExternal(); RefreshState();
        }
        internal void ShowExternalInventory(Dictionary<string, object> data)
        {
            if (!NeedsExternalInventory) return;
            var inventory = new DiskFoldersModel(new DiskChoice());
            foreach (var item in Json.Array(Json.Get(data, "items"))) {
                var row = Json.Map(item);
                inventory.AddExternal(Json.Str(row, "path"), Json.Str(row, "remote"), Json.Text(row, "direction", DiskChoice.Both));
            }
            Model.External.AddRange(inventory.External);
            NeedsExternalInventory = false; RefreshExternal(); RefreshState();
        }
        internal void AcceptProfile() { NeedsExternalInventory = false; }
        internal void AllowSkip(bool value) { skip.Visible = value; }
        internal void ShowTree(Dictionary<string, object> data)
        { folders.ShowRoot(data); RefreshState(); }
        internal void SetBusy(bool value) { busy = value; Enabled = !value; if (!value) RefreshState(); }
        void ChangeMode(RadioButton button, DiskFoldersMode mode)
        {
            if (updating || !button.Checked) return;
            NeedsExternalInventory = false; Model.SetMode(mode); RefreshExternal(); RefreshState();
        }
        void RefreshState()
        {
            updating = true;
            try { all.Checked = Model.Mode == DiskFoldersMode.All; selected.Checked = Model.Mode == DiskFoldersMode.Selected; none.Checked = Model.Mode == DiskFoldersMode.None; }
            finally { updating = false; }
            folders.RefreshChecks(); tree.Enabled = Loaded;
            // A failed inventory must not turn an unseen server selection into an empty selection.
            apply.Enabled = !busy && (Loaded || Model.Mode != DiskFoldersMode.Selected || Model.ToChoice().Folders.Count > 0 || Model.External.Count > 0);
            RefreshDirection(); RefreshExternalDirection();
        }
        void RefreshDirection()
        {
            string path = tree.SelectedNode == null ? "" : Convert.ToString(tree.SelectedNode.Tag);
            string top = DiskChoice.Project(path); bool chosen = top.Length > 0 && (Model.Includes(top) || Model.Partial(top));
            updating = true;
            try { direction.SelectedIndex = chosen ? Array.IndexOf(DiskChoice.Directions, Model.DirectionOf(top)) : -1; }
            finally { updating = false; }
            project.Text = chosen ? "Направление для «" + top + "»:" : "Выберите отмеченную папку";
            direction.Enabled = chosen;
            DiskFolderInfo info; bool localChanges = Model.Items.TryGetValue(top, out info) && info.LocalChanges > 0;
            changes.Text = localChanges ? "В «" + top + "» есть изменения на компьютере: " + info.LocalChanges + ". Они не отправляются на сервер." : "";
            changes.Visible = localChanges; revert.Visible = localChanges; revert.Enabled = !busy;
        }
        void RefreshExternal(int selectedIndex = -1)
        {
            updating = true;
            try {
                external.Items.Clear();
                foreach (var e in Model.External) external.Items.Add(new ListViewItem(new[] { e.Path, e.Remote, DiskFoldersModel.DirectionText(e.Direction) }) { ToolTipText = e.Path + " → " + e.Remote + " — " + DiskFoldersModel.DirectionText(e.Direction) });
                if (selectedIndex >= 0 && selectedIndex < external.Items.Count) external.Items[selectedIndex].Selected = true;
            } finally { updating = false; }
            RefreshExternalDirection();
        }
        void RefreshExternalDirection()
        {
            if (updating) return;
            bool chosen = external.SelectedIndices.Count > 0;
            remove.Enabled = chosen; externalDirection.Enabled = chosen;
            updating = true;
            try { externalDirection.SelectedIndex = chosen ? Array.IndexOf(DiskChoice.Directions, Model.External[external.SelectedIndices[0]].Direction) : -1; }
            finally { updating = false; }
        }
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
                    if (dialog.ShowDialog(this) == DialogResult.OK) { NeedsExternalInventory = false; RefreshExternal(Model.External.Count - 1); RefreshState(); }
                }
            }
        }
        async Task Revert()
        {
            if (busy || tree.SelectedNode == null) return;
            string path = DiskChoice.Project(Convert.ToString(tree.SelectedNode.Tag));
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
