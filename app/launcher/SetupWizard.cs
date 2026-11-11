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
    internal sealed partial class SetupWizard : Form
    {
        readonly string home, bundle; readonly bool first;
        readonly WizardNavigation steps = new WizardNavigation();
        readonly Panel pages = new Panel { Dock = DockStyle.Fill };
        readonly Panel[] sections = new Panel[9], details = new Panel[9];
        readonly Label[] states = new Label[9];
        readonly TextBox journal = new TextBox { Dock = DockStyle.Fill, ReadOnly = true, Multiline = true, ScrollBars = ScrollBars.Vertical };
        readonly Label lastLine = new Label { Dock = DockStyle.Fill, AutoEllipsis = true, TextAlign = ContentAlignment.MiddleLeft };
        readonly Button back = new Button { Text = "Назад", Width = 88 }, next = new Button { Text = "Далее", Width = 88 }, close = new Button { Text = "Закрыть", Width = 88 };
        readonly ProgressBar progress = new ProgressBar { Dock = DockStyle.Bottom, Height = 4 };
        readonly string[] titles = { "Сервер", "Связь", "Диск", "Happier", "Мост", "VPN", "Локальные сети", "Итог", "Выход в интернет" };
        readonly string[] results = Enumerable.Repeat("Ещё не проверено", 9).ToArray();
        readonly int[] order = {0,1,8,4,2,3,6,5,7};
        bool activationRequested, lastSuccess, reconnectDisk, serverChanged, repairingServer; int currentPage;
        readonly bool[] applied = new bool[9], dirty = new bool[9];
        TextBox address, login, password, keyFile, diskBase, label, accountKey, api, web, vpnCheck, vpnDns;
        CheckBox installMissing, shared, bridge, shell, vpn;
        RadioButton haveAccount, newAccount; Panel newKeyPanel; TextBox newKeyText; Button openHappier; Label accountKeyCaption;
        // Long server installs run detached on the server; sections wait (⏳) without blocking the next ones.
        readonly Dictionary<int,string> waiting = new Dictionary<int,string>();
        readonly List<string> tracked = new List<string>(); Dictionary<string,object> lastOperations = new Dictionary<string,object>();
        readonly Panel installPanel = new Panel { Dock = DockStyle.Fill, AutoScroll = true };
        readonly System.Windows.Forms.Timer operationTimer = new System.Windows.Forms.Timer { Interval = 12000 };
        readonly CancellationTokenSource pollCancellation = new CancellationTokenSource();
        bool pendingAccount, polling, showingInstall, resumeAccount, retryConnection;
        DataGridView nodes; TreeView tree; ListBox accounts; Label inventory, accountHint, summary, diskWarning;
        string originalAddress, originalLogin, lanCommand = "";
        Dictionary<string, object> expectedCatalog; Dictionary<string, object>[] accountRows = new Dictionary<string, object>[0];
        DiskTreeSelection selection = new DiskTreeSelection(new string[0]);
        CancellationTokenSource stepCancellation; bool closingRequested;
        bool busy, changingTree, treeLoaded, catalogLoaded, initializing;

        protected override void Dispose(bool disposing)
        {if(disposing){operationTimer.Dispose();pollCancellation.Dispose();foreach(var panel in details)if(panel!=null)panel.Dispose();journal.Dispose();}base.Dispose(disposing);}
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
                if(!form.applied[1] && Enumerable.Range(0,6).All(i=>i==1 || form.applied[i])){await Task.Delay(20000);await form.Inspect();}
                // The optional LAN step alone never opens the window.
                bool required=Enumerable.Range(0,6).All(i=>form.applied[i]);
                if(required){
                    // Everything is verified: record it without a window.
                    form.SelectPage(7);await form.ExecuteCurrent();
                    if(form.lastSuccess)return "Настройка завершена. Приложение работает в трее.";
                    // Not confirmed: show the summary with the reason instead of failing silently.
                }
                form.SelectPage(required?7:form.order.First(i=>i<6 && !form.applied[i]));
                if(form.ShowDialog()!=DialogResult.OK)return null;
                return "Настройка завершена. Приложение работает в трее.";
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
            for(int i=0;i<sections.Length;i++) {
                sections[i]=new Panel {Dock=DockStyle.Fill,AutoScroll=true};pages.Controls.Add(sections[i]);
                details[i]=new Panel {Width=575,Height=420,AutoScroll=true};
            }
            ServerPage(config);ConnectionPage();DiskPage();AccountPage(config);BridgePage(config);VpnPage(config);LanPage();SummaryPage();ProxyPage(config);
            pages.Controls.Add(installPanel);
            steps.Initialize(titles,order);steps.Available=i=>WizardStep.CanOpen(i,currentPage,first,WizardStep.Passable(applied,waiting.Keys),order);
            steps.ExtraRequested+=ShowInstall;operationTimer.Tick+=async(a,b)=>await PollOperations();
            // Settings: free clicking, the main button applies the open section. First run: walk with «Далее».
            back.Visible=first;
            foreach(int i in order.Where(x=>x!=7)) {int section=i;
                foreach(Control c in sections[i].Controls.Cast<Control>().Concat(details[i].Controls.Cast<Control>())) {
                    var t=c as TextBox;if(t!=null)t.TextChanged+=(a,b)=>Changed(section);
                    var check=c as CheckBox;if(check!=null)check.CheckedChanged+=(a,b)=>Changed(section);
                }
            }
            nodes.CellValueChanged+=(a,b)=>Changed(1);nodes.UserAddedRow+=(a,b)=>Changed(1);
            tree.AfterCheck+=(a,b)=> {if(!changingTree)Changed(2);};
            address.TextChanged+=(a,b)=>InvalidateServer();login.TextChanged+=(a,b)=>InvalidateServer();
            steps.SectionRequested+=i=> {if(WizardStep.CanOpen(i,currentPage,first,WizardStep.Passable(applied,waiting.Keys),order))SelectPage(i);else{steps.Section=currentPage;Append("Сначала завершите или пропустите раздел «"+titles[currentPage]+"»");}};
            back.Click+=(a,b)=>Navigate(-1);
            next.Click+=async(a,b)=> {
                int completed=steps.Section;
                await ExecuteCurrent();
                if(!lastSuccess || closingRequested)return;
                if(completed==0 && serverChanged){repairingServer=true;serverChanged=false;}
                if(!first){if(completed==0 && repairingServer){Navigate(1);await ContinueServerRepair();}return;}
                if(completed==7){DialogResult=DialogResult.OK;Close();return;}
                Navigate(1);await ContinueServerRepair();await FinishAutomatically();
            };
            close.Click+=(a,b)=>Close();
            FormClosing+=(a,b)=> {operationTimer.Stop();pollCancellation.Cancel();if(busy){b.Cancel=true;closingRequested=true;Append("Отменяю текущую операцию…");stepCancellation.Cancel();}else if(DialogResult!=DialogResult.OK)DialogResult=DialogResult.Cancel;};
            Shown+=async(a,b)=> {if(!first)await Inspect();};
            initializing=false;SelectPage(0);
            Append("Готов к настройке. Пароль используется один раз и не сохраняется.");
            // Reopened window: installs started earlier (even before closing the window or the PC).
            var saved=ServerOperations.Load(home);tracked.AddRange(Json.Strings(Json.Get(saved,"tracked")));lastOperations=Json.Map(Json.Get(saved,"operations"));pendingAccount=Json.Bool(saved,"pendingAccount");
            if(pendingAccount)waiting[3]="happier";RefreshInstall();if(tracked.Count>0 || pendingAccount)operationTimer.Start();
        }
        void SelectPage(int index)
        {
            if(index<0 || index>=sections.Length)return;
            showingInstall=false;if(!busy)next.Enabled=true;
            currentPage=index;steps.Section=index;sections[index].BringToFront();back.Enabled=!busy && Array.IndexOf(order,index)>0;
            next.Text=first?(index==7?"Готово":"Далее"):(index==7?"Проверить":"Применить");RefreshSummary();
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
        {if(first && steps.Section==7 && lastSuccess && !closingRequested){await ExecuteCurrent();if(lastSuccess){DialogResult=DialogResult.OK;Close();}}}
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
                if(profile.Length==0){string dir=Path.Combine(home,"ssh-profiles");if(Directory.Exists(dir)){var found=Directory.GetFiles(dir,"ssh-transport.json",SearchOption.AllDirectories);if(found.Length==1)profile=found[0];}}
                if(File.Exists(profile)){var p=Json.Read(profile);host=Json.Str(p,"serverAddress");user=Json.Str(p,"login");}
            }catch{}
            address=Field(0,"Адрес",83,host);login=Field(0,"Логин",135,user);password=Field(0,"Вход: ключ этого компьютера → выбранный файл ключа → пароль",187,"",true);password.Width=250;
            keyFile=new TextBox {Left=276,Top=209,Width=195,ReadOnly=true};sections[0].Controls.Add(keyFile);
            Button(0,"Файл ключа…",207,()=>{string dir=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),".ssh");using(var d=new OpenFileDialog {Title="Файл закрытого ключа SSH",InitialDirectory=Directory.Exists(dir)?dir:"",CheckFileExists=true})if(d.ShowDialog(this)==DialogResult.OK)keyFile.Text=d.FileName;return Task.FromResult(0);},481,110);
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
                api.Clear();web.Clear();accountKey.Clear();accounts.Items.Clear();lanCommand=proxyCommand="";applied[6]=applied[8]=false;results[6]=results[8]="Нужно проверить для нового сервера";expectedCatalog=null;nodes.Rows.Clear();
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
            haveAccount=new RadioButton {Left=16,Top=82,Width=280,Height=24,Text="У меня уже есть аккаунт",Checked=true};
            newAccount=new RadioButton {Left=300,Top=82,Width=280,Height=24,Text="Создать новый аккаунт"};
            sections[3].Controls.Add(haveAccount);sections[3].Controls.Add(newAccount);
            accountKeyCaption=Hint(3,"Секретный ключ аккаунта (пусто — сохранённый на этом компьютере)",112,21);
            accountKey=new TextBox {Left=16,Top=134,Width=575,UseSystemPasswordChar=true};sections[3].Controls.Add(accountKey);
            label=Field(3,"Имя аккаунта — чтобы различать аккаунты",160,Json.Str(settings,"label"));
            accounts=new ListBox {Left=16,Top=12,Width=570,Height=80};
            api=Field(3,"HTTPS API Happier",105,Json.Str(settings,"serverUrl"));web=Field(3,"HTTPS Web Happier",165,Json.Str(settings,"webappUrl"));
            accountHint=Hint(3,"Ключ хранится только в secrets этого компьютера и передаётся на сервер через SSH stdin. Для телефона — тот же ключ (Happier → Restore with Secret Key). Если Happier на сервере ещё устанавливается, ключ можно ввести сразу: подключение применится само.",235,70);
            // Technical fields and their captions live under «Подробнее…».
            foreach(Control c in sections[3].Controls.Cast<Control>().Where(c=>c is Label && (c.Top==105 || c.Top==165)).ToArray())Technical(3,c);
            Technical(3,accounts,api,web,accountHint);
            accounts.SelectedIndexChanged+=(a,b)=>{if(accounts.SelectedIndex<0)return;var r=accountRows[accounts.SelectedIndex];label.Text=Json.Str(r,"label");if(Json.Str(r,"serverUrl").Length>0)api.Text=Json.Str(r,"serverUrl");if(Json.Str(r,"webappUrl").Length>0)web.Text=Json.Str(r,"webappUrl");};
            var reload=new Button {Text="Получить аккаунты",Left=16,Top=310,Width=180};reload.Click+=async(a,b)=>{if(!busy)await Guard(LoadAccounts);};details[3].Controls.Add(reload);
            newAccount.CheckedChanged+=(a,b)=>{accountKey.Visible=accountKeyCaption.Visible=!newAccount.Checked;Changed(3);};
            More(3,215);Button(3,"Пропустить",215,()=>Skip("Happier",3),150,110);
            openHappier=new Button {Left=275,Top=215,Width=160,Height=29,Text="Открыть Happier",Visible=false};sections[3].Controls.Add(openHappier);
            openHappier.Click+=(a,b)=>{try{Process.Start(new ProcessStartInfo(Origin(web.Text)){UseShellExecute=true});}catch(Exception e){Append("Ошибка: "+e.Message);}};
            // A new key is shown once, right after creation; it is never written to the journal.
            newKeyPanel=new Panel {Left=16,Top=250,Width=580,Height=92,Visible=false};sections[3].Controls.Add(newKeyPanel);
            newKeyPanel.Controls.Add(new Label {Left=0,Top=0,Width=575,Height=36,Text="Сохраните ключ: он нужен для других компьютеров и телефона (Happier → Restore with Secret Key). Больше он не будет показан."});
            newKeyText=new TextBox {Left=0,Top=40,Width=455,ReadOnly=true};newKeyPanel.Controls.Add(newKeyText);
            var copy=new Button {Left=465,Top=38,Width=110,Height=27,Text="Скопировать"};newKeyPanel.Controls.Add(copy);
            copy.Click+=(a,b)=>{if(newKeyText.Text.Length>0){Clipboard.SetText(newKeyText.Text);Append("Ключ скопирован в буфер обмена");}};
            RefreshAccountButtons();
        }
        void RefreshAccountButtons()
        {if(openHappier!=null)openHappier.Visible=applied[3] && !waiting.ContainsKey(3) && web.Text.Trim().StartsWith("https://",StringComparison.OrdinalIgnoreCase);}
        void ShowNewKey(string key)
        {newKeyText.Text=key;newKeyPanel.Visible=true;}
        void BridgePage(Dictionary<string,object> config)
        {
            var c=Json.Map(Json.Get(config,"bridge"));Question(4,"Разрешить агенту управлять этим ПК?");
            bool controlOn=Json.Bool(Json.Map(Json.Get(Json.Map(Json.Get(config,"components")),"control")),"enabled");
            bridge=Check(4,"Включить мост",95,Json.Bool(c,"enabled",controlOn || !Json.Map(Json.Get(config,"components")).ContainsKey("control")));shell=Check(4,"Разрешить выполнение команд (shell)",135,Json.Bool(c,"allowShell",c.Count==0 && controlOn));
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
        void SummaryPage(){Question(7,"Настройка завершена?");summary=Hint(7,"",85,235);}
        void Changed(int index){if(busy || initializing)return;dirty[index]=true;applied[index]=false;results[index]="Есть неприменённые изменения";RefreshSummary();}
        void RefreshSummary()
        {
            if(summary!=null)summary.Text=string.Join("\r\n",order.Where(i=>i!=7).Select(i=>titles[i]+": "+(results[i].Length>72?results[i].Substring(0,69)+"…":results[i])));
            for(int i=0;i<sections.Length;i++){if(states[i]!=null){states[i].Text=results[i];states[i].ForeColor=results[i].StartsWith("Ошибка")?Color.Firebrick:SystemColors.ControlText;}steps.Mark(i,(i!=7 && applied[i])?"✓":waiting.ContainsKey(i)?"⏳":results[i].StartsWith("Ошибка")?"✗":"…");}
            RefreshAccountButtons();
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
                results[1]=applied[1]?"Работает через "+StatusView.Title(current):"Нет рабочего пути: "+Json.Text(current,"error","нет свежей проверки выбранного сервера");
                var services=Json.Map(Json.Get(server,"services"));if(api.Text.Length==0)api.Text=Json.Str(services,"serverUrl");if(web.Text.Length==0)web.Text=Json.Str(services,"webappUrl");
                pendingAccount=Json.Bool(result,"pendingAccount");TrackServer(Json.Map(Json.Get(server,"operations")));
                var wizard=Json.Map(Json.Get(new Configuration(home).Data,"wizard"));
                InspectNetwork(wizard);
                password.Enabled=!applied[0];
            });
        }
        async Task Guard(Func<Task> action, int section = -1)
        {
            int page=section<0?steps.Section:section;
            lastSuccess=false;busy=true;stepCancellation=new CancellationTokenSource();steps.Enabled=false;pages.Enabled=false;foreach(var panel in details)panel.Enabled=false;back.Enabled=next.Enabled=false;close.Enabled=true;progress.Style=ProgressBarStyle.Marquee;
            try {await action();lastSuccess=true;}
            catch(OperationCanceledException) {if(page!=7)applied[page]=false;results[page]="Шаг отменён; готовность не подтверждена";Append(results[page]);}
            catch(Exception e) {if(page==0)password.Enabled=true;if(page!=7)applied[page]=false;results[page]="Ошибка: "+e.Message;Append(results[page]);}
            finally {busy=false;foreach(var panel in details)panel.Enabled=true;stepCancellation.Dispose();stepCancellation=null;steps.Enabled=pages.Enabled=close.Enabled=true;back.Enabled=Array.IndexOf(order,steps.Section)>0;next.Enabled=!showingInstall;progress.Style=ProgressBarStyle.Continuous;RefreshSummary();if(closingRequested)Close();}
        }
        async Task<Dictionary<string,object>> Run(string action, object request, CancellationToken? quiet = null)
        {
            string message=action=="Server"?"Подключаюсь к серверу "+address.Text.Trim()+"…":action=="Catalog"?"Загружаю узлы с сервера…":action=="DiskTree"?"Загружаю проекты Disk…":action=="Connection"?"Проверяю варианты связи…":action=="Bridge"?"Настраиваю и проверяю мост…":action=="Inspect"?"Проверяю текущее состояние в фоне…":action=="Lan"?"Подключаю локальную сеть…":action=="Proxy"?"Настраиваю выход сервера в интернет…":action=="NetStatus"?"Проверяю состояние сетей сервера…":action=="AdminProbe"?"Проверяю права root на сервере…":action=="LanRemove"?"Удаляю локальную сеть…":action=="Account"?"Подключаю Happier…":action=="ResumeAccount"?"Happier установлен: подключаю аккаунт…":action=="Disk"?"Применяю выбор проектов…":action=="Vpn"?"Проверяю настройки VPN…":"Завершаю настройку…";
            if(quiet==null)Append(message);
            string requestFile=Path.Combine(home,"state","wizard-request-"+Guid.NewGuid().ToString("N")+".json"), output=requestFile+".out", live=requestFile+".progress";
            try {
                Json.Write(requestFile,request);
                var args=new[]{"-NoLogo","-NoProfile","-NonInteractive","-STA","-ExecutionPolicy","Bypass","-File",Path.Combine(bundle,"build","Wizard.ps1"),"-Home",home,"-Action",action,"-RequestFile",requestFile,"-ProgressFile",live};
                var token=quiet ?? stepCancellation.Token;
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
        // Common result handling: ok — ready ✓; «pending» — waits for a detached server install (⏳),
        // which does not block the next sections and completes by itself.
        bool ApplyResult(int index, Dictionary<string,object> result)
        {
            bool ok=Json.Bool(result,"ok",true);string pending=Json.Str(result,"pending");
            applied[index]=ok;dirty[index]=false;
            if(pending.Length>0){waiting[index]=pending;TrackOperation(pending);}else waiting.Remove(index);
            if(index==3){pendingAccount=pending=="happier";if(ok)newKeyPanel.Visible=newKeyText.Text.Length>0;}
            results[index]=Json.Text(result,"summary",index==0?"Подключено ✓":"Готово: операция подтверждена")+(ok || pending.Length>0?"":" (ожидание, не готово)");Append(titles[index]+": "+results[index]);
            RefreshInstall();
            return ok || pending.Length>0;
        }
        // Server step / inspection: installs running on the server are tracked by their sections.
        void TrackServer(Dictionary<string,object> operations)
        {
            foreach(var pair in new[]{new KeyValuePair<string,int>("disk",2),new KeyValuePair<string,int>("happier",3)}) {
                var op=Json.Map(Json.Get(operations,pair.Key));if(Json.Str(op,"state")!="running")continue;
                lastOperations[pair.Key]=op;TrackOperation(pair.Key);
                if(!applied[pair.Value]){waiting[pair.Value]=pair.Key;results[pair.Value]=Json.Str(op,"text");}
            }
            if(pendingAccount){waiting[3]="happier";TrackOperation("happier");}
            RefreshInstall();
        }
        // API for other sections (e.g. LAN): follow a detached server operation in «Установка».
        internal void TrackOperation(string name)
        {
            if(name==ServerOperations.Account || tracked.Contains(name))return;
            // A new batch replaces the list of already finished installs.
            if(!ServerOperations.Active(ServerOperations.Parse(lastOperations,tracked,pendingAccount)))tracked.Clear();
            tracked.Add(name);SaveOperations();RefreshInstall();operationTimer.Start();
        }
        void SaveOperations(){try{ServerOperations.Save(home,tracked,lastOperations,pendingAccount);}catch(Exception){}}
        async Task PollOperations(string start = null)
        {
            if(polling || closingRequested || (tracked.Count==0 && !pendingAccount)){if(tracked.Count==0 && !pendingAccount)operationTimer.Stop();return;}
            polling=true;
            try {
                var names=tracked.Concat(pendingAccount?new[]{"happier"}:new string[0]).Distinct().ToArray();
                var result=await Run("Operation",new {operations=names,start},pollCancellation.Token);
                lastOperations=Json.Map(Json.Get(result,"operations"));pendingAccount=Json.Bool(result,"pendingAccount");
                // A restarted («Повторить») install makes its section wait again.
                foreach(var pair in new[]{new KeyValuePair<string,int>("disk",2),new KeyValuePair<string,int>("happier",3)})if(Json.Str(Json.Map(Json.Get(lastOperations,pair.Key)),"state")=="running" && !applied[pair.Value])waiting[pair.Value]=pair.Key;
                foreach(var pair in waiting.ToArray()) {
                    var op=Json.Map(Json.Get(lastOperations,pair.Value));string state=Json.Str(op,"state");
                    if(state=="running"){results[pair.Key]=Json.Str(op,"text")+(pair.Key==3 && pendingAccount?". Ключ сохранён: подключение применится автоматически":"");continue;}
                    waiting.Remove(pair.Key);
                    if(state=="failed"){results[pair.Key]=Json.Str(op,"text");applied[pair.Key]=false;continue;}
                    if(pair.Key==3 && pendingAccount)resumeAccount=true;
                    else if(pair.Key==1)retryConnection=true;
                    else if(!applied[pair.Key])results[pair.Key]=pair.Key==3?"Happier установлен на сервере. Подключите аккаунт":"Сервер диска установлен. Выберите проекты";
                }
                SaveOperations();RefreshSummary();RefreshInstall();
            } catch(OperationCanceledException) {}
            catch(Exception e) {lastLine.Text="Состояние установки на сервере не получено: "+e.Message+". Повторю позже";}
            finally {polling=false;}
            // Dependent parts complete by themselves once the window is free.
            if(!busy && !closingRequested && resumeAccount){resumeAccount=false;await Guard(async()=>{var r=await Run("ResumeAccount",new {});ApplyResult(3,r);},3);SaveOperations();RefreshInstall();}
            if(!busy && !closingRequested && retryConnection){retryConnection=false;await ExecuteSection(1);}
        }
        void ShowInstall()
        {showingInstall=true;installPanel.BringToFront();next.Enabled=false;RefreshInstall();}
        void RefreshInstall()
        {
            var list=ServerOperations.Parse(lastOperations,tracked,pendingAccount);bool visible=ServerOperations.Visible(list);
            steps.SetExtra(visible?"Установка":null,list.Any(o=>o.State=="failed")?"✗":"⏳");
            if(!visible && showingInstall){SelectPage(currentPage);return;}
            if(!visible)return;
            installPanel.SuspendLayout();
            foreach(Control c in installPanel.Controls.Cast<Control>().ToArray()){installPanel.Controls.Remove(c);c.Dispose();}
            installPanel.Controls.Add(new Label {Left=16,Top=8,Width=585,Height=26,Text="Установка на сервере",Font=new Font(Font.FontFamily,12F,FontStyle.Bold)});
            installPanel.Controls.Add(new Label {Left=16,Top=36,Width=585,Height=40,Text="Долгие операции идут на сервере. Окно можно свернуть или закрыть, компьютер — выключить: установка не прервётся. Пункт исчезнет, когда всё будет готово."});
            int top=84;
            foreach(var op in list) {
                installPanel.Controls.Add(new Label {Left=16,Top=top,Width=585,Height=20,Text=op.Title,Font=new Font(Font,FontStyle.Bold)});
                installPanel.Controls.Add(new Label {Left=16,Top=top+20,Width=op.State=="failed"?470:585,Height=36,Text=ServerOperations.Line(op),ForeColor=op.State=="failed"?Color.Firebrick:SystemColors.ControlText});
                if(op.State=="failed" && op.Name!=ServerOperations.Account){string name=op.Name;var retry=new Button {Left=495,Top=top+18,Width=100,Height=27,Text="Повторить"};retry.Click+=async(a,b)=>await PollOperations(name);installPanel.Controls.Add(retry);}
                top+=62;
            }
            installPanel.ResumeLayout();
        }
        async Task LoadCatalog()
        {
            var catalog=await Run("Catalog",new {});expectedCatalog=catalog;catalogLoaded=true;nodes.Rows.Clear();
            var config=new Configuration(home).Data;var wizard=Json.Map(Json.Get(config,"wizard"));
            var local=Json.Map(Json.Get(wizard,"localCatalog"));
            if(!wizard.ContainsKey("localCatalog"))local=Json.Map(Json.Get(config,"transport"));
            foreach(string group in new[]{"entries","hops","relays","cdn"}) {
                var rows=Json.Array(Json.Get(catalog,group)).Select(Json.Map).ToList();
                foreach(var row in Json.Array(Json.Get(local,group)).Select(Json.Map)){var clean=new Dictionary<string,object>(row);clean.Remove("configPath");if(!clean.ContainsKey("ssh") && clean.ContainsKey("alias")){clean["ssh"]=clean["alias"];clean.Remove("alias");}if(!clean.ContainsKey("host") && clean.ContainsKey("server")){clean["host"]=clean["server"];clean.Remove("server");}rows.RemoveAll(r=>Json.Str(r,"name")==Json.Str(row,"name"));rows.Add(clean);}
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
        async Task ExecuteCurrent() {await ExecuteSection(steps.Section);}
        async Task ExecuteSection(int index)
        {
            bool operationReady=true;
            await Guard(async()=> {
                Dictionary<string,object> result;
                switch(index) {
                    case 0:
                        using(var relay=new PasswordRelay(password.Text)) {
                            password.Clear();
                            result=await Run("Server",new {address=address.Text.Trim(),login=login.Text.Trim(),installMissing=installMissing.Checked,keyFile=keyFile.Text,passwordPipe=relay.Name,askpassExecutable=Program.Exe});
                        }
                        var saved=new Configuration(home).Data;var profile=Json.Read(Json.Text(Json.Map(Json.Get(saved,"wizard")),"pendingProfile",Json.Str(Json.Map(Json.Get(saved,"transport")),"profilePath")));login.Text=Json.Str(profile,"login");originalAddress=address.Text.Trim();originalLogin=login.Text.Trim();password.Enabled=false;
                        inventory.Text="SSH: проверен\r\n"+string.Join("\r\n",new[]{"disk","happier","bridge","catalog"}.Select(k=>(k=="disk"?"Диск-сервер":k=="happier"?"Happier (программа)":k=="bridge"?"Серверная часть моста":"Каталог узлов")+": "+(Json.Bool(result,k)?"обнаружен / проверен":"отсутствует или не отвечает")));
                        var services=Json.Map(Json.Get(result,"services"));if(api.Text.Length==0)api.Text=Json.Str(services,"serverUrl");if(web.Text.Length==0)web.Text=Json.Str(services,"webappUrl");
                        TrackServer(Json.Map(Json.Get(result,"operations")));

                        break;
                    case 1:
                        if(!catalogLoaded)await LoadCatalog();
                        result=await Run("Connection",new {catalog=ReadCatalog(),expected=expectedCatalog,shared=shared.Checked});break;
                    case 2:
                        if(!treeLoaded)await LoadTree();
                        var paths=selection.Paths;
                        result=await Run("Disk",new {@base=diskBase.Text.Trim(),paths,reconnect=reconnectDisk});break;
                    case 3: {
                        string apiOrigin=Origin(api.Text),webOrigin=Origin(web.Text);if(string.IsNullOrWhiteSpace(label.Text))throw new IOException("Укажите имя аккаунта, чтобы различать аккаунты");
                        bool create=newAccount.Checked;string key=create?HappierKey.Create():accountKey.Text.Trim();
                        string expectedAccount=!create && accounts.SelectedIndex>=0?Json.Str(accountRows[accounts.SelectedIndex],"account"):"";
                        // The key waits in secrets/happier-pending.key; Wizard.ps1 applies it now or after the install.
                        if(key.Length>0){AccountDiskSetup.SaveKey(home,key,"happier-pending.key");accountKey.Clear();}
                        try {result=await Run("Account",new {label=label.Text.Trim(),serverUrl=apiOrigin,webappUrl=webOrigin,expectedAccount});}
                        catch {
                            // A never shown new key must not be connected later by the automatic resume.
                            if(create){foreach(var f in new[]{Path.Combine(home,"secrets","happier-pending.key"),Path.Combine(home,"state","happier-pending.json")})if(File.Exists(f))File.Delete(f);}
                            throw;
                        }
                        if(create){ShowNewKey(key);haveAccount.Checked=true;}
                        break; }
                    case 4:result=await Run("Bridge",new {enabled=bridge.Checked,shell=shell.Checked});break;
                    case 6:result=await ExecuteLan();break;
                    case 8:result=await ExecuteProxy();break;
                    case 5:result=await Run("Vpn",new {enabled=vpn.Checked,checkUrl=vpnCheck.Text.Trim(),dnsServer=vpnDns.Text.Trim()});break;
                    default:
                        if(dirty.Any(v=>v))throw new IOException("Сначала примените изменённые разделы: итог проверяет сохранённые настройки");
                        var config=new Configuration(home).Data;
                        bool configured=Json.Bool(Json.Map(Json.Get(config,"wizard")),"configured");
                        if(!configured && !activationRequested){result=await Run("Activate",new {});activationRequested=true;}
                        else {result=await Run("Inspect",new {});if(!Json.Bool(result,"ok"))throw new IOException("Есть неготовые шаги. Проверьте связь и разделы с отметкой …");}
                        results[7]=Json.Text(result,"summary","Настройки сохранены");Append(results[7]);
                        return;
                }
                operationReady=ApplyResult(index,result);
            },index);
            lastSuccess=lastSuccess && operationReady;
        }
    }
    // Left list of settings sections with a ✓/✗/… mark; the wizard decides which clicks are allowed.
    internal sealed class WizardNavigation : ListBox
    {
        int[] order=new int[0];string[] titles=new string[0];readonly string[] marks=Enumerable.Repeat("…",9).ToArray();bool syncing;
        // Optional last row «Установка»: shown only while server installs run, wait or failed.
        string extraTitle, extraMark="⏳";int lastSection;
        internal Func<int,bool> Available=i=>true;
        internal event Action<int> SectionRequested;
        internal event Action ExtraRequested;
        internal void SetExtra(string title,string mark)
        {
            if(title==extraTitle && mark==extraMark)return;
            extraMark=mark;
            if(title!=extraTitle){
                extraTitle=title;bool chosen=SelectedIndex>=order.Length;syncing=true;
                try{if(title==null){if(Items.Count>order.Length)Items.RemoveAt(order.Length);if(chosen)SelectedIndex=Array.IndexOf(order,lastSection);}else if(Items.Count==order.Length)Items.Add(title);}
                finally{syncing=false;}
            }
            Invalidate();
        }
        internal WizardNavigation(){Dock=DockStyle.Left;Width=150;DrawMode=DrawMode.OwnerDrawFixed;IntegralHeight=false;BorderStyle=BorderStyle.None;BackColor=SystemColors.Control;ItemHeight=30;}
        internal int Section
        {
            get{return SelectedIndex<0?0:SelectedIndex>=order.Length?lastSection:order[SelectedIndex];}
            set{lastSection=value;int row=Array.IndexOf(order,value);if(row==SelectedIndex)return;syncing=true;try{SelectedIndex=row;}finally{syncing=false;}}
        }
        internal void Initialize(string[] titles,int[] order){this.titles=titles;this.order=order;BeginUpdate();Items.Clear();foreach(int i in order)Items.Add(titles[i]);EndUpdate();}
        internal void Mark(int i,string mark){marks[i]=mark;}
        protected override void OnFontChanged(EventArgs e){base.OnFontChanged(e);ItemHeight=Math.Max(24,Font.Height*2);}
        protected override void OnSelectedIndexChanged(EventArgs e)
        {
            base.OnSelectedIndexChanged(e);Invalidate();if(syncing || SelectedIndex<0)return;
            if(SelectedIndex>=order.Length){if(ExtraRequested!=null)ExtraRequested();return;}
            if(SectionRequested!=null)SectionRequested(order[SelectedIndex]);
        }
        protected override void OnDrawItem(DrawItemEventArgs e)
        {
            if(e.Index<0 || e.Index>order.Length || (e.Index==order.Length && extraTitle==null))return;
            bool extra=e.Index==order.Length;int i=extra?-1:order[e.Index];bool chosen=e.Index==SelectedIndex;bool open=chosen || extra || Available(i);
            string title=extra?extraTitle:titles[i],mark=extra?extraMark:marks[i];
            using(var fill=new SolidBrush(chosen?SystemColors.Highlight:BackColor))e.Graphics.FillRectangle(fill,e.Bounds);
            Color fore=chosen?SystemColors.HighlightText:open && Enabled?ForeColor:SystemColors.GrayText;
            Color markColor=chosen?fore:mark=="✓"?Color.ForestGreen:mark=="✗"?Color.Firebrick:mark=="⏳"?Color.DarkGoldenrod:SystemColors.GrayText;
            int pad=e.Bounds.Height/3,markWidth=e.Bounds.Height;
            TextRenderer.DrawText(e.Graphics,title,Font,new Rectangle(e.Bounds.Left+pad,e.Bounds.Top,e.Bounds.Width-pad-markWidth,e.Bounds.Height),fore,TextFormatFlags.VerticalCenter|TextFormatFlags.Left|TextFormatFlags.EndEllipsis|TextFormatFlags.NoPrefix);
            TextRenderer.DrawText(e.Graphics,mark,Font,new Rectangle(e.Bounds.Right-markWidth,e.Bounds.Top,markWidth,e.Bounds.Height),markColor,TextFormatFlags.VerticalCenter|TextFormatFlags.HorizontalCenter|TextFormatFlags.NoPrefix);
        }
    }

}
