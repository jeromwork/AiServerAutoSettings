using System.Diagnostics;
using System.IO.Pipes;
using System.Net.NetworkInformation;
using System.Reflection;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using Microsoft.Win32;
using RemoteAgents.Core;
using RemoteAgents.Tray;

var data=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"RemoteAgents");
var appData=Path.Combine(data,"app-v1");Directory.CreateDirectory(appData);
var hostFile=Path.Combine(appData,"host-id.txt");
if(!File.Exists(hostFile))File.WriteAllText(hostFile,"host-"+Guid.NewGuid().ToString("N"));
var journal=new Journal(Path.Combine(data,"logs"),File.ReadAllText(hostFile).Trim());
journal.Write("app","start","begin"); // Before config, UI, mutex, resources or network.
var identity=Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(WindowsIdentity.GetCurrent().User!.Value)))[..24];
var pipeName="RemoteAgents.V1."+identity;
using var mutex=new Mutex(true,"Local\\"+pipeName,out var created);
if(!created) {
    try { using var pipe=new NamedPipeClientStream(".",pipeName,PipeDirection.Out,PipeOptions.CurrentUserOnly);pipe.Connect(3000);using var writer=new StreamWriter(pipe);writer.WriteLine(JsonSerializer.Serialize(args)); }
    catch {journal.Write("ipc","forward","failed");}
    return;
}
ApplicationConfiguration.Initialize();
try {Application.Run(new TrayContext(data,appData,journal,pipeName,args));}
catch {journal.Write("app","fatal","failed");MessageBox.Show("Приложение не запустилось. Проверьте локальный журнал RemoteAgents.");}

