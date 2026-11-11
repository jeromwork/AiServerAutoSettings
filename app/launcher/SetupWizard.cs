using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace RemoteAgents.Launcher
{
    // One UI and one production step dispatcher for first run and tray settings, in both EXEs.
    internal sealed class SetupWizard : Form
    {
        readonly string home, bundle; readonly bool first;
        readonly ListBox steps = new ListBox { Dock = DockStyle.Left, Width = 175 };
        readonly Panel pages = new Panel { Dock = DockStyle.Fill };
        readonly Panel[] sections = new Panel[7];
        readonly TextBox journal = new TextBox { Dock = DockStyle.Bottom, Height = 115, ReadOnly = true, Multiline = true, ScrollBars = ScrollBars.Vertical };
        readonly Button apply = new Button { Text = "Проверить / применить", Width = 180 }, back = new Button { Text = "Назад", Width = 90 }, next = new Button { Text = "Далее", Width = 90 }, close = new Button { Text = "Закрыть", Width = 90 };
        readonly ProgressBar progress = new ProgressBar { Dock = DockStyle.Bottom, Height = 7, Style = ProgressBarStyle.Continuous };
        readonly string[] titles = { "1. Сервер", "2. Связь", "3. Диск", "4. Happier", "5. Мост", "6. VPN", "7. Итог" };
        readonly string[] results = Enumerable.Repeat("Не проверено", 7).ToArray();
        bool activationRequested;
        readonly bool[] applied = new bool[6], dirty = new bool[6];
        TextBox address, login, diskBase, label, accountKey, api, web, vpnCheck, vpnDns;
        CheckBox installMissing, shared, bridge, shell, vpn, create;
        DataGridView nodes; TreeView tree; ListBox accounts; Label inventory, accountHint, summary;
        Dictionary<string, object> expectedCatalog; Dictionary<string, object>[] accountRows = new Dictionary<string, object>[0];
        DiskTreeSelection selection = new DiskTreeSelection(new string[0]);
        CancellationTokenSource stepCancellation; bool closingRequested;
        bool busy, changingTree, treeLoaded, catalogLoaded;

        internal static bool Display(string home, string bundle, bool first, int section = 0, bool activate = false)
        {
            // Product-independent lease: Start.cmd and simultaneous EXEs cannot open two masters.
            string suffix;
            using (var sha = SHA256.Create()) suffix = BitConverter.ToString(sha.ComputeHash(Files.Utf8.GetBytes(Path.GetFullPath(home).ToLowerInvariant()))).Replace("-", "");
            using (var lease = new Mutex(false, "Global\\RemoteAgents.Wizard." + suffix)) {
                bool owned; try { owned = lease.WaitOne(0); } catch (AbandonedMutexException) { owned = true; }
                if (!owned) { MessageBox.Show("Мастер уже открыт другим RemoteAgents/RemoteVPN. Завершите настройку в том окне: настройки общие.", "RemoteAgents"); return false; }
                try { using (var form = new SetupWizard(home, bundle, first, activate)) { form.steps.SelectedIndex = section; return form.ShowDialog() == DialogResult.OK; } }
                finally { lease.ReleaseMutex(); }
            }
        }
        SetupWizard(string home, string bundle, bool first, bool activate)
        {
            this.home = home; this.bundle = bundle; this.first = first;
            Text = "RemoteAgents — " + (first ? "первый запуск" : "Настройки"); Size = new Size(1000, 800); MinimumSize = new Size(930, 740);
            StartPosition = FormStartPosition.CenterScreen; AutoScaleMode = AutoScaleMode.Dpi;
            var bar = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 48, FlowDirection = FlowDirection.RightToLeft, Padding = new Padding(5) };
            bar.Controls.Add(close); bar.Controls.Add(next); bar.Controls.Add(apply); bar.Controls.Add(back);
            Controls.Add(pages); Controls.Add(steps); Controls.Add(journal); Controls.Add(progress); Controls.Add(bar);
            var config = new Configuration(home).Data;
            for (int i = 0; i < sections.Length; i++) { sections[i] = new Panel { Dock = DockStyle.Fill, AutoScroll = true, Padding = new Padding(15) }; pages.Controls.Add(sections[i]); steps.Items.Add(titles[i]); }
            ServerPage(config); ConnectionPage(); DiskPage(); AccountPage(config); BridgePage(config); VpnPage(config); SummaryPage();
            for(int i=0;i<6;i++) {
                int section=i;
                foreach(Control control in sections[i].Controls) {
                    var text=control as TextBox;if(text!=null)text.TextChanged+=(s,e)=>Changed(section);
                    var check=control as CheckBox;if(check!=null)check.CheckedChanged+=(s,e)=>Changed(section);
                }
            }
            nodes.CellValueChanged+=(s,e)=>Changed(1);nodes.UserAddedRow+=(s,e)=>Changed(1);
            tree.AfterCheck+=(s,e)=> {if(!changingTree)Changed(2);};
            steps.SelectedIndexChanged += async (s,e) => { sections[steps.SelectedIndex].BringToFront(); back.Enabled = steps.SelectedIndex > 0; next.Enabled = steps.SelectedIndex < 6; apply.Text = steps.SelectedIndex == 6 ? "Проверить итог / запустить" : "Проверить / применить"; RefreshSummary();
                if(!busy && steps.SelectedIndex==1 && !catalogLoaded)await Guard(LoadCatalog);
                if(!busy && steps.SelectedIndex==2 && !treeLoaded)await Guard(LoadTree);
                if(!busy && steps.SelectedIndex==3 && accountRows.Length==0)await Guard(LoadAccounts);
            };
            back.Click += (s,e) => { if (steps.SelectedIndex > 0) steps.SelectedIndex--; };
            next.Click += (s,e) => { if (steps.SelectedIndex < 6) steps.SelectedIndex++; };
            apply.Click += async (s,e) => await ExecuteCurrent();
            close.Click += (s,e) => Close();
            FormClosing += (s,e) => {
                if (busy) { e.Cancel = true; closingRequested = true; Append("Отмена текущего шага…"); stepCancellation.Cancel(); }
                else DialogResult = DialogResult.Cancel;
            };
            if(activate) Shown += async (s,e) => await Guard(async()=> {var result=await Run("Activate",new {});activationRequested=true;results[6]=Json.Str(result,"summary");Append(results[6]);});
            Append("Каждый шаг проверяет состояние заново. Пароль вводится только в защищённом окне SSH и не сохраняется. Журналы: " + Path.Combine(home,"logs"));
        }
        Label Hint(int page, string text, int top = 12, int height = 72)
        { var c = new Label { Left = 18, Top = top, Width = 700, Height = height, Text = text, Anchor = AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Top }; sections[page].Controls.Add(c); return c; }
        TextBox Field(int page, string title, int top, string value = "", bool secret = false)
        {
            Hint(page,title,top,24); var box = new TextBox { Left = 18, Top = top+25, Width = 680, Text = value, UseSystemPasswordChar = secret, Anchor = AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Top };
            sections[page].Controls.Add(box); return box;
        }
        CheckBox Check(int page, string text, int top, bool value)
        { var c = new CheckBox { Left = 18, Top = top, Width = 690, Height = 40, Text = text, Checked = value }; sections[page].Controls.Add(c); return c; }
        void Button(int page, string text, int top, Func<Task> action)
        { var c = new Button { Left = 18, Top = top, Width = 265, Height = 30, Text = text }; c.Click += async (s,e) => { if (busy) return; await Guard(action); }; sections[page].Controls.Add(c); }
        void ServerPage(Dictionary<string,object> config)
        {
            Hint(0,"Подключитесь к своему Linux-серверу. Нужен рабочий пользователь SSH. Подтвердите отпечаток сервера в окне SSH. Уже настроенные службы проверяются и сохраняются.");
            string host="", user="";
            try {
                string profile = Json.Str(Json.Map(Json.Get(config,"transport")),"profilePath");
                if (profile.Length==0) { string saved=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"RemoteDisk","profile.txt"); profile=Files.ReadLine(saved); }
                if(profile.Length==0) { string dir=Path.Combine(home,"ssh-profiles"); if(Directory.Exists(dir)) {var found=Directory.GetFiles(dir,"ssh-transport.json",SearchOption.AllDirectories);if(found.Length==1)profile=found[0];} }
                if(File.Exists(profile)) {var p=Json.Read(profile);host=Json.Str(p,"serverAddress");user=Json.Str(p,"login");}
            } catch { }
            address=Field(0,"Адрес сервера",95,host); login=Field(0,"Пользователь SSH",160,user);
            installMissing=Check(0,"Установить / восстановить недостающее на моём сервере",230,false);
            inventory=Hint(0,"Сервер ещё не проверен.",280,160);
            Hint(0,"Установка использует существующие server-скрипты под вашим пользователем. Если нужны системные пакеты или user systemd, мастер покажет необходимые действия с sudo. Скрытого ввода sudo-пароля нет.",440,85);
        }
        void ConnectionPage()
        {
            Hint(1,"Каталог входов, переходов, ретрансляторов и CDN приходит с вашего сервера. Для SSH-узла укажите свой SSH-алиас; ключи и known_hosts настраиваются отдельно на этом ПК. Старый канал импортируется автоматически при переходе.");
            Button(1,"Получить каталог с сервера",88,LoadCatalog);
            nodes=new DataGridView {Left=18,Top=130,Width=690,Height=315,Anchor=AnchorStyles.Left|AnchorStyles.Right|AnchorStyles.Top,AllowUserToAddRows=true,AllowUserToDeleteRows=false,AutoSizeColumnsMode=DataGridViewAutoSizeColumnsMode.Fill};
            var kind=new DataGridViewComboBoxColumn {Name="kind",HeaderText="Тип"};kind.Items.AddRange("Вход","SSH-переход","Ретранслятор","CDN");nodes.Columns.Add(kind);
            nodes.Columns.Add("name","Имя");nodes.Columns.Add("target","SSH-алиас / хост / домен");nodes.Columns.Add("port","Порт ретранслятора");nodes.Columns.Add("entry","Вход для CDN");nodes.Columns.Add(new DataGridViewCheckBoxColumn {Name="enabled",HeaderText="Включён"});sections[1].Controls.Add(nodes);
            shared=Check(1,"Сохранить на сервере для всех моих компьютеров",453,false);
            Hint(1,"Без этой отметки изменения действуют только здесь. Новые строки добавляются в конце таблицы. Для отключения снимите отметку «Включён». Для действующей связи сначала выполняется проба на отдельных портах, затем применяется изменение с независимым откатом.",497,100);
        }
        void DiskPage()
        {
            string file=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"RemoteDisk","base.txt");string value=Files.ReadLine(file);if(value.Length==0)value=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),"Disk");
            Hint(2,"Отмеченное синхронизируется в обе стороны. Неотмеченные файлы только на ПК остаются здесь. Серверные копии не удаляются снятием отметки. При конфликте сохраняются версии .sync-conflict; секреты и .git исключены.",12,68);
            diskBase=Field(2,"Корень Disk (смена переносит подключённые проекты; занятый путь блокирует перенос)",82,value);
            Button(2,"Выбрать папку…",145,()=> {using(var d=new FolderBrowserDialog {SelectedPath=diskBase.Text})if(d.ShowDialog(this)==DialogResult.OK){diskBase.Text=d.SelectedPath;treeLoaded=false;}return Task.FromResult(0);});
            Button(2,"Обновить объединённое дерево",185,LoadTree);
            tree=new TreeView {Left=18,Top=228,Width=690,Height=320,CheckBoxes=true,Anchor=AnchorStyles.Top|AnchorStyles.Left|AnchorStyles.Right};sections[2].Controls.Add(tree);
            diskBase.TextChanged+=(s,e)=>treeLoaded=false;
            tree.AfterCheck+=(s,e)=> {
                if(changingTree)return;
                string path=Convert.ToString(e.Node.Tag);
                try {if(path.Length>0)selection.Set(path,e.Node.Checked);}
                catch(Exception error) {Append(error.Message);}
                RefreshTreeChecks();
            };
            tree.BeforeExpand+=async (s,e)=> {
                if(e.Node.Nodes.Count!=1 || e.Node.Nodes[0].Tag!=null)return;
                e.Cancel=true;if(busy)return;
                var node=e.Node;
                await Guard(async()=> {await LoadChildren(node);node.Expand();});
            };
            Button(2,"Пропустить диск",558,()=> {results[2]="Диск пропущен; настройка не подтверждена";Append(results[2]);steps.SelectedIndex=3;return Task.FromResult(0);});
        }
        void AccountPage(Dictionary<string,object> config)
        {
            var settings=Json.Map(Json.Get(config,"happier"));
            Hint(3,"Подключайтесь только к своему аккаунту по его ключу или создайте новый с именем. Список показывает имена; чужой аккаунт нельзя присвоить выбором строки. Чаты и службы других аккаунтов сохраняются.");
            Button(3,"Получить имена аккаунтов",85,LoadAccounts);
            accounts=new ListBox {Left=18,Top=125,Width=690,Height=90};sections[3].Controls.Add(accounts);
            accounts.SelectedIndexChanged+=(s,e)=> {if(accounts.SelectedIndex<0)return;var r=accountRows[accounts.SelectedIndex];label.Text=Json.Str(r,"label");if(Json.Str(r,"serverUrl").Length>0)api.Text=Json.Str(r,"serverUrl");if(Json.Str(r,"webappUrl").Length>0)web.Text=Json.Str(r,"webappUrl");};
            label=Field(3,"Имя моего аккаунта",222,Json.Str(settings,"label"));
            create=Check(3,"Создать новый аккаунт с этим именем",283,false);
            accountKey=Field(3,"Ключ своего аккаунта (пусто — проверить сохранённый ключ)",330,"",true);
            api=Field(3,"HTTPS-адрес API Happier (из настроек вашего сервера)",395,Json.Str(settings,"serverUrl"));
            web=Field(3,"HTTPS-адрес Web Happier",460,Json.Str(settings,"webappUrl"));
            create.CheckedChanged+=(s,e)=>accountKey.Enabled=!create.Checked;
            accountHint=Hint(3,"Ключ хранится только в secrets. Для телефона и браузера используйте тот же ключ в Restore with Secret Key. Сохраните резервную копию secrets.",530,65);
        }
        void BridgePage(Dictionary<string,object> config)
        {
            var c=Json.Map(Json.Get(config,"bridge"));
            Hint(4,"Мост позволяет вашим агентам управлять этим компьютером. Разрешение shell даёт выполнение команд от вашего имени. Оно применяется и на компьютере, и в каталоге сервера.");
            bool legacy=Json.Bool(Json.Map(Json.Get(Json.Map(Json.Get(config,"components")),"control")),"enabled") || File.Exists(Path.Combine(home,"control","config.json"));
            bool enabled=Json.Bool(c,"enabled",legacy);
            bridge=Check(4,"Включить мост для этого компьютера",110,enabled);shell=Check(4,"Разрешить выполнение команд (shell)",175,Json.Bool(c,"allowShell",c.Count==0 && legacy));
        }
        void VpnPage(Dictionary<string,object> config)
        {
            var c=Json.Map(Json.Get(config,"vpn"));
            Hint(5,"VPN использует ту же связь с сервером. По умолчанию выключен. Перед включением мастер проверяет другой VPN: отключите его сами либо оставьте всё как есть. Для TUN Windows запросит UAC; независимый watchdog вернёт маршруты при ошибке.",12,105);
            vpn=Check(5,"Включить VPN для этого компьютера",130,Json.Bool(c,"enabled"));
            vpnCheck=Field(5,"Ваш HTTPS-адрес для проверки VPN",200,Json.Str(c,"checkUrl"));vpnDns=Field(5,"DNS для VPN (адрес вашего сервера или выбранного DNS)",275,Json.Str(c,"dnsServer"));
            Hint(5,"Первое включение VPN — после подтверждения связи в трее. Для смены DNS/проверки работающий VPN сначала выключите. Для применения отметки требуется установленный RemoteVPN.exe; вход в мастер у обоих EXE общий.",370,100);
        }
        void SummaryPage()
        {
            summary=Hint(6,"",12,350);
            Hint(6,"Журнал шагов находится внизу окна и в logs/migration.log. «Выбор применён» не означает «все файлы переданы». Итоговая проверка связи — живые статусы трея и три зелёных минуты перехода. При ошибке вернитесь к нужному разделу и повторите проверку.",380,110);
        }
        void Changed(int index) {if(busy)return;dirty[index]=true;applied[index]=false;results[index]="Есть неприменённые изменения";RefreshSummary();}
        void RefreshSummary() {if(summary!=null)summary.Text=string.Join("\r\n\r\n",titles.Select((t,i)=>t+": "+results[i]));}
        void Append(string text) {journal.AppendText(DateTime.Now.ToString("HH:mm:ss")+" "+text+"\r\n");}
        async Task Guard(Func<Task> action)
        {
            busy=true;stepCancellation=new CancellationTokenSource();steps.Enabled=false;pages.Enabled=false;apply.Enabled=back.Enabled=next.Enabled=false;close.Enabled=true;progress.Style=ProgressBarStyle.Marquee;
            try {await action();}
            catch(OperationCanceledException) {if(steps.SelectedIndex<6)applied[steps.SelectedIndex]=false;results[steps.SelectedIndex]="Шаг отменён; готовность не подтверждена";Append(results[steps.SelectedIndex]);}
            catch(Exception e) {if(steps.SelectedIndex<6)applied[steps.SelectedIndex]=false;results[steps.SelectedIndex]="Ошибка: "+e.Message;Append(results[steps.SelectedIndex]);}
            finally {busy=false;stepCancellation.Dispose();stepCancellation=null;steps.Enabled=pages.Enabled=apply.Enabled=close.Enabled=true;back.Enabled=steps.SelectedIndex>0;next.Enabled=steps.SelectedIndex<6;progress.Style=ProgressBarStyle.Continuous;RefreshSummary();if(closingRequested)Close();}
        }
        async Task<Dictionary<string,object>> Run(string action, object request)
        {
            Append(action+": проверка…");
            string requestFile=Path.Combine(home,"state","wizard-request-"+Guid.NewGuid().ToString("N")+".json"), output=requestFile+".out";
            try {
                Json.Write(requestFile,request);
                var args=new[]{"-NoLogo","-NoProfile","-NonInteractive","-STA","-ExecutionPolicy","Bypass","-File",Path.Combine(bundle,"build","Wizard.ps1"),"-Home",home,"-Action",action,"-RequestFile",requestFile};
                var token=stepCancellation.Token;
                int code;
                try {code=await Task.Run(()=>External.Run(Files.Executable("powershell.exe"),args,bundle,output,WizardStep.Timeout(action),4*1024*1024,token));}
                catch(OperationCanceledException) {new Journal(home).Write("wizard."+action+".cancelled");throw;}
                catch(TimeoutException) {new Journal(home).Write("wizard."+action+".timeout");throw;}
                Dictionary<string,object> response;
                try {response=Json.Map(Json.Parse(Files.LF(External.ReadPowerShellOutput(output))));}
                catch {throw new IOException("Шаг не вернул результат (код "+code+"). Проверьте журнал соответствующего модуля и повторите");}
                if(code!=0 || !Json.Bool(response,"ok"))throw new IOException(Json.Text(response,"reason","Шаг не подтверждён: проверьте журнал и повторите")+". "+Json.Str(response,"remedy"));
                return Json.Map(Json.Get(response,"result"));
            } finally {if(File.Exists(requestFile))File.Delete(requestFile);if(File.Exists(output))File.Delete(output);}
        }
        async Task LoadCatalog()
        {
            var catalog=await Run("Catalog",new {});expectedCatalog=catalog;catalogLoaded=true;nodes.Rows.Clear();
            var config=new Configuration(home).Data;var wizard=Json.Map(Json.Get(config,"wizard"));
            var local=Json.Map(Json.Get(wizard,"localCatalog"));
            if(!wizard.ContainsKey("localCatalog"))local=Json.Map(Json.Get(config,"transport"));
            foreach(string group in new[]{"entries","hops","relays","cdn"}) {
                var rows=Json.Array(Json.Get(catalog,group)).Select(Json.Map).ToList();
                foreach(var row in Json.Array(Json.Get(local,group)).Select(Json.Map).Where(r=>Json.Str(r,"legacyOutbound").Length==0)){var clean=new Dictionary<string,object>(row);clean.Remove("configPath");if(!clean.ContainsKey("ssh") && clean.ContainsKey("alias")){clean["ssh"]=clean["alias"];clean.Remove("alias");}if(!clean.ContainsKey("host") && clean.ContainsKey("server")){clean["host"]=clean["server"];clean.Remove("server");}rows.RemoveAll(r=>Json.Str(r,"name")==Json.Str(row,"name"));rows.Add(clean);}
                foreach(var row in rows){int index=nodes.Rows.Add(CatalogTitle(group),Json.Str(row,"name"),Json.Text(row,"ssh",Json.Text(row,"host",Json.Str(row,"domain"))),Json.Str(row,"port"),Json.Str(row,"entry"),Json.Bool(row,"enabled",true));nodes.Rows[index].Tag=row;}
            }
            Append("Каталог получен с сервера; секреты не загружались в таблицу.");
        }
        static string CatalogTitle(string group) {return group=="entries"?"Вход":group=="hops"?"SSH-переход":group=="relays"?"Ретранслятор":"CDN";}
        Dictionary<string,object> ReadCatalog()
        {
            nodes.EndEdit();
            foreach(DataGridViewRow row in nodes.Rows)if(!row.IsNewRow && !new[]{"Вход","SSH-переход","Ретранслятор","CDN"}.Contains(Convert.ToString(row.Cells[0].Value)))throw new IOException("Выберите тип для каждой добавленной строки каталога");
            var map=new Dictionary<string,object>{{"schema",1}};
            foreach(string group in new[]{"entries","hops","relays","cdn"}) {
                var list=new List<object>();foreach(DataGridViewRow row in nodes.Rows) {
                    if(row.IsNewRow || Convert.ToString(row.Cells[0].Value)!=CatalogTitle(group))continue;
                    var item=row.Tag is Dictionary<string,object>?new Dictionary<string,object>((Dictionary<string,object>)row.Tag):new Dictionary<string,object>();
                    item["name"]=Convert.ToString(row.Cells[1].Value).Trim();item["enabled"]=Convert.ToBoolean(row.Cells[5].Value??true);
                    string target=Convert.ToString(row.Cells[2].Value).Trim();
                    if(group=="entries" || group=="hops")item["ssh"]=target;
                    if(group=="relays"){item["host"]=target;item["port"]=int.Parse(Convert.ToString(row.Cells[3].Value));}
                    if(group=="cdn"){item["domain"]=target;item["entry"]=Convert.ToString(row.Cells[4].Value).Trim();}
                    list.Add(item);
                }map[group]=list.ToArray();
            }return map;
        }
        static IEnumerable<TreeNode> All(TreeNodeCollection nodes) {foreach(TreeNode n in nodes){yield return n;foreach(var child in All(n.Nodes))yield return child;}}
        void MarkPartial(){foreach(var n in All(tree.Nodes))if(n.Tag!=null)n.ForeColor=selection.Partial((string)n.Tag)?Color.DarkOrange:SystemColors.WindowText;}
        void RefreshTreeChecks()
        {
            changingTree=true;
            try {foreach(var n in All(tree.Nodes))n.Checked=n.Tag!=null && Convert.ToString(n.Tag).Length>0 && selection.Includes((string)n.Tag);MarkPartial();}
            finally{changingTree=false;}
        }
        void AddTreeLevel(Dictionary<string,object> union, TreeNode parent)
        {
            string prefix=parent==null?"":(string)parent.Tag;
            var children=new List<TreeNode>();
            foreach(var r in Json.Array(Json.Get(union,"rows"))) {
                var row=Json.Map(r);string path=Json.Str(row,"path"),presence=Json.Str(row,"presence");int slash=path.LastIndexOf('/');
                string actualParent=slash<0?"":path.Substring(0,slash);
                if(actualParent!=prefix)throw new InvalidDataException("Сервер вернул другой уровень дерева");
                string mark=presence=="both"?"в обоих":presence=="local"?"только здесь":"только на сервере";
                if(Json.Bool(union,"truncated"))mark=presence=="both"?"в обоих":"обнаружено "+(presence=="local"?"здесь":"на сервере")+" (список неполный)";
                var n=new TreeNode((slash<0?path:path.Substring(slash+1))+" — "+mark){Tag=path};
                if(slash<0 && Json.Str(row,"kind")=="file"){n.Tag="";n.Text+=" — поместите в папку проекта для синхронизации";}
                if(Json.Str(row,"kind")=="directory" && Json.Bool(row,"hasChildren"))n.Nodes.Add(new TreeNode("Загрузка при раскрытии…"));
                children.Add(n);
            }
            selection.Level(prefix,children.Where(n=>Convert.ToString(n.Tag).Length>0).Select(n=>(string)n.Tag),Json.Bool(union,"truncated"));
            var target=parent==null?tree.Nodes:parent.Nodes;
            target.Clear();target.AddRange(children.ToArray());RefreshTreeChecks();
            if(Json.Bool(union,"truncated"))Append("Показана часть большой папки. Отметка папки включает скрытые элементы. Для частичного выбора снимите всю папку, затем отметьте нужные видимые элементы.");
        }
        async Task LoadTree()
        {
            treeLoaded=false;
            var data=await Run("DiskTree",new { @base=diskBase.Text.Trim(),path="" });
            selection=new DiskTreeSelection(Json.Strings(Json.Get(Json.Map(Json.Get(data,"selection")),"paths")));
            changingTree=true;try {AddTreeLevel(Json.Map(Json.Get(data,"union")),null);treeLoaded=true;}finally{changingTree=false;}
            Append("Загружен корень Disk. Дети папки загружаются при раскрытии. Наличие в обоих местах не подтверждает совпадение содержимого.");
        }
        async Task LoadChildren(TreeNode parent)
        {
            var data=await Run("DiskTree",new { @base=diskBase.Text.Trim(),path=(string)parent.Tag });
            changingTree=true;try {AddTreeLevel(Json.Map(Json.Get(data,"union")),parent);}finally{changingTree=false;}
        }
        async Task LoadAccounts()
        {
            var result=await Run("AccountList",new {});accountRows=Json.Array(Json.Get(result,"accounts")).Select(Json.Map).ToArray();accounts.Items.Clear();
            string current="";string file=Path.Combine(home,"state","happier-account.json");if(File.Exists(file))current=Json.Str(Json.Read(file),"account");
            foreach(var row in accountRows)accounts.Items.Add(Json.Str(row,"label")+(Json.Str(row,"account")==current?" — мой сохранённый аккаунт (ключ проверяется при подключении)":" — другой / ещё не подтверждён вашим ключом"));
            Append("Имена аккаунтов получены. Принадлежность подтверждается ключом, имя не даёт доступа.");
        }
        string Origin(string text)
        {
            Uri uri;if(!Uri.TryCreate(text.Trim(),UriKind.Absolute,out uri) || uri.Scheme!="https" || uri.UserInfo.Length>0 || uri.AbsolutePath!="/" || uri.Query.Length>0 || uri.Fragment.Length>0)throw new IOException("Укажите HTTPS-адрес Happier без пути, пароля и параметров");
            return uri.GetLeftPart(UriPartial.Authority);
        }
        async Task ExecuteCurrent()
        {
            int index=steps.SelectedIndex;
            await Guard(async()=> {
                Dictionary<string,object> result;
                switch(index) {
                    case 0:
                        result=await Run("Server",new {address=address.Text.Trim(),login=login.Text.Trim(),installMissing=installMissing.Checked});
                        inventory.Text="SSH: проверен\r\n"+string.Join("\r\n",new[]{"disk","happier","bridge","catalog"}.Select(k=>(k=="disk"?"Диск-сервер":k=="happier"?"Happier (программа)":k=="bridge"?"Серверная часть моста":"Каталог узлов")+": "+(Json.Bool(result,k)?"обнаружен / проверен":"отсутствует или не отвечает")));
                        var services=Json.Map(Json.Get(result,"services"));if(api.Text.Length==0)api.Text=Json.Str(services,"serverUrl");if(web.Text.Length==0)web.Text=Json.Str(services,"webappUrl");
                        if(new[]{"disk","happier","bridge","catalog"}.Any(k=>!Json.Bool(result,k)))throw new IOException("SSH работает; сервер настроен частично. Отметьте установку недостающего и повторите. Существующие службы сохраняются");
                        break;
                    case 1:
                        if(!catalogLoaded){await LoadCatalog();return;}
                        result=await Run("Connection",new {catalog=ReadCatalog(),expected=expectedCatalog,shared=shared.Checked});break;
                    case 2:
                        if(!treeLoaded){await LoadTree();return;}
                        var paths=selection.Paths;
                        result=await Run("Disk",new {@base=diskBase.Text.Trim(),paths});break;
                    case 3:
                        string apiOrigin=Origin(api.Text),webOrigin=Origin(web.Text);if(string.IsNullOrWhiteSpace(label.Text))throw new IOException("Укажите имя своего аккаунта");
                        string key=accountKey.Text.Trim();if(create.Checked){var bytes=new byte[32];using(var rng=RandomNumberGenerator.Create())rng.GetBytes(bytes);key=Convert.ToBase64String(bytes).TrimEnd('=').Replace('+','-').Replace('/','_');}
                        string keyFile=Path.Combine(home,"secrets","happier-account.key");string previousKey=File.Exists(keyFile)?File.ReadAllText(keyFile):null;
                        string expectedAccount=!create.Checked && accounts.SelectedIndex>=0?Json.Str(accountRows[accounts.SelectedIndex],"account"):"";
                        try {
                            if(key.Length>0){AccountDiskSetup.SaveKey(home,key);accountKey.Clear();}
                            result=await Run("Account",new {label=label.Text.Trim(),serverUrl=apiOrigin,webappUrl=webOrigin,expectedAccount});
                        } catch {
                            if(key.Length>0) {Files.Atomic(Path.Combine(home,"secrets","happier-unconfirmed-"+Guid.NewGuid().ToString("N")+".key"),key+"\n");if(previousKey!=null)Files.Atomic(keyFile,previousKey);else if(File.Exists(keyFile))File.Delete(keyFile);}
                            throw;
                        }
                        create.Checked=false;break;
                    case 4:result=await Run("Bridge",new {enabled=bridge.Checked,shell=shell.Checked});break;
                    case 5:result=await Run("Vpn",new {enabled=vpn.Checked,checkUrl=vpnCheck.Text.Trim(),dnsServer=vpnDns.Text.Trim()});break;
                    default:
                        if(dirty.Any(v=>v))throw new IOException("Сначала примените изменённые разделы: итог проверяет сохранённые настройки");
                        if(first && applied.Any(v=>!v))throw new IOException("Сначала проверьте / примените все шесть разделов. Выключенные мост и VPN тоже нужно подтвердить");
                        if(first && !activationRequested) {result=await Run("Activate",new {});activationRequested=true;results[6]=Json.Text(result,"summary","Ожидается подтверждение живого состояния");Append(results[6]);}
                        else {
                            result=await Run("Inspect",new {});
                            var observations=Json.Array(Json.Get(result,"steps")).Select(Json.Map).ToArray();
                            for(int i=0;i<Math.Min(6,observations.Length);i++)results[i]=Json.Bool(observations[i],"ready")?"Готово: проверено сейчас":"Не готово: проверьте раздел, связь или журнал";
                            results[6]="Переход: "+Json.Str(result,"phase")+". "+Json.Str(result,"summary");Append(results[6]);
                        }
                        return;
                }
                bool ok=Json.Bool(result,"ok",true);applied[index]=true;dirty[index]=false;
                results[index]=Json.Text(result,"summary",index==0?"Состояние сервера проверено":"Готово: операция подтверждена")+(ok?"":" (ожидание, не готово)");Append(titles[index]+": "+results[index]);
            });
        }
    }
}
