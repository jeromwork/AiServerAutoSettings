using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace RemoteAgents.Launcher
{
    // Separate entry: no administrator credentials or server repair actions here.
    internal sealed class InviteWindow : Form
    {
        readonly string home; string bundle; readonly Func<Task<string>> prepare; readonly Journal log; readonly CancellationTokenSource stop=new CancellationTokenSource();
        readonly Label line=new Label {Dock=DockStyle.Top,Height=78,Padding=new Padding(12),Text="Подключаю компьютер по приглашению…"};
        readonly TreeView folders=new TreeView {Dock=DockStyle.Fill,CheckBoxes=true,Visible=false};
        DiskTreeSelection selection;bool changingTree;
        readonly Button retry=new Button {Text="Повторить",Width=120},close=new Button {Text="Закрыть",Width=100};
        bool busy,choose; internal bool Manual;
        internal static bool Display(string home,string bundle,Func<Task<string>> prepare=null)
        {using(var form=new InviteWindow(home,bundle,prepare)){form.ShowDialog();return form.Manual;}}
        InviteWindow(string home,string bundle,Func<Task<string>> prepare)
        {
            this.home=home;this.bundle=bundle;this.prepare=prepare;log=new Journal(home);
            Text="RemoteAgents — приглашение";ClientSize=new Size(560,340);StartPosition=FormStartPosition.CenterScreen;Font=new Font("Segoe UI",10F);
            var bar=new FlowLayoutPanel {Dock=DockStyle.Bottom,Height=42,FlowDirection=FlowDirection.RightToLeft};bar.Controls.Add(close);bar.Controls.Add(retry);
            var manual=new LinkLabel {Dock=DockStyle.Bottom,Height=30,Text="Настроить сервер вручную",Padding=new Padding(12,2,0,0)};
            manual.LinkClicked+=(s,e)=>{if(!busy){Manual=true;Close();}};
            Controls.Add(folders);Controls.Add(line);Controls.Add(manual);Controls.Add(bar);
            folders.BeforeExpand+=async(s,e)=>{if(e.Node.Nodes.Count==1 && e.Node.Nodes[0].Tag==null){try{var data=await Step("DiskTree",new {path=(string)e.Node.Tag},"Загружаю папки…");AddTreeLevel(Json.Map(Json.Get(data,"union")),e.Node);}catch(Exception ex){line.Text=ex.Message;}}};
            folders.AfterCheck+=(s,e)=>{if(changingTree || selection==null || e.Node.Tag==null || (string)e.Node.Tag=="")return;try{selection.Set((string)e.Node.Tag,e.Node.Checked);}catch(Exception ex){line.Text=ex.Message;}RefreshChecks();};
            close.Click+=(s,e)=>Close();retry.Click+=async(s,e)=>await Run();Shown+=async(s,e)=>await Run();
            FormClosing+=(s,e)=>{if(busy){e.Cancel=true;stop.Cancel();line.Text="Останавливаю текущую операцию…";}};
        }
        protected override void Dispose(bool disposing){if(disposing)stop.Dispose();base.Dispose(disposing);}
        async Task<Dictionary<string,object>> Step(string action,object request,string text)
        {line.Text=text;log.Write("invite."+action+".start");var result=await Task.Run(()=>ServerOperations.Invoke(home,bundle,action,request,stop.Token));if(result.ContainsKey("ok") && !Json.Bool(result,"ok"))throw new IOException(Json.Text(result,"summary","Этап ещё не подтверждён. Повторите позже."));log.Write("invite."+action+".ok");return result;}
        static IEnumerable<TreeNode> Nodes(TreeNodeCollection nodes){foreach(TreeNode n in nodes){yield return n;foreach(var child in Nodes(n.Nodes))yield return child;}}
        void RefreshChecks()
        {
            changingTree=true;try{foreach(var n in Nodes(folders.Nodes)){n.Checked=n.Tag!=null && (string)n.Tag!="" && selection.Includes((string)n.Tag);n.ForeColor=n.Tag!=null && selection.Partial((string)n.Tag)?Color.DarkOrange:SystemColors.WindowText;}}finally{changingTree=false;}
        }
        void AddTreeLevel(Dictionary<string,object> union,TreeNode parent)
        {
            string prefix=parent==null?"":(string)parent.Tag;var children=new List<TreeNode>();
            foreach(var item in Json.Array(Json.Get(union,"rows"))){
                var row=Json.Map(item);string path=Json.Str(row,"path"),presence=Json.Str(row,"presence");int slash=path.LastIndexOf('/');
                if((slash<0?"":path.Substring(0,slash))!=prefix)throw new InvalidDataException("Сервер вернул другой уровень дерева");
                string label=presence=="both"?"в обоих":presence=="local"?"только здесь":"только на сервере";
                var node=new TreeNode((slash<0?path:path.Substring(slash+1))+" — "+label){Tag=path};
                if(slash<0 && Json.Str(row,"kind")=="file"){node.Tag="";node.Text+=" — поместите в папку проекта";}
                if(Json.Str(row,"kind")=="directory" && Json.Bool(row,"hasChildren"))node.Nodes.Add(new TreeNode("Загрузка…"));children.Add(node);
            }
            selection.Level(prefix,children.Where(n=>(string)n.Tag!="").Select(n=>(string)n.Tag),Json.Bool(union,"truncated"));
            changingTree=true;try{var target=parent==null?folders.Nodes:parent.Nodes;target.Clear();target.AddRange(children.ToArray());}finally{changingTree=false;}RefreshChecks();
            if(Json.Bool(union,"truncated"))line.Text="Список неполный. Отметка папки включает скрытые элементы. Для частичного выбора снимите всю папку и отметьте нужное.";
        }
        async Task Run()
        {
            if(busy)return;busy=true;retry.Enabled=false;
            try {
                if(bundle==null && prepare!=null){line.Text="Подготавливаю программу…";bundle=await prepare();}
                var state=Json.Read(Invitation.State(home));
                if(!choose){
                if(!Json.Bool(state,"registered")){
                    var invitation=Invitation.Read(Invitation.Secret(home));
                    Dictionary<string,object> initial;
                    do { initial=await Step("InvitePrepare",new {path=Invitation.Secret(home),parentPid=System.Diagnostics.Process.GetCurrentProcess().Id},"Применяю каталог связи и включаю VPN…"); }
                    while(Json.Str(initial,"vpn")=="conflict" && TrayContext.VpnConflictDialog(Json.Str(initial,"found")));
                    state["vpnOutcome"]=Json.Str(initial,"vpn");Json.Write(Invitation.State(home),state);
                    string hopPassword=Json.Array(Json.Get(invitation.Data,"routes")).Select(x=>Json.Str(Json.Map(Json.Get(Json.Map(x),"hop")),"password")).FirstOrDefault(x=>x.Length>0) ?? "";
                    using(var relay=new PasswordRelay(hopPassword,32))await Step("InviteEnroll",new {path=Invitation.Secret(home),askpassExecutable=Program.Exe,hopPasswordPipe=relay.Name},"Регистрирую ключ этого компьютера…");
                    state["registered"]=true;Json.Write(Invitation.State(home),state);
                }else await Step("InviteVerify",new {},"Проверяю вход своим ключом…");
                // Receipt is durable first: interruption during deletion resumes using our own key.
                Invitation.Consume(home,state);
                RefreshPackage.RememberDevice(home,Json.Str(state,"name"));
                var catalog=await Step("Catalog",new {},"Загружаю настройки связи…");
                await Step("Connection",new {catalog,shared=false},"Настраиваю и проверяю связь…");
                await Step("Bridge",new {enabled=true,shell=true},"Подключаю и проверяю мост…");
                string mode=Json.Str(state,"happier");
                if(mode.StartsWith("new:",StringComparison.Ordinal)){
                    string key=Path.Combine(home,"secrets","invite-happier.key");
                    if(!File.Exists(key))AccountDiskSetup.SaveKey(home,HappierKey.Create(),"invite-happier.key");
                    AccountDiskSetup.SaveKey(home,File.ReadAllText(key),"happier-pending.key");
                }
                await Step("InviteAccount",new {mode,account=Json.Str(state,"happierAccount")},"Проверяю Happier…");
                    var tree=await Step("DiskTree",new {path=""},"Загружаю папки диска…");
                    selection=new DiskTreeSelection(Json.Strings(Json.Get(state,"folders")));
                    AddTreeLevel(Json.Map(Json.Get(tree,"union")),null);
                    choose=true;folders.Visible=true;line.Text="Выберите папки: с сервера — на компьютер, местные — на сервер. Раскройте папку для частичного выбора.";retry.Text="Подключить";return;
                }
                await Step("InviteDisk",new {paths=selection.Paths},"Подключаю выбранные папки диска…");
                var observed=await Step("Inspect",new {},"Проверяю итоговое состояние…");
                if(!Json.Bool(observed,"ok"))throw new IOException("Есть неподтверждённые этапы. Проверьте связь и повторите.");
                await Step("Activate",new {},"Завершаю настройку…");
                File.Delete(Invitation.State(home));string newKey=Path.Combine(home,"secrets","invite-happier.key");if(File.Exists(newKey))File.Delete(newKey);folders.Visible=false;line.Text="Компьютер подключён. Связь, мост и Happier проверены. Передача файлов продолжается; её состояние видно в Диске.";
                if(Json.Str(state,"vpn")=="on"){
                    var vpn=StatusView.Read(home,"vpn",maxAgeSec:15);
                    line.Text+=" VPN: "+(Json.Bool(vpn,"ok") && Json.Str(vpn,"state")=="on"?"включён и проверен.":"не подтверждён; подключение выполнено через доступный маршрут.");
                }
                retry.Visible=false;log.Write("invite.complete");
            } catch(OperationCanceledException){line.Text="Операция остановлена. Закройте окно и запустите RemoteAgents снова для продолжения.";retry.Visible=false;}
            catch(Exception e){line.Text=e.Message;log.Write("invite.failed");retry.Text="Повторить";}
            finally{busy=false;retry.Enabled=true;}
        }
    }
}
