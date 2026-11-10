using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace RemoteAgents.Launcher
{
    // WinForms stays in the EXE. Modules only configure Happier/Syncthing over the saved SSH profile.
    internal static class AccountDiskSetup
    {
        static string Run(string home, string bundle, string script, params string[] args)
        {
            string output = Path.Combine(home, "state", "setup-" + Guid.NewGuid().ToString("N") + ".tmp");
            Directory.CreateDirectory(Path.GetDirectoryName(output));
            try {
                var argv = new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", Path.Combine(bundle, script), "-Home", home }.Concat(args).ToArray();
                if (External.Run(Files.Executable("powershell.exe"), argv, bundle, output, script.StartsWith("accounts/",StringComparison.Ordinal) ? 1300000 : 180000, 4 * 1024 * 1024, CancellationToken.None) != 0)
                    throw new IOException("Операция не подтверждена. Проверьте SSH, ключ аккаунта и состояние синхронизации. Файлы сохранены; повторите после проверки.");
                return Files.LF(External.ReadPowerShellOutput(output));
            } finally { if (File.Exists(output)) File.Delete(output); }
        }
        static string Wait(Func<string> action, string text)
        {
            using (var form = new Form { Text = "RemoteAgents", Width = 600, Height = 160, StartPosition = FormStartPosition.CenterScreen, ControlBox = false })
            using (var timer = new System.Windows.Forms.Timer { Interval = 100 }) {
                form.Controls.Add(new Label { Dock = DockStyle.Fill, Padding = new Padding(18), Text = text });
                var task = Task.Run(action); timer.Tick += (s,e) => { if (task.IsCompleted) form.Close(); }; timer.Start(); form.ShowDialog();
                return task.GetAwaiter().GetResult();
            }
        }
        static void SaveKey(string home, string key)
        {
            string directory = Path.Combine(home, "secrets"); Directory.CreateDirectory(directory);
            var sid = WindowsIdentity.GetCurrent().User;
            var acl = new DirectorySecurity(); acl.SetAccessRuleProtection(true, false);
            acl.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            Directory.SetAccessControl(directory, acl);
            string current = Path.Combine(directory, "happier-account.key");
            if (File.Exists(current)) Files.Atomic(Path.Combine(directory, "happier-backup-" + Guid.NewGuid().ToString("N") + ".key"), File.ReadAllText(current));
            Files.Atomic(current, key.Trim() + "\n");
        }
        public static bool ChooseAccount(string home)
        {
            var settings = Json.Map(Json.Get(new Configuration(home).Data,"happier"));
            using (var form = new Form { Text = "RemoteAgents — аккаунт Happier", Width = 640, Height = 460, StartPosition = FormStartPosition.CenterScreen, MinimizeBox = false, MaximizeBox = false }) {
                var existing = new RadioButton { Left = 20, Top = 20, Width = 590, Text = "Подключиться к существующему аккаунту Happier", Checked = true };
                var create = new RadioButton { Left = 20, Top = 55, Width = 590, Text = "Создать новый аккаунт Happier" };
                var key = new TextBox { Left = 20, Top = 120, Width = 580, UseSystemPasswordChar = true };
                form.Controls.Add(existing); form.Controls.Add(create);
                form.Controls.Add(new Label { Left = 20, Top = 95, Width = 580, Text = "Секретный ключ (из резервной копии Happier)" }); form.Controls.Add(key);
                var server = new TextBox {Left=140,Top=165,Width=460,Text=Json.Text(settings,"serverUrl","https://api.happier.dev")};
                var web = new TextBox {Left=140,Top=205,Width=460,Text=Json.Text(settings,"webappUrl","https://cloud.happier.dev")};
                form.Controls.Add(new Label {Left=20,Top=168,Width=115,Text="Happier API"});form.Controls.Add(server);
                form.Controls.Add(new Label {Left=20,Top=208,Width=115,Text="Happier Web"});form.Controls.Add(web);
                form.Controls.Add(new Label { Left = 20, Top = 245, Width = 580, Height = 80, Text = "Для телефона и браузера используйте этот же ключ в «Restore with Secret Key». Новый ключ сохраняется в RemoteAgents\\secrets\\happier-account.key — сохраните резервную копию. Подписки агентов общие для аккаунтов на сервере." });
                create.CheckedChanged += (s,e) => { key.Enabled = !create.Checked; };
                var cancel = new Button { Left = 320, Top = 365, Width = 130, Text = "Позже", DialogResult = DialogResult.Cancel };
                var next = new Button { Left = 465, Top = 365, Width = 135, Text = "Подключить" };
                next.Click += (s,e) => {
                    if (existing.Checked && key.Text.Trim().Length == 0) return;
                    string value = key.Text;
                    if (create.Checked) { var bytes = new byte[32]; using (var rng = RandomNumberGenerator.Create()) rng.GetBytes(bytes); value = Convert.ToBase64String(bytes).TrimEnd('=').Replace('+','-').Replace('/','_'); }
                    Uri apiUri, webUri;
                    if(!Uri.TryCreate(server.Text.Trim(),UriKind.Absolute,out apiUri) || !Uri.TryCreate(web.Text.Trim(),UriKind.Absolute,out webUri) || apiUri.Scheme!="https" || webUri.Scheme!="https" || apiUri.UserInfo.Length>0 || webUri.UserInfo.Length>0 || apiUri.AbsolutePath!="/" || webUri.AbsolutePath!="/" || apiUri.Query.Length>0 || webUri.Query.Length>0 || apiUri.Fragment.Length>0 || webUri.Fragment.Length>0) {MessageBox.Show("Укажите HTTPS-адреса API и Web Happier без пути и пароля.","RemoteAgents");return;}
                    try { SaveKey(home, value); new Configuration(home).SetHappier(apiUri.GetLeftPart(UriPartial.Authority),webUri.GetLeftPart(UriPartial.Authority)); }
                    catch {MessageBox.Show("Не удалось безопасно сохранить ключ и настройки.","RemoteAgents");return;}
                    key.Clear(); form.DialogResult = DialogResult.OK; form.Close();
                };
                form.Controls.Add(cancel); form.Controls.Add(next); form.AcceptButton = next; form.CancelButton = cancel;
                return form.ShowDialog() == DialogResult.OK;
            }
        }
        public static void Account(string home, string bundle, bool choose)
        {
            bool interactive=choose || !File.Exists(Path.Combine(home,"secrets","happier-account.key"));
            if ((choose || !File.Exists(Path.Combine(home,"secrets","happier-account.key"))) && !ChooseAccount(home)) return;
            Wait(() => Run(home,bundle,"accounts/Account.ps1"), "Подключаем аккаунт Happier и проверяем его службу на сервере. Другие аккаунты продолжают работать.");
            if(interactive) MessageBox.Show("Аккаунт подключён. В Happier на телефоне или в браузере восстановите аккаунт по тому же ключу. Ключ хранится только в папке secrets.", "RemoteAgents — Happier");
        }
        static IEnumerable<TreeNode> All(TreeNodeCollection nodes) { foreach(TreeNode n in nodes) {yield return n;foreach(var child in All(n.Nodes)) yield return child;} }
        static void CheckChildren(TreeNode node, bool value) { node.Checked=value; foreach(TreeNode child in node.Nodes) CheckChildren(child,value); }
        static bool Included(string path, string[] selected) { return selected.Any(p => path == p || path.StartsWith(p+"/",StringComparison.Ordinal)); }
        public static void Disk(string home, string bundle)
        {
            var response=Json.Map(Json.Parse(Wait(() => Run(home,bundle,"disk/Select-Disk.ps1","-Action","Tree"), "Получаем дерево папок с сервера по SSH…")));
            var treeData=Json.Map(Json.Get(response,"tree"));var selected=Json.Strings(Json.Get(Json.Map(Json.Get(response,"selection")),"paths"));
            using(var form=new Form {Text="RemoteAgents — выбор папок и файлов",Width=780,Height=660,StartPosition=FormStartPosition.CenterScreen}) {
                var tree=new TreeView {Dock=DockStyle.Fill,CheckBoxes=true}; var nodes=new Dictionary<string,TreeNode>(StringComparer.Ordinal);
                foreach(var row in Json.Array(Json.Get(treeData,"folders"))) {var value=Json.Map(row);string name=Json.Str(value,"name");var n=tree.Nodes.Add(name);n.Tag=name;nodes.Add(name,n);}
                foreach(var row in Json.Array(Json.Get(treeData,"entries"))) {
                    var value=Json.Map(row);string path=Json.Str(value,"path");int slash=path.LastIndexOf('/');
                    TreeNode parent;if(slash<0 || !nodes.TryGetValue(path.Substring(0,slash),out parent)) throw new InvalidDataException();
                    var n=parent.Nodes.Add(path.Substring(slash+1));n.Tag=path;nodes.Add(path,n);
                }
                // Keep saved selections for temporarily absent files/projects, so a tree refresh loses no intent.
                var absent=selected.Where(p=>!nodes.ContainsKey(p)).ToArray();
                bool changing=true;foreach(var n in All(tree.Nodes)) n.Checked=Included((string)n.Tag,selected);changing=false;
                Action markPartial=()=>{foreach(var n in All(tree.Nodes)) n.ForeColor=!n.Checked && All(n.Nodes).Any(c=>c.Checked)?Color.DarkOrange:SystemColors.WindowText;};markPartial();
                tree.AfterCheck+=(s,e)=>{if(changing)return;changing=true;CheckChildren(e.Node,e.Node.Checked);
                    // An unchecked parent with checked descendants is a partial selection.
                    for(var p=e.Node.Parent;p!=null;p=p.Parent) p.Checked=false;
                    changing=false;markPartial();};
                var bar=new FlowLayoutPanel {Dock=DockStyle.Bottom,Height=50,FlowDirection=FlowDirection.RightToLeft};
                var apply=new Button {Text="Применить",Width=140,DialogResult=DialogResult.OK};var cancel=new Button {Text="Отмена",Width=120,DialogResult=DialogResult.Cancel};bar.Controls.Add(apply);bar.Controls.Add(cancel);
                var hint=new Label {Dock=DockStyle.Top,Height=65,Padding=new Padding(12),Text="Отмеченное синхронизируется. Оранжевый родитель выбран частично. Снятие отметки оставляет файлы на сервере. Локальная копия удаляется только после проверки синхронизации и совпадения с сервером."};
                form.Controls.Add(tree);form.Controls.Add(hint);form.Controls.Add(bar);form.AcceptButton=apply;form.CancelButton=cancel;
                if(form.ShowDialog()!=DialogResult.OK)return;
                var paths=All(tree.Nodes).Where(n=>n.Checked && (n.Parent==null || !n.Parent.Checked)).Select(n=>(string)n.Tag).Concat(absent).Distinct().ToArray();
                string file=Path.Combine(home,"state","disk-choice-"+Guid.NewGuid().ToString("N")+".json");
                try {
                    Json.Write(file,new {schema=1,paths});
                    Wait(()=>Run(home,bundle,"disk/Select-Disk.ps1","-Action","Apply","-SelectionFile",file),"Применяем выбор. Проверяем серверную копию перед освобождением места…");
                    Files.Atomic(Path.Combine(home,"state","disk-choice-complete"),"1\n");
                } finally {if(File.Exists(file))File.Delete(file);}
            }
        }
        public static void Ensure(string home,string bundle)
        {
            try { Account(home,bundle,false); }
            catch { MessageBox.Show("Аккаунт Happier пока не подтверждён. Повторите подключение через меню «Аккаунт Happier». Проверьте SSH и ключ.","RemoteAgents"); }
            if(!File.Exists(Path.Combine(home,"state","disk-choice-complete"))) Disk(home,bundle);
        }
    }
}
