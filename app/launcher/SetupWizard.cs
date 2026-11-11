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
        readonly WizardNavigation steps = new WizardNavigation();
        readonly Panel pages = new Panel { Dock = DockStyle.Fill };
        readonly Panel[] sections = new Panel[8], details = new Panel[8];
        readonly Label[] states = new Label[8];
        readonly TextBox journal = new TextBox { Dock = DockStyle.Fill, ReadOnly = true, Multiline = true, ScrollBars = ScrollBars.Vertical };
        readonly Label lastLine = new Label { Dock = DockStyle.Fill, AutoEllipsis = true, TextAlign = ContentAlignment.MiddleLeft };
        readonly Button back = new Button { Text = "Назад", Width = 88 }, next = new Button { Text = "Далее", Width = 88 }, close = new Button { Text = "Закрыть", Width = 88 };
        readonly ProgressBar progress = new ProgressBar { Dock = DockStyle.Bottom, Height = 4 };
        readonly string[] titles = { "Сервер", "Связь", "Диск", "Happier", "Мост", "VPN", "Локальная сеть", "Итог" };
        readonly string[] results = Enumerable.Repeat("Ещё не проверено", 8).ToArray();
        readonly int[] order = {0,1,4,2,3,6,5,7};
        bool activationRequested, lastSuccess, reconnectDisk, serverChanged, repairingServer; int currentPage;
        readonly bool[] applied = new bool[7], dirty = new bool[7];
        TextBox address, login, password, diskBase, label, accountKey, api, web, vpnCheck, vpnDns;
        CheckBox installMissing, shared, bridge, shell, vpn, create;
        DataGridView nodes; TreeView tree; ListBox accounts; Label inventory, accountHint, summary, diskWarning;
        string originalAddress, originalLogin, lanFile = "", lanCommand = "";
        Dictionary<string, object> expectedCatalog; Dictionary<string, object>[] accountRows = new Dictionary<string, object>[0];
        DiskTreeSelection selection = new DiskTreeSelection(new string[0]);
        CancellationTokenSource stepCancellation; bool closingRequested;
        bool busy, changingTree, treeLoaded, catalogLoaded, initializing;
        bool legacy, migrationRunning, migrationHandover; System.Windows.Forms.Timer migrationTimer; string migrationText = "";

        protected override void Dispose(bool disposing)
        {if(disposing){if(migrationTimer!=null)migrationTimer.Dispose();foreach(var panel in details)if(panel!=null)panel.Dispose();journal.Dispose();}base.Dispose(disposing);}
        static string LeaseName(string home)
        {using(var sha=SHA256.Create())return "Global\\RemoteAgents.Wizard."+BitConverter.ToString(sha.ComputeHash(Files.Utf8.GetBytes(Path.GetFullPath(home).ToLowerInvariant()))).Replace("-", "");}
        internal static bool Display(string home, string bundle, bool first, int section = 0, bool activate = false)
        {
            using (var lease = new Mutex(false, LeaseName(home))) {
                bool owned; try { owned = lease.WaitOne(0); } catch (AbandonedMutexException) { owned = true; }
                if (!owned) return false;
                try { using (var form = new SetupWizard(home, bundle, first, activate)) { form.SelectPage(section); return form.ShowDialog() == DialogResult.OK; } }
                finally { lease.ReleaseMutex(); }
            }
        }
        // Inspect before showing anything (only for a not yet configured PC; the tray never calls this
        // once wizard.configured is set). Returns null: setup incomplete; "": ready, nothing changed;
        // otherwise the balloon text describing the real change.
        internal static async Task<string> CheckOnLaunch(string home, string bundle)
        {
            using(var lease=new Mutex(false,LeaseName(home))) {
            bool owned;try{owned=lease.WaitOne(0);}catch(AbandonedMutexException){owned=true;}if(!owned)return null;
            try {using(var form = new SetupWizard(home,bundle,true,false)) {
                var handle=form.Handle;
                await form.Inspect();
                // At boot the transport may publish its first live status later than this check:
                // when only «Связь» is open, look once more before showing anything.
                if(!form.applied[1] && !form.legacy && Enumerable.Range(0,6).All(i=>i==1 || form.applied[i])){await Task.Delay(20000);await form.Inspect();}
                // The optional LAN step alone never opens the window.
                bool required=Enumerable.Range(0,6).All(i=>form.applied[i]);
                if(required && !form.legacy){
                    // Everything is verified: record it without a window.
                    form.SelectPage(7);await form.ExecuteCurrent();
                    if(form.lastSuccess)return "Настройка завершена. Приложение работает в трее.";
                    // Not confirmed: show the summary with the reason instead of failing silently.
                }
                form.SelectPage(required?7:form.order.First(i=>i<6 && !form.applied[i]));
                if(form.ShowDialog()!=DialogResult.OK)return null;
                return form.migrationHandover?"":"Настройка завершена. Приложение работает в трее.";
            }}finally{lease.ReleaseMutex();}
            }
        }
        internal SetupWizard(string home, string bundle, bool first, bool activate)
        {
            this.home = home; this.bundle = bundle; this.first = first; initializing=true;
            AutoScaleDimensions=new SizeF(96,96); AutoScaleMode=AutoScaleMode.Dpi;
            Text = "RemoteAgents — " + (first ? "настройка" : "Настройки"); ClientSize=new Size(780,460);
            if(!first)titles[7]="Состояние";
            FormBorderStyle=FormBorderStyle.FixedDialog; MaximizeBox=false; StartPosition=FormStartPosition.CenterScreen;
            Font=new Font("Segoe UI",9F);
            var bar=new FlowLayoutPanel {Dock=DockStyle.Bottom,Height=42,FlowDirection=FlowDirection.RightToLeft,Padding=new Padding(5)};
            bar.Controls.Add(close);bar.Controls.Add(next);bar.Controls.Add(back);
            var logbar=new Panel {Dock=DockStyle.Bottom,Height=29,Padding=new Padding(8,0,5,0)};
            var showLog=new Button {Text="Журнал",Dock=DockStyle.Right,Width=88};showLog.Click+=(a,b)=>ShowJournal();
            logbar.Controls.Add(lastLine);logbar.Controls.Add(showLog);
            var divider=new Label {Dock=DockStyle.Left,Width=1,BackColor=SystemColors.ControlDark};
            Controls.Add(pages);Controls.Add(divider);Controls.Add(steps);Controls.Add(progress);Controls.Add(logbar);Controls.Add(bar);
            var config=new Configuration(home).Data;
            for(int i=0;i<8;i++) {
                sections[i]=new Panel {Dock=DockStyle.Fill,AutoScroll=true};pages.Controls.Add(sections[i]);
                details[i]=new Panel {Width=575,Height=420,AutoScroll=true};
            }
            ServerPage(config);ConnectionPage();DiskPage();AccountPage(config);BridgePage(config);VpnPage(config);LanPage();SummaryPage();
            steps.Initialize(titles,order);steps.Available=i=>WizardStep.CanOpen(i,currentPage,first,applied,order);
            // Settings: free clicking, the main button applies the open section. First run: walk with «Далее».
            back.Visible=first;
            for(int i=0;i<7;i++) {int section=i;
                foreach(Control c in sections[i].Controls.Cast<Control>().Concat(details[i].Controls.Cast<Control>())) {
                    var t=c as TextBox;if(t!=null)t.TextChanged+=(a,b)=>Changed(section);
                    var check=c as CheckBox;if(check!=null)check.CheckedChanged+=(a,b)=>Changed(section);
                }
            }
            nodes.CellValueChanged+=(a,b)=>Changed(1);nodes.UserAddedRow+=(a,b)=>Changed(1);
            tree.AfterCheck+=(a,b)=> {if(!changingTree)Changed(2);};
            address.TextChanged+=(a,b)=>InvalidateServer();login.TextChanged+=(a,b)=>InvalidateServer();
            steps.SectionRequested+=i=> {if(WizardStep.CanOpen(i,currentPage,first,applied,order))SelectPage(i);else{steps.Section=currentPage;Append("Сначала завершите или пропустите раздел «"+titles[currentPage]+"»");}};
            back.Click+=(a,b)=>Navigate(-1);
            next.Click+=async(a,b)=> {
                int completed=steps.Section;
                await ExecuteCurrent();
                if(!lastSuccess || closingRequested)return;
                if(completed==0 && serverChanged){repairingServer=true;serverChanged=false;}
                if(!first){if(completed==0 && repairingServer){Navigate(1);await ContinueServerRepair();}return;}
                if(completed==7){if(!migrationRunning){DialogResult=DialogResult.OK;Close();}return;}
                Navigate(1);await ContinueServerRepair();await FinishAutomatically();
            };
            close.Click+=(a,b)=>Close();
            FormClosing+=(a,b)=> {if(busy){b.Cancel=true;closingRequested=true;Append("Отменяю текущую операцию…");stepCancellation.Cancel();}else if(DialogResult!=DialogResult.OK)DialogResult=DialogResult.Cancel;};
            Shown+=async(a,b)=> {if(!first)await Inspect();};
            initializing=false;SelectPage(0);
            Append("Готов к настройке. Пароль используется один раз и не сохраняется.");
        }
        void SelectPage(int index)
        {
            if(index<0 || index>7)return;
            currentPage=index;steps.Section=index;sections[index].BringToFront();back.Enabled=!busy && Array.IndexOf(order,index)>0;
            next.Text=first?(index==7?(legacy?"Начать переход":"Готово"):"Далее"):(index==7?"Проверить":"Применить");RefreshSummary();
        }
        void Navigate(int direction)
        {
            // Forward in first run skips ready sections; back always opens the previous one.
            int n=Array.IndexOf(order,steps.Section)+direction;
            while(n>=0 && n<order.Length) {
                int i=order[n];if(!first || direction<0 || i==7 || !applied[i]){SelectPage(i);return;}n+=direction;
            }
        }
        async Task ContinueServerRepair()
        {
            // Reapply known settings in priority order; stop whenever an explicit data/file choice is needed.
            while(repairingServer && !closingRequested) {
                int index=steps.Section;
                if(index==2 || index==6 || index==7 || (index==5 && vpn.Checked))return;
                if(index==3 && (api.Text.Length==0 || web.Text.Length==0 || label.Text.Length==0))return;
                if(index!=1 && index!=4 && index!=3 && index!=5)return;
                await ExecuteCurrent();if(!lastSuccess)return;Navigate(1);
            }
        }
        async Task FinishAutomatically()
        {if(first && steps.Section==7 && lastSuccess && !closingRequested){await ExecuteCurrent();if(lastSuccess && !migrationRunning){DialogResult=DialogResult.OK;Close();}}}
        Label Hint(int page,string text,int top=12,int height=44)
        {var c=new Label {Left=16,Top=top,Width=585,Height=height,Text=text};sections[page].Controls.Add(c);return c;}
        void Question(int page,string text)
        {var title=Hint(page,text,8,26);title.Font=new Font(Font.FontFamily,12F,FontStyle.Bold);states[page]=Hint(page,results[page],36,44);states[page].Font=new Font(Font.FontFamily,10.5F);}
        TextBox Field(int page,string title,int top,string value="",bool secret=false)
        {Hint(page,title,top,21);var c=new TextBox {Left=16,Top=top+22,Width=575,Text=value,UseSystemPasswordChar=secret};sections[page].Controls.Add(c);return c;}
        CheckBox Check(int page,string text,int top,bool value)
        {var c=new CheckBox {Left=16,Top=top,Width=580,Height=30,Text=text,Checked=value};sections[page].Controls.Add(c);return c;}
        Button Button(int page,string text,int top,Func<Task> action,int left=16,int width=260)
        {var c=new Button {Left=left,Top=top,Width=width,Height=29,Text=text};c.Click+=async(a,b)=>{if(!busy){await Guard(action);if(lastSuccess){await ContinueServerRepair();await FinishAutomatically();}}};sections[page].Controls.Add(c);return c;}
        void Technical(int page, params Control[] controls)
        {foreach(var c in controls)details[page].Controls.Add(c);}
        void More(int page,int top=300)
        {var b=new Button {Text="Подробнее…",Left=16,Top=top,Width=120,Height=29};b.Click+=async(a,e)=>{if(busy)return;if(page==1 && !catalogLoaded)await Guard(LoadCatalog);ShowDetails(page);};sections[page].Controls.Add(b);}
        void ShowDetails(int page)
        {
            using(var form=new Form {Text=titles[page]+" — Подробнее",ClientSize=new Size(610,430),StartPosition=FormStartPosition.CenterParent,AutoScaleMode=AutoScaleMode.Dpi}) {
                details[page].Dock=DockStyle.Fill;form.Controls.Add(details[page]);form.ShowDialog(this);form.Controls.Remove(details[page]);
            }
        }
        void ShowJournal()
        {using(var form=new Form {Text="Журнал",ClientSize=new Size(610,360),StartPosition=FormStartPosition.CenterParent,AutoScaleMode=AutoScaleMode.Dpi}){form.Controls.Add(journal);form.ShowDialog(this);form.Controls.Remove(journal);}}
        void ServerPage(Dictionary<string,object> config)
        {
            Question(0,"К какому серверу подключиться?");string host="",user="root";
            try {string profile=Json.Text(Json.Map(Json.Get(config,"wizard")),"pendingProfile",Json.Str(Json.Map(Json.Get(config,"transport")),"profilePath"));
                if(profile.Length==0)profile=Files.ReadLine(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"RemoteDisk","profile.txt"));
                if(profile.Length==0){string dir=Path.Combine(home,"ssh-profiles");if(Directory.Exists(dir)){var found=Directory.GetFiles(dir,"ssh-transport.json",SearchOption.AllDirectories);if(found.Length==1)profile=found[0];}}
                if(File.Exists(profile)){var p=Json.Read(profile);host=Json.Str(p,"serverAddress");user=Json.Str(p,"login");}
            }catch{}
            address=Field(0,"Адрес",83,host);login=Field(0,"Логин",135,user);password=Field(0,"Пароль — только если ключ не работает",187,"",true);
            password.Enabled=host.Length==0;originalAddress=host;originalLogin=user;
            installMissing=Check(0,"Установить недостающие службы сервера",242,true);
            inventory=Hint(0,"Root используется только для создания рабочего пользователя remoteagents.",50,90);Technical(0,inventory);
            More(0,285);
        }
        void InvalidateServer()
        {
            if(initializing || busy)return;serverChanged=address.Text.Trim()!=originalAddress || login.Text.Trim()!=originalLogin;
            password.Enabled=true;password.Clear();
            if(serverChanged){for(int i=1;i<6;i++){applied[i]=false;results[i]="Нужно проверить для нового сервера";}catalogLoaded=treeLoaded=false;accountRows=new Dictionary<string,object>[0];
                api.Clear();web.Clear();accountKey.Clear();accounts.Items.Clear();lanCommand=lanFile="";applied[6]=false;results[6]="Не настроена (необязательно)";expectedCatalog=null;nodes.Rows.Clear();
                RefreshDiskWarning();RefreshSummary();}
        }
        void ConnectionPage()
        {
            Question(1,"Как связаться с сервером?");Hint(1,"«Далее» проверит доступные пути и сохранит рабочую связь.",90,50);
            nodes=new DataGridView {Left=12,Top=45,Width=575,Height=280,AllowUserToAddRows=true,AllowUserToDeleteRows=false,AutoSizeColumnsMode=DataGridViewAutoSizeColumnsMode.Fill};
            var kind=new DataGridViewComboBoxColumn {Name="kind",HeaderText="Тип"};kind.Items.AddRange("Вход","SSH-переход","Ретранслятор","CDN");nodes.Columns.Add(kind);
            nodes.Columns.Add("name","Имя");nodes.Columns.Add("target","SSH-алиас / хост / домен");nodes.Columns.Add("port","Порт");nodes.Columns.Add("entry","Вход для CDN");nodes.Columns.Add(new DataGridViewCheckBoxColumn {Name="enabled",HeaderText="Включён"});
            shared=Check(1,"Сохранить каталог на сервере для всех моих компьютеров",335,false);Technical(1,nodes,shared);
            var reload=new Button {Text="Обновить каталог",Left=12,Top=8,Width=170};reload.Click+=async(a,b)=>{if(!busy)await Guard(LoadCatalog);};details[1].Controls.Add(reload);
            More(1,150);
        }
        void DiskPage()
        {
            string value=Files.ReadLine(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"RemoteDisk","base.txt"));if(value.Length==0)value=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),"Disk");
            Question(2,"Какие проекты хранить на этом компьютере?");diskBase=Field(2,"Папка Disk",80,value);diskBase.ReadOnly=true;diskBase.Width=450;
            Button(2,"Изменить…",100,()=>{using(var d=new FolderBrowserDialog {SelectedPath=diskBase.Text})if(d.ShowDialog(this)==DialogResult.OK){diskBase.Text=d.SelectedPath;treeLoaded=false;}return Task.FromResult(0);},480,115);
            tree=new TreeView {Left=16,Top=135,Width=580,Height=150,CheckBoxes=true};sections[2].Controls.Add(tree);
            diskWarning=Hint(2,"",135,66);diskWarning.Visible=false;
            var reconnect=Button(2,"Отключить и подключить к новому",208,()=>{if(!reconnectDisk){reconnectDisk=true;diskBase.Text=diskBase.Text+"-"+DateTime.Now.ToString("yyyyMMddHHmmss");}RefreshDiskWarning();return Task.FromResult(0);});reconnect.Tag="reconnect";reconnect.Visible=false;
            var keep=Button(2,"Остановить синхронизацию, файлы оставить",245,()=>Skip("Disk",2),16,300);keep.Tag="keep";keep.Visible=false;
            tree.AfterCheck+=(a,e)=>{if(changingTree)return;string path=Convert.ToString(e.Node.Tag);try{if(path.Length>0)selection.Set(path,e.Node.Checked);}catch(Exception error){Append(error.Message);}RefreshTreeChecks();};
            tree.BeforeExpand+=async(a,e)=>{if(e.Node.Nodes.Count!=1 || e.Node.Nodes[0].Tag!=null)return;e.Cancel=true;if(busy)return;var node=e.Node;await Guard(async()=>{await LoadChildren(node);node.Expand();});};
            Button(2,"Загрузить проекты",292,LoadTree,16,175);Button(2,"Пропустить",292,()=>Skip("Disk",2),204,110);More(2,292);sections[2].Controls[sections[2].Controls.Count-1].Left=330;
            var info=Hint(2,"Снятие отметки не удаляет файлы. Синхронизация двусторонняя. .git, секреты и зависимости исключены. При смене сервера нужна новая пустая папка: прежняя папка остаётся на ПК.",10,130);Technical(2,info);
            diskBase.TextChanged+=(a,b)=>treeLoaded=false;
        }
        void RefreshDiskWarning()
        {
            var wizard=Json.Map(Json.Get(new Configuration(home).Data,"wizard"));bool warning=!reconnectDisk && Json.Str(wizard,"diskPreviousProfile").Length>0;
            diskWarning.Visible=warning;tree.Visible=!warning;diskWarning.Text="Диск был подключён к старому серверу. «Отключить и подключить к новому» — новая пустая папка для нового сервера; старые файлы останутся на ПК. «Остановить синхронизацию, файлы оставить» — диск не синхронизируется, файлы и прежние настройки сохраняются.";
            foreach(Control c in sections[2].Controls)if(Convert.ToString(c.Tag)=="reconnect" || Convert.ToString(c.Tag)=="keep")c.Visible=warning;
        }
        async Task Skip(string step,int index)
        {var result=await Run("Skip",new {step});applied[index]=true;dirty[index]=false;results[index]=Json.Str(result,"summary");Append(results[index]);if(first)Navigate(1);}
        void AccountPage(Dictionary<string,object> config)
        {
            var settings=Json.Map(Json.Get(config,"happier"));Question(3,"Подключить свой аккаунт Happier?");
            label=Field(3,"Имя аккаунта",83,Json.Str(settings,"label"));create=Check(3,"Создать новый аккаунт",135,false);accountKey=Field(3,"Ключ аккаунта (пусто — сохранённый)",170,"",true);
            accounts=new ListBox {Left=16,Top=12,Width=570,Height=80};
            api=Field(3,"HTTPS API Happier",105,Json.Str(settings,"serverUrl"));web=Field(3,"HTTPS Web Happier",165,Json.Str(settings,"webappUrl"));
            accountHint=Hint(3,"Ключ хранится в secrets. Для телефона используйте тот же ключ в Restore with Secret Key.",235,60);
            // Move field captions together with their inputs into Details.
            foreach(Control c in sections[3].Controls.Cast<Control>().Where(c=>c is Label && (c.Top==105 || c.Top==165)).ToArray())Technical(3,c);
            Technical(3,accounts,api,web,accountHint);
            accounts.SelectedIndexChanged+=(a,b)=>{if(accounts.SelectedIndex<0)return;var r=accountRows[accounts.SelectedIndex];label.Text=Json.Str(r,"label");if(Json.Str(r,"serverUrl").Length>0)api.Text=Json.Str(r,"serverUrl");if(Json.Str(r,"webappUrl").Length>0)web.Text=Json.Str(r,"webappUrl");};
            var reload=new Button {Text="Получить аккаунты",Left=16,Top=310,Width=180};reload.Click+=async(a,b)=>{if(!busy)await Guard(LoadAccounts);};details[3].Controls.Add(reload);
            create.CheckedChanged+=(a,b)=>accountKey.Enabled=!create.Checked;More(3,240);Button(3,"Пропустить",285,()=>Skip("Happier",3),16,120);
        }
        void BridgePage(Dictionary<string,object> config)
        {
            var c=Json.Map(Json.Get(config,"bridge"));Question(4,"Разрешить агенту управлять этим ПК?");
            bool legacy=Json.Bool(Json.Map(Json.Get(Json.Map(Json.Get(config,"components")),"control")),"enabled") || File.Exists(Path.Combine(home,"control","config.json"));
            bridge=Check(4,"Включить мост",95,Json.Bool(c,"enabled",legacy || !Json.Map(Json.Get(config,"components")).ContainsKey("control")));shell=Check(4,"Разрешить выполнение команд (shell)",135,Json.Bool(c,"allowShell",c.Count==0 && legacy));
            var info=Hint(4,"Разрешение shell позволяет выполнять команды от вашего имени. Настройка применяется на компьютере и на сервере. Изменение защищено независимым откатом.",12,100);Technical(4,info);More(4,195);
        }
        void VpnPage(Dictionary<string,object> config)
        {
            var c=Json.Map(Json.Get(config,"vpn"));Question(5,"Использовать VPN на этом компьютере?");vpn=Check(5,"Включить VPN",95,Json.Bool(c,"enabled"));
            Hint(5,"Можно оставить выключенным. Первый запуск TUN запросит UAC.",140,55);
            vpnCheck=Field(5,"Ваш HTTPS-адрес проверки VPN",20,Json.Str(c,"checkUrl"));vpnDns=Field(5,"DNS для VPN",85,Json.Str(c,"dnsServer"));
            foreach(Control control in sections[5].Controls.Cast<Control>().Where(cn=>cn.Top==20 || cn.Top==85).ToArray())Technical(5,control);
            Technical(5,vpnCheck,vpnDns);More(5,210);
        }
        void LanPage()
        {
            Question(6,"Есть ли локальная сеть по OpenVPN?");Hint(6,"Профиль копируется на сервер. Локальную сеть включает администратор сервера; сеть Windows этот шаг не меняет.",86,65);
            Button(6,"Выбрать файл .ovpn…",160,async()=>{using(var d=new OpenFileDialog {Filter="OpenVPN (*.ovpn)|*.ovpn",CheckFileExists=true})if(d.ShowDialog(this)==DialogResult.OK){lanFile=d.FileName;}if(lanFile.Length>0){var result=await Run("Lan",new {file=lanFile});lanCommand=Json.Str(result,"command");results[6]=Json.Str(result,"summary");Append(results[6]);RefreshSummary();}});
            Button(6,"Пропустить",200,()=>Skip("Lan",6));
            Button(6,"Скопировать команду",240,()=>{if(lanCommand.Length==0)throw new IOException("Сначала отправьте профиль кнопкой «Далее»");Clipboard.SetText(lanCommand);Append("Команда скопирована. При выполнении она запросит HTTPS-адрес проверки IP.");return Task.FromResult(0);});
            var state=Path.Combine(home,"state","lan-upload.json");if(File.Exists(state)){var receipt=Json.Read(state);if(Json.Str(receipt,"profile")==Json.Str(Json.Map(Json.Get(new Configuration(home).Data,"transport")),"profilePath"))lanCommand=Json.Str(receipt,"command");}
        }
        void SummaryPage(){Question(7,"Настройка завершена?");summary=Hint(7,"",85,235);}
        void Changed(int index){if(busy || initializing)return;dirty[index]=true;applied[index]=false;results[index]="Есть неприменённые изменения";RefreshSummary();}
        void RefreshSummary()
        {
            if(summary!=null)summary.Text=string.Join("\r\n",order.Where(i=>i!=7).Select(i=>titles[i]+": "+(results[i].Length>72?results[i].Substring(0,69)+"…":results[i])));
            for(int i=0;i<8;i++){if(states[i]!=null){states[i].Text=results[i];states[i].ForeColor=results[i].StartsWith("Ошибка")?Color.Firebrick:SystemColors.ControlText;}steps.Mark(i,(i<7 && applied[i])?"✓":results[i].StartsWith("Ошибка")?"✗":"…");}
            steps.Invalidate();
            RefreshDiskWarning();
        }
        void Append(string text)
        {
            journal.AppendText(DateTime.Now.ToString("HH:mm:ss")+" "+text+"\r\n");lastLine.Text=text;
            lastLine.ForeColor=text.StartsWith("Ошибка") || text.Contains(" ✗")?Color.Firebrick:SystemColors.ControlText;
            if(states[steps.Section]!=null)states[steps.Section].Text=text;
        }
        async Task Inspect()
        {
            await Guard(async()=>{
                var result=await Run("Inspect",new {});var observations=Json.Array(Json.Get(result,"steps")).Select(Json.Map).ToArray();
                for(int i=0;i<Math.Min(6,observations.Length);i++)if(!dirty[i]){applied[i]=Json.Bool(observations[i],"ready");results[i]=applied[i]?"Проверено сейчас ✓":"Требуется настройка или проверка";}
                var server=Json.Map(Json.Get(result,"server"));
                results[0]=applied[0]?"Подключено ✓":Json.Text(server,"reason","Укажите сервер и проверьте вход");
                var current=StatusView.Read(home,"transport",maxAgeSec:15);
                legacy=Json.Bool(result,"legacy");
                results[1]=legacy?(applied[1]?"Сейчас работает прежняя связь; новая проверяется при переходе (шаг «Итог»)":"Сервер недоступен по SSH"):applied[1]?"Работает через "+StatusView.Title(current):"Нет рабочего пути: "+Json.Text(current,"error","нет свежей проверки выбранного сервера");
                string failed=Json.Str(result,"migrationError");
                if(!migrationRunning)results[7]=failed.Length>0?"Ошибка: прошлый переход не выполнен. "+failed:legacy?"Найдена прежняя установка. «Готово» запустит переход с проверкой и автоматическим откатом":results[7];
                var services=Json.Map(Json.Get(server,"services"));if(api.Text.Length==0)api.Text=Json.Str(services,"serverUrl");if(web.Text.Length==0)web.Text=Json.Str(services,"webappUrl");
                var wizard=Json.Map(Json.Get(new Configuration(home).Data,"wizard"));
                applied[6]=lanCommand.Length>0 || Json.Bool(wizard,"skipLan") || Json.Bool(wizard,"configured");results[6]=lanCommand.Length>0?"Профиль отправлен; включение на сервере":"Не настроена (необязательно)";
                password.Enabled=!applied[0];
            });
        }
        async Task Guard(Func<Task> action)
        {
            lastSuccess=false;busy=true;stepCancellation=new CancellationTokenSource();steps.Enabled=false;pages.Enabled=false;foreach(var panel in details)panel.Enabled=false;back.Enabled=next.Enabled=false;close.Enabled=true;progress.Style=ProgressBarStyle.Marquee;
            try {await action();lastSuccess=true;}
            catch(OperationCanceledException) {if(steps.Section<7)applied[steps.Section]=false;results[steps.Section]="Шаг отменён; готовность не подтверждена";Append(results[steps.Section]);}
            catch(Exception e) {if(steps.Section==0)password.Enabled=true;if(steps.Section<7)applied[steps.Section]=false;results[steps.Section]="Ошибка: "+e.Message;Append(results[steps.Section]);}
            finally {busy=false;foreach(var panel in details)panel.Enabled=true;stepCancellation.Dispose();stepCancellation=null;steps.Enabled=pages.Enabled=close.Enabled=true;back.Enabled=Array.IndexOf(order,steps.Section)>0;next.Enabled=!migrationRunning;progress.Style=ProgressBarStyle.Continuous;RefreshSummary();if(closingRequested)Close();}
        }
        void WatchMigration(DateTime activation)
        {
            // Migrate.ps1 runs detached from this window and the tray: only its state files are read.
            migrationRunning=true;next.Enabled=false;migrationText="";
            migrationTimer=new System.Windows.Forms.Timer {Interval=1000};
            migrationTimer.Tick+=(a,b)=>{
                var p=MigrationProgress.Read(home,activation);
                if(p.Text!=migrationText){migrationText=p.Text;results[7]=(p.Failed?"Ошибка: ":"")+p.Text;Append(results[7]);RefreshSummary();}
                if(p.Failed){migrationTimer.Stop();migrationRunning=false;activationRequested=false;next.Enabled=true;return;}
                // The migration stops this tray next and restarts it; leave quietly so it can exit.
                if(p.Handover){migrationTimer.Stop();migrationHandover=true;DialogResult=DialogResult.OK;Close();}
            };
            migrationTimer.Start();
        }
        async Task<Dictionary<string,object>> Run(string action, object request)
        {
            string message=action=="Server"?"Подключаюсь к серверу "+address.Text.Trim()+"…":action=="Catalog"?"Загружаю узлы с сервера…":action=="DiskTree"?"Загружаю проекты Disk…":action=="Connection"?"Проверяю варианты связи…":action=="Bridge"?"Настраиваю и проверяю мост…":action=="Inspect"?"Проверяю текущее состояние в фоне…":action=="Lan"?"Копирую профиль локальной сети на сервер…":action=="Account"?"Подключаю Happier…":action=="Disk"?"Применяю выбор проектов…":action=="Vpn"?"Проверяю настройки VPN…":"Завершаю настройку…";
            Append(message);
            string requestFile=Path.Combine(home,"state","wizard-request-"+Guid.NewGuid().ToString("N")+".json"), output=requestFile+".out", live=requestFile+".progress";
            try {
                Json.Write(requestFile,request);
                var args=new[]{"-NoLogo","-NoProfile","-NonInteractive","-STA","-ExecutionPolicy","Bypass","-File",Path.Combine(bundle,"build","Wizard.ps1"),"-Home",home,"-Action",action,"-RequestFile",requestFile,"-ProgressFile",live};
                var token=stepCancellation.Token;
                int code;int readLines=0;
                using(var poll=new System.Windows.Forms.Timer {Interval=150}) {
                Action readProgress=()=>{try {if(!File.Exists(live))return;string text;using(var stream=new FileStream(live,FileMode.Open,FileAccess.Read,FileShare.ReadWrite))using(var reader=new StreamReader(stream,Files.Utf8)){text=reader.ReadToEnd();}var lines=Files.LF(text).Split('\n');while(readLines<lines.Length-1){var item=Json.Map(Json.Parse(lines[readLines++]));Append(Json.Str(item,"text"));}}catch(IOException){} };
                poll.Tick+=(s,e)=>readProgress();poll.Start();
                try {code=await Task.Run(()=>External.Run(Files.Executable("powershell.exe"),args,bundle,output,WizardStep.Timeout(action),4*1024*1024,token));}
                catch(OperationCanceledException) {new Journal(home).Write("wizard."+action+".cancelled");throw;}
                catch(TimeoutException) {new Journal(home).Write("wizard."+action+".timeout");throw;}
                poll.Stop();readProgress();
                }
                Dictionary<string,object> response;
                try {response=Json.Map(Json.Parse(Files.LF(External.ReadPowerShellOutput(output))));}
                catch {throw new IOException("Шаг не вернул результат (код "+code+"). Проверьте журнал соответствующего модуля и повторите");}
                if(code!=0 || !Json.Bool(response,"ok"))throw new IOException(Json.Text(response,"reason","Шаг не подтверждён: проверьте журнал и повторите")+". "+Json.Str(response,"remedy"));
                return Json.Map(Json.Get(response,"result"));
            } finally {if(File.Exists(requestFile))File.Delete(requestFile);if(File.Exists(output))File.Delete(output);if(File.Exists(live))File.Delete(live);}
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
            var wizard=Json.Map(Json.Get(new Configuration(home).Data,"wizard"));
            if(Json.Str(wizard,"diskPreviousProfile").Length>0 && !reconnectDisk)throw new IOException("Выберите, что делать с прежним подключением диска");
            treeLoaded=false;
            var data=await Run("DiskTree",new { @base=diskBase.Text.Trim(),path="",fresh=reconnectDisk });
            selection=new DiskTreeSelection(Json.Strings(Json.Get(Json.Map(Json.Get(data,"selection")),"paths")));
            changingTree=true;try {AddTreeLevel(Json.Map(Json.Get(data,"union")),null);treeLoaded=true;}finally{changingTree=false;}
            Append("Загружен корень Disk. Дети папки загружаются при раскрытии. Наличие в обоих местах не подтверждает совпадение содержимого.");
        }
        async Task LoadChildren(TreeNode parent)
        {
            var data=await Run("DiskTree",new { @base=diskBase.Text.Trim(),path=(string)parent.Tag });
            changingTree=true;try {AddTreeLevel(Json.Map(Json.Get(data,"union")),parent);}finally{changingTree=false;}
            string rejected=Json.Str(data,"unsupportedName");
            if(rejected.Length>0)Append("Имя «"+rejected+"» не подходит для сервера (допустимы буквы, цифры, пробел, точка, _ и -). Переименуйте папку, чтобы синхронизировать её; показано только локальное содержимое.");
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
            int index=steps.Section;bool operationReady=true;
            await Guard(async()=> {
                Dictionary<string,object> result;
                switch(index) {
                    case 0:
                        using(var relay=new PasswordRelay(password.Text)) {
                            password.Clear();
                            result=await Run("Server",new {address=address.Text.Trim(),login=login.Text.Trim(),installMissing=installMissing.Checked,passwordPipe=relay.Name,askpassExecutable=Program.Exe});
                        }
                        var saved=new Configuration(home).Data;var profile=Json.Read(Json.Text(Json.Map(Json.Get(saved,"wizard")),"pendingProfile",Json.Str(Json.Map(Json.Get(saved,"transport")),"profilePath")));login.Text=Json.Str(profile,"login");originalAddress=address.Text.Trim();originalLogin=login.Text.Trim();password.Enabled=false;
                        inventory.Text="SSH: проверен\r\n"+string.Join("\r\n",new[]{"disk","happier","bridge","catalog"}.Select(k=>(k=="disk"?"Диск-сервер":k=="happier"?"Happier (программа)":k=="bridge"?"Серверная часть моста":"Каталог узлов")+": "+(Json.Bool(result,k)?"обнаружен / проверен":"отсутствует или не отвечает")));
                        var services=Json.Map(Json.Get(result,"services"));if(api.Text.Length==0)api.Text=Json.Str(services,"serverUrl");if(web.Text.Length==0)web.Text=Json.Str(services,"webappUrl");

                        break;
                    case 1:
                        if(!catalogLoaded)await LoadCatalog();
                        result=await Run("Connection",new {catalog=ReadCatalog(),expected=expectedCatalog,shared=shared.Checked});break;
                    case 2:
                        if(!treeLoaded)await LoadTree();
                        var paths=selection.Paths;
                        result=await Run("Disk",new {@base=diskBase.Text.Trim(),paths,reconnect=reconnectDisk});break;
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
                    case 6:
                        if(lanCommand.Length>0){result=new Dictionary<string,object>{{"summary","Файл на сервере ✓; включение выполняет администратор"}};break;}
                        if(lanFile.Length==0){result=new Dictionary<string,object>{{"summary","Локальная сеть пропущена"}};break;}
                        result=await Run("Lan",new {file=lanFile});lanCommand=Json.Str(result,"command");break;
                    case 5:result=await Run("Vpn",new {enabled=vpn.Checked,checkUrl=vpnCheck.Text.Trim(),dnsServer=vpnDns.Text.Trim()});break;
                    default:
                        if(dirty.Any(v=>v))throw new IOException("Сначала примените изменённые разделы: итог проверяет сохранённые настройки");
                        var config=new Configuration(home).Data;
                        bool configured=Json.Bool(Json.Map(Json.Get(config,"wizard")),"configured");
                        if(!configured && !activationRequested){result=await Run("Activate",new {});activationRequested=true;}
                        else {result=await Run("Inspect",new {});if(!Json.Bool(result,"ok"))throw new IOException("Есть неготовые шаги. Проверьте связь и разделы с отметкой …");}
                        results[7]=Json.Text(result,"summary","Настройки сохранены");Append(results[7]);
                        if(Json.Bool(result,"migration"))WatchMigration(DateTime.UtcNow);
                        return;
                }
                bool ok=Json.Bool(result,"ok",true);operationReady=ok;applied[index]=ok;dirty[index]=false;
                results[index]=Json.Text(result,"summary",index==0?"Подключено ✓":"Готово: операция подтверждена")+(ok?"":" (ожидание, не готово)");Append(titles[index]+": "+results[index]);
            });
            lastSuccess=lastSuccess && operationReady;
        }
    }
    // Left list of settings sections with a ✓/✗/… mark; the wizard decides which clicks are allowed.
    internal sealed class WizardNavigation : ListBox
    {
        int[] order=new int[0];string[] titles=new string[0];readonly string[] marks=Enumerable.Repeat("…",8).ToArray();bool syncing;
        internal Func<int,bool> Available=i=>true;
        internal event Action<int> SectionRequested;
        internal WizardNavigation(){Dock=DockStyle.Left;Width=150;DrawMode=DrawMode.OwnerDrawFixed;IntegralHeight=false;BorderStyle=BorderStyle.None;BackColor=SystemColors.Control;ItemHeight=30;}
        internal int Section
        {
            get{return SelectedIndex<0?0:order[SelectedIndex];}
            set{int row=Array.IndexOf(order,value);if(row==SelectedIndex)return;syncing=true;try{SelectedIndex=row;}finally{syncing=false;}}
        }
        internal void Initialize(string[] titles,int[] order){this.titles=titles;this.order=order;BeginUpdate();Items.Clear();foreach(int i in order)Items.Add(titles[i]);EndUpdate();}
        internal void Mark(int i,string mark){marks[i]=mark;}
        protected override void OnFontChanged(EventArgs e){base.OnFontChanged(e);ItemHeight=Math.Max(24,Font.Height*2);}
        protected override void OnSelectedIndexChanged(EventArgs e){base.OnSelectedIndexChanged(e);Invalidate();if(!syncing && SelectedIndex>=0 && SectionRequested!=null)SectionRequested(order[SelectedIndex]);}
        protected override void OnDrawItem(DrawItemEventArgs e)
        {
            if(e.Index<0 || e.Index>=order.Length)return;
            int i=order[e.Index];bool chosen=e.Index==SelectedIndex;bool open=chosen || Available(i);
            using(var fill=new SolidBrush(chosen?SystemColors.Highlight:BackColor))e.Graphics.FillRectangle(fill,e.Bounds);
            Color fore=chosen?SystemColors.HighlightText:open && Enabled?ForeColor:SystemColors.GrayText;
            Color markColor=chosen?fore:marks[i]=="✓"?Color.ForestGreen:marks[i]=="✗"?Color.Firebrick:SystemColors.GrayText;
            int pad=e.Bounds.Height/3,markWidth=e.Bounds.Height;
            TextRenderer.DrawText(e.Graphics,titles[i],Font,new Rectangle(e.Bounds.Left+pad,e.Bounds.Top,e.Bounds.Width-pad-markWidth,e.Bounds.Height),fore,TextFormatFlags.VerticalCenter|TextFormatFlags.Left|TextFormatFlags.EndEllipsis|TextFormatFlags.NoPrefix);
            TextRenderer.DrawText(e.Graphics,marks[i],Font,new Rectangle(e.Bounds.Right-markWidth,e.Bounds.Top,markWidth,e.Bounds.Height),markColor,TextFormatFlags.VerticalCenter|TextFormatFlags.HorizontalCenter|TextFormatFlags.NoPrefix);
        }
    }

}