sealed class TrayContext : ApplicationContext
{
    readonly NotifyIcon icon=new(){Visible=true,Text="RemoteAgents: запуск",Icon=System.Drawing.SystemIcons.Information};
    readonly System.Windows.Forms.Timer timer=new(){Interval=5000};
    readonly Control dispatch=new();
    readonly CancellationTokenSource stop=new();
    readonly Dictionary<string,ManagedRuntime> runtimes=[];
    readonly Dictionary<SyncState,System.Drawing.Icon> icons=[];
    readonly string data,appData,configPath,binary;
    readonly Journal journal;
    readonly AppConfig config;
    readonly Task pipeTask;
    bool busy,closing;
    SyncState previous=SyncState.Disconnected;
    DateTimeOffset nextUpload=DateTimeOffset.MinValue;
    public TrayContext(string data,string appData,Journal journal,string pipeName,string[] args)
    {
        this.data=data;this.appData=appData;this.journal=journal;configPath=Path.Combine(appData,"config.json");
        dispatch.CreateControl();
        config=AppConfig.Load(configPath);config.HostId=File.ReadAllText(Path.Combine(appData,"host-id.txt")).Trim();config.Save(configPath);
        binary=EngineResource.Extract(Assembly.GetExecutingAssembly(),"syncthing.exe",Path.Combine(data,"engine",EngineResource.Version,"syncthing.exe"),EngineResource.WindowsSha256);
        journal.Write("engine","verify","ok");
        foreach(var state in Enum.GetValues<SyncState>())icons[state]=MakeIcon(state);
        LoadRuntimes();BuildMenu();
        timer.Tick+=async(_,_)=>await Poll();timer.Start();
        SystemEvents.PowerModeChanged+=PowerChanged;NetworkChange.NetworkAvailabilityChanged+=NetworkChanged;
        pipeTask=ReceiveCommands(pipeName,stop.Token);
        dispatch.BeginInvoke(async()=>{await Handle(args);await Poll();});
    }
    void LoadRuntimes()
    {
        if(config.Profile==null)return;
        foreach(var folder in config.Folders.Where(f=>f.Enabled)) {
            try {runtimes[folder.Id]=new(folder,config.Profile,journal,binary,Path.Combine(appData,"workers"));}
            catch {journal.Write("runtime","load","failed");}
        }
    }
    async Task ReceiveCommands(string name,CancellationToken token)
    {
        while(!token.IsCancellationRequested) {
            try {
                using var server=new NamedPipeServerStream(name,PipeDirection.In,1,PipeTransmissionMode.Byte,PipeOptions.Asynchronous|PipeOptions.CurrentUserOnly);
                await server.WaitForConnectionAsync(token);using var reader=new StreamReader(server);
                using var timeout=CancellationTokenSource.CreateLinkedTokenSource(token);timeout.CancelAfter(TimeSpan.FromSeconds(3));
                var line=await reader.ReadLineAsync(timeout.Token);
                if(line is {Length:<32768}) {var args=JsonSerializer.Deserialize<string[]>(line);if(args!=null)dispatch.BeginInvoke(async()=>await Handle(args));}
            } catch(OperationCanceledException) { } catch {journal.Write("ipc","receive","failed");}
        }
    }
    void BuildMenu()
    {
        var old=icon.ContextMenuStrip;var menu=new ContextMenuStrip();
        var folders=new ToolStripMenuItem("Папки");
        foreach(var f in config.Folders) {
            var entry=new ToolStripMenuItem(Path.GetFileName(f.LocalPath)+(f.Enabled?"":" (отключена)"));
            entry.DropDownItems.Add("Показать статус",null,(_,_)=>ShowStatus(f));
            entry.DropDownItems.Add("Открыть папку",null,(_,_)=>Open(f.LocalPath));
            entry.DropDownItems.Add("Пауза на 30 минут",null,async(_,_)=>await Pause([f],TimeSpan.FromMinutes(30)));
            entry.DropDownItems.Add("Пауза на 2 часа",null,async(_,_)=>await Pause([f],TimeSpan.FromHours(2)));
            entry.DropDownItems.Add("Пауза до включения",null,async(_,_)=>await Pause([f],null,true));
            entry.DropDownItems.Add("Возобновить",null,async(_,_)=>await Pause([f],null));
            entry.DropDownItems.Add("Исключения / подпапки",null,async(_,_)=>await Exclusions(f));
            entry.DropDownItems.Add("Версии",null,async(_,_)=>await Versions(f));
            entry.DropDownItems.Add("Отключить, файлы останутся",null,(_,_)=>Disconnect(f));folders.DropDownItems.Add(entry);
        }
        menu.Items.Add(folders);
        menu.Items.Add("Подключить тестовую папку…",null,async(_,_)=>await Connect(null));
        menu.Items.Add("Существующие подключения (только просмотр)",null,(_,_)=>MessageBox.Show(string.Join(Environment.NewLine,SyncDiscovery.Find(data).Select(p=>$"{p.ProjectId}: {p.ReplicaPath}")) is {Length:>0} text?text:"Существующих подключений нет."));
        menu.Items.Add("Последние файлы",null,(_,_)=>MessageBox.Show(string.Join(Environment.NewLine,runtimes.Values.SelectMany(r=>r.RecentFiles))));
        menu.Items.Add("Пауза всех на 30 минут",null,async(_,_)=>await Pause(config.Folders,TimeSpan.FromMinutes(30)));
        menu.Items.Add("Пауза всех на 2 часа",null,async(_,_)=>await Pause(config.Folders,TimeSpan.FromHours(2)));
        menu.Items.Add("Пауза всех до включения",null,async(_,_)=>await Pause(config.Folders,null,true));
        menu.Items.Add("Возобновить все",null,async(_,_)=>await Pause(config.Folders,null));
        menu.Items.Add("Ошибки и конфликты",null,(_,_)=>MessageBox.Show(string.Join(Environment.NewLine,config.Folders.Select(f=>Describe(f)))));
        menu.Items.Add("Настройки",null,(_,_)=>Settings());
        menu.Items.Add("Журнал",null,(_,_)=>Open(journal.DirectoryPath));
        menu.Items.Add("Собрать диагностику",null,(_,_)=>Diagnostics());
        menu.Items.Add("Выход",null,(_,_)=>ExitThread());icon.ContextMenuStrip=menu;old?.Dispose();
    }
    async Task Poll()
    {
        if(busy||closing)return;busy=true;
        try {
            foreach(var runtime in runtimes.Values.ToArray())await runtime.TickAsync(stop.Token);
            var statuses=config.Folders.Where(f=>f.Enabled).Select(f=>runtimes.TryGetValue(f.Id,out var r)?r.Status:new SyncStatus(SyncState.Error,Detail:"Движок не загружен")).ToArray();
            SyncState[] priority=[SyncState.Error,SyncState.Conflict,SyncState.Disconnected,SyncState.Transferring,SyncState.Paused,SyncState.Synced];
            var state=statuses.Length==0?SyncState.Disconnected:priority.First(s=>statuses.Any(x=>x.State==s));
            var transfer=statuses.FirstOrDefault(s=>s.State==SyncState.Transferring);
            string text="RemoteAgents: "+StateText(state)+(transfer==null?"":$" {transfer.Percent:F0}% {transfer.BytesDone}/{transfer.BytesTotal} Б, {transfer.BytesPerSecond:F0} Б/с");
            icon.Text=text[..Math.Min(63,text.Length)];icon.Icon=icons[state];
            if(state!=previous) {journal.Write("tray","state",state.ToString().ToLowerInvariant());if(state is SyncState.Error or SyncState.Conflict or SyncState.Disconnected)icon.ShowBalloonTip(5000,"RemoteAgents",StateText(state),ToolTipIcon.Warning);previous=state;}
            if(DateTimeOffset.UtcNow>=nextUpload&&config.Profile!=null&&config.ServerLogDirectory is {Length:>0} root) {
                nextUpload=DateTimeOffset.UtcNow.AddMinutes(1);
                // Independent short SSH launches; cap each batch to preserve UI responsiveness.
                var ssh=new SshTransport(config.Profile,journal);
                using var upload=CancellationTokenSource.CreateLinkedTokenSource(stop.Token);upload.CancelAfter(TimeSpan.FromSeconds(20));
                _=SendLogs(ssh,root,upload.Token); // SendLogs owns its own timeout below.
            }
        } catch {journal.Write("app","poll","failed");} finally {busy=false;}
    }
    bool sending;
    async Task SendLogs(SshTransport ssh,string root,CancellationToken ignored)
    {
        if(sending)return;sending=true;
        try {using var timeout=CancellationTokenSource.CreateLinkedTokenSource(stop.Token);timeout.CancelAfter(TimeSpan.FromSeconds(20));int sent=0;await journal.FlushQueueAsync(async(text,token)=>++sent<=50&&await ssh.UploadLogAsync(text,root,config.HostId,token),timeout.Token);}
        catch {journal.Write("logs","upload","deferred");} finally {sending=false;}
    }
    static string StateText(SyncState s)=>s switch{SyncState.Synced=>"синхронизировано",SyncState.Transferring=>"идёт передача",SyncState.Paused=>"пауза",SyncState.Disconnected=>"нет подключения",SyncState.Conflict=>"конфликт",_=>"ошибка"};
    string Describe(ManagedFolder f)=>$"{f.LocalPath}: "+(!f.Enabled?"отключена":runtimes.TryGetValue(f.Id,out var r)?$"{StateText(r.Status.State)}; {r.Status.Percent:F1}%; {r.Status.BytesDone}/{r.Status.BytesTotal} Б; {r.Status.BytesPerSecond:F0} Б/с\n{r.Status.Detail}\n"+string.Join('\n',r.Conflicts):"не удалось загрузить движок");
    void ShowStatus(ManagedFolder f)=>MessageBox.Show(Describe(f),"RemoteAgents");
    async Task Pause(IEnumerable<ManagedFolder> folders,TimeSpan? duration,bool until=false)
    {
        foreach(var f in folders.Where(f=>f.Enabled))try {if(runtimes.TryGetValue(f.Id,out var r))await r.PauseAsync(duration,until);}catch{journal.Write("user","pause","failed");MessageBox.Show("Не удалось подтвердить паузу движка. См. журнал.");}
        Save();await Poll();
    }
    void Disconnect(ManagedFolder f)
    {
        f.Enabled=false;if(runtimes.Remove(f.Id,out var r))r.Dispose();journal.Write("user","disconnect","files-preserved");Save();
        MessageBox.Show("Локальная передача остановлена, файлы сохранены. Серверный процесс не удалён и не остановлен.");
    }
    void Save(){config.Save(configPath);WindowsIntegration.RegisterMenus(config);BuildMenu();}
    void Settings()
    {
        using var form=new Form{Text="Настройки",Width=560,Height=260,StartPosition=FormStartPosition.CenterScreen};
        var auto=new CheckBox{Text="Запускать при входе в Windows",Checked=config.AutoStart,Dock=DockStyle.Top};
        var context=new CheckBox{Text="Контекстное меню Проводника (HKCU)",Checked=config.ContextMenu,Dock=DockStyle.Top};
        var import=new Button{Text="Импорт существующего ssh-transport.json (без изменения)",Dock=DockStyle.Top,Height=40};
        import.Click+=(_,_)=>{using var dialog=new OpenFileDialog{Filter="Профиль SSH|*.json"};if(dialog.ShowDialog()!=DialogResult.OK)return;try{config.Profile=SshProfile.Import(dialog.FileName);config.Profile.Arguments();journal.Write("user","profile-import","ok");MessageBox.Show("Профиль импортирован. Ключ не читался, подключения не мигрировались. Перезапустите приложение, если есть новые управляемые папки.");}catch{MessageBox.Show("Профиль не принят: проверьте формат и параметры.");}};
        var rates=new Button{Text="Ограничение скорости (КиБ/с; 0 — без ограничения)",Dock=DockStyle.Top,Height=40};
        rates.Click+=async(_,_)=>{var values=Ask("Скорость",[("Отправка","0"),("Приём","0")]);if(values==null)return;if(!int.TryParse(values[0],out int send)||!int.TryParse(values[1],out int receive)||send<0||receive<0)return;try{foreach(var r in runtimes.Values)await r.Api.SetRatesAsync(send,receive);journal.Write("user","rates","applied");}catch{MessageBox.Show("Лимит не подтверждён движком.");}};
        var save=new Button{Text="Сохранить",Dock=DockStyle.Bottom};save.Click+=(_,_)=>{config.AutoStart=auto.Checked;config.ContextMenu=context.Checked;WindowsIntegration.AutoStart(config.AutoStart);Save();form.Close();};
        form.Controls.AddRange([save,rates,import,context,auto]);form.ShowDialog();
    }
    async Task Connect(string? path)
    {
        if(busy){MessageBox.Show("Дождитесь текущей проверки.");return;}
        if(config.Profile==null){MessageBox.Show("Сначала импортируйте существующий SSH-профиль в настройках.");return;}
        if(path==null){using var picker=new FolderBrowserDialog{Description="Выберите тестовую папку"};if(picker.ShowDialog()!=DialogResult.OK)return;path=picker.SelectedPath;}
        path=Path.GetFullPath(path);
        if(config.Folders.Any(f=>Overlaps(f.LocalPath,path))||SyncDiscovery.Find(data).Any(f=>Overlaps(f.ReplicaPath,path))) {MessageBox.Show("Папка пересекается с существующим подключением. Автоматическая миграция запрещена.");return;}
        var values=Ask("Новое двустороннее подключение",[("Абсолютная папка файлов на сервере",""),("Новый отдельный каталог состояния на сервере (родитель уже существует)","")]);if(values==null)return;
        if(MessageBox.Show("Синхронизация передаёт изменения и удаления в обе стороны. Используйте тестовые папки и резервные копии. Подключить?","RemoteAgents",MessageBoxButtons.OKCancel)!=DialogResult.OK)return;
        var f=new ManagedFolder{LocalPath=path,ServerPath=values[0],ServerState=values[1]};f.Home=Path.Combine(appData,"workers",f.Id);
        var ports=Enumerable.Range(0,6).Select(_=>FreePort()).ToArray();if(ports.Distinct().Count()!=6){MessageBox.Show("Не удалось выбрать разные порты, повторите.");return;}
        f.ListenPort=ports[0];f.TunnelPort=ports[1];f.ApiPort=ports[2];f.ServerListenPort=ports[3];f.RemoteForwardPort=ports[4];f.ServerApiPort=ports[5];
        busy=true;
        try {
            var ssh=new SshTransport(config.Profile,journal);await new FirstConnection(ssh,journal).PrepareAsync(f,config.HostId,binary,Resource,stop.Token);
            config.Folders.Add(f);config.ServerLogDirectory??=f.ServerState+"/logs";
            runtimes[f.Id]=new(f,config.Profile,journal,binary,Path.Combine(appData,"workers"));Save();journal.Write("user","connect","configured");
            MessageBox.Show("Настройка выполнена. Дождитесь подтверждённого статуса обеих сторон в трее.");
        }catch{journal.Write("setup","connect","failed");MessageBox.Show("Подключение не завершено. Файлы сохранены. Частичное состояние оставлено для диагностики; повторное использование не выполняется.");}
        finally{busy=false;}await Poll();
    }
    static int FreePort(){var listener=new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback,0);listener.Start();int port=((System.Net.IPEndPoint)listener.LocalEndpoint).Port;listener.Stop();return port;}
    static bool Overlaps(string a,string b) {a=Path.GetFullPath(a).TrimEnd('\\');b=Path.GetFullPath(b).TrimEnd('\\');return a.Equals(b,StringComparison.OrdinalIgnoreCase)||a.StartsWith(b+"\\",StringComparison.OrdinalIgnoreCase)||b.StartsWith(a+"\\",StringComparison.OrdinalIgnoreCase);}
    static string Resource(string name){using var stream=Assembly.GetExecutingAssembly().GetManifestResourceStream(name)??throw new InvalidDataException("Missing resource");using var r=new StreamReader(stream);return r.ReadToEnd();}
    async Task Exclusions(ManagedFolder f)
    {
        var values=Ask("Исключения (по одному правилу на строку)",[("Относительные пути / шаблоны",string.Join(Environment.NewLine,f.Exclusions))],true);if(values==null)return;
        var patterns=values[0].Split(['\r','\n'],StringSplitOptions.RemoveEmptyEntries);
        if(patterns.Any(p=>p.StartsWith('!')||p.StartsWith('#')||p.Contains(".."))){MessageBox.Show("Разрешены только исключения, без отрицания и родительских путей.");return;}
        try{if(!runtimes.TryGetValue(f.Id,out var r))return;await r.Api.SetIgnoresAsync(f.FolderId,patterns);f.Exclusions=patterns;Save();journal.Write("user","exclusions","applied");}catch{MessageBox.Show("Исключения не подтверждены движком.");}
    }
    async Task Versions(ManagedFolder f)
    {try{if(runtimes.TryGetValue(f.Id,out var r)){var versions=await r.Api.VersionsAsync(f.FolderId);MessageBox.Show(versions.ToString(),"Версии (сохранение 30 дней)");}}catch{MessageBox.Show("Не удалось получить версии.");}}
    async Task Handle(string[] args)
    {
        if(args.Length==0)return;var cmd=ContextMenuLogic.Parse(args);if(cmd==null){journal.Write("ipc","command","rejected");return;}
        if(cmd.Name=="connect"){await Connect(cmd.Path);return;}
        if(cmd.Name=="log"){Open(journal.DirectoryPath);return;}
        if(cmd.Path==null)return;
        var path=Path.GetFullPath(cmd.Path);var f=config.Folders.FirstOrDefault(f=>f.Enabled&&Overlaps(f.LocalPath,path)&&path.Length>=f.LocalPath.TrimEnd('\\').Length);if(f==null){MessageBox.Show("Папка не подключена приложением.");return;}
        switch(cmd.Name){case "status":ShowStatus(f);break;case "pause":await Pause([f],null,true);break;case "resume":await Pause([f],null);break;case "disconnect":Disconnect(f);break;case "versions":await Versions(f);break;
            case "exclude":case "include":
                var relative=Path.GetRelativePath(f.LocalPath,path).Replace('\\','/');if(relative=="."||relative.StartsWith(".."))return;
                var patterns=f.Exclusions.ToHashSet();if(cmd.Name=="exclude")patterns.Add("/"+relative);else patterns.Remove("/"+relative);
                try{await runtimes[f.Id].Api.SetIgnoresAsync(f.FolderId,patterns);f.Exclusions=patterns.ToArray();Save();}catch{MessageBox.Show("Изменение исключений не подтверждено.");}break;
        }
    }
    void Diagnostics()
    {using var dialog=new SaveFileDialog{Filter="Архив диагностики|*.zip",FileName="RemoteAgents-diagnostics.zip"};if(dialog.ShowDialog()!=DialogResult.OK)return;try{journal.CollectDiagnostics(dialog.FileName);MessageBox.Show("Диагностика собрана: только структурированные журналы, без конфигураций и содержимого файлов.");}catch{MessageBox.Show("Не удалось создать архив. Выберите новое имя файла.");}}
    static void Open(string path){if(Directory.Exists(path)||File.Exists(path))Process.Start(new ProcessStartInfo(path){UseShellExecute=true});}
    void PowerChanged(object? sender,PowerModeChangedEventArgs e){journal.Write("windows","power",e.Mode.ToString().ToLowerInvariant());if(e.Mode==PowerModes.Resume)dispatch.BeginInvoke(()=>{foreach(var r in runtimes.Values)r.ResetTunnel();});}
    void NetworkChanged(object? sender,NetworkAvailabilityEventArgs e){journal.Write("windows","network",e.IsAvailable?"available":"unavailable");dispatch.BeginInvoke(()=>{foreach(var r in runtimes.Values)r.ResetTunnel();});}
    static string[]? Ask(string title,(string Label,string Value)[] fields,bool multiline=false)
    {
        using var form=new Form{Text=title,Width=700,Height=multiline?400:230,StartPosition=FormStartPosition.CenterScreen};var panel=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=1,AutoScroll=true};var boxes=new List<TextBox>();
        foreach(var field in fields){panel.Controls.Add(new Label{Text=field.Label,AutoSize=true});var box=new TextBox{Text=field.Value,Dock=DockStyle.Top,Multiline=multiline,Height=multiline?220:25};boxes.Add(box);panel.Controls.Add(box);}
        var ok=new Button{Text="Применить",DialogResult=DialogResult.OK};panel.Controls.Add(ok);form.Controls.Add(panel);form.AcceptButton=ok;return form.ShowDialog()==DialogResult.OK?boxes.Select(b=>b.Text).ToArray():null;
    }
    static System.Drawing.Icon MakeIcon(SyncState state)
    {
        using var bitmap=new System.Drawing.Bitmap(32,32);using var g=System.Drawing.Graphics.FromImage(bitmap);g.Clear(System.Drawing.Color.Transparent);
        var color=state switch{SyncState.Synced=>System.Drawing.Color.ForestGreen,SyncState.Transferring=>System.Drawing.Color.RoyalBlue,SyncState.Paused=>System.Drawing.Color.DarkOrange,SyncState.Disconnected=>System.Drawing.Color.Gray,SyncState.Conflict=>System.Drawing.Color.DarkViolet,_=>System.Drawing.Color.Firebrick};
        using var brush=new System.Drawing.SolidBrush(color);g.FillEllipse(brush,1,1,30,30);
        using var font=new System.Drawing.Font("Segoe UI",17,System.Drawing.FontStyle.Bold);string symbol=state switch{SyncState.Synced=>"✓",SyncState.Transferring=>"↕",SyncState.Paused=>"Ⅱ",SyncState.Disconnected=>"×",SyncState.Conflict=>"!",_=>"E"};g.DrawString(symbol,font,System.Drawing.Brushes.White,3,1);
        var handle=bitmap.GetHicon();try{return (System.Drawing.Icon)System.Drawing.Icon.FromHandle(handle).Clone();}finally{DestroyIcon(handle);}
    }
    [System.Runtime.InteropServices.DllImport("user32.dll")]static extern bool DestroyIcon(IntPtr handle);
    protected override void ExitThreadCore()
    {
        closing=true;timer.Stop();stop.Cancel();SystemEvents.PowerModeChanged-=PowerChanged;NetworkChange.NetworkAvailabilityChanged-=NetworkChanged;
        foreach(var r in runtimes.Values)r.Dispose();journal.Write("app","exit","ok");timer.Dispose();icon.Visible=false;icon.Dispose();foreach(var i in icons.Values)i.Dispose();dispatch.Dispose();base.ExitThreadCore();
    }
}
