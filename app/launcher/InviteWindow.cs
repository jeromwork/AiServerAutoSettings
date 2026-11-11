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
        readonly string home,bundle; readonly Journal log; readonly CancellationTokenSource stop=new CancellationTokenSource();
        readonly Label line=new Label {Dock=DockStyle.Top,Height=78,Padding=new Padding(12),Text="Подключаю компьютер по приглашению…"};
        readonly CheckedListBox folders=new CheckedListBox {Dock=DockStyle.Fill,CheckOnClick=true,Visible=false};
        readonly Button retry=new Button {Text="Повторить",Width=120},close=new Button {Text="Закрыть",Width=100};
        bool busy,choose; internal bool Manual;
        internal static bool Display(string home,string bundle)
        {using(var form=new InviteWindow(home,bundle)){form.ShowDialog();return form.Manual;}}
        InviteWindow(string home,string bundle)
        {
            this.home=home;this.bundle=bundle;log=new Journal(home);
            Text="RemoteAgents — приглашение";ClientSize=new Size(560,340);StartPosition=FormStartPosition.CenterScreen;Font=new Font("Segoe UI",10F);
            var bar=new FlowLayoutPanel {Dock=DockStyle.Bottom,Height=42,FlowDirection=FlowDirection.RightToLeft};bar.Controls.Add(close);bar.Controls.Add(retry);
            var manual=new LinkLabel {Dock=DockStyle.Bottom,Height=30,Text="Настроить сервер вручную",Padding=new Padding(12,2,0,0)};
            manual.LinkClicked+=(s,e)=>{if(!busy){Manual=true;Close();}};
            Controls.Add(folders);Controls.Add(line);Controls.Add(manual);Controls.Add(bar);
            close.Click+=(s,e)=>Close();retry.Click+=async(s,e)=>await Run();Shown+=async(s,e)=>await Run();
            FormClosing+=(s,e)=>{if(busy){e.Cancel=true;stop.Cancel();line.Text="Останавливаю текущую операцию…";}};
        }
        protected override void Dispose(bool disposing){if(disposing)stop.Dispose();base.Dispose(disposing);}
        async Task<Dictionary<string,object>> Step(string action,object request,string text)
        {line.Text=text;log.Write("invite."+action+".start");var result=await Task.Run(()=>ServerOperations.Invoke(home,bundle,action,request,stop.Token));if(result.ContainsKey("ok") && !Json.Bool(result,"ok"))throw new IOException(Json.Text(result,"summary","Этап ещё не подтверждён. Повторите позже."));log.Write("invite."+action+".ok");return result;}
        async Task Run()
        {
            if(busy)return;busy=true;retry.Enabled=false;
            try {
                var state=Json.Read(Invitation.State(home));
                if(!Json.Bool(state,"registered")){
                    var invitation=Invitation.Read(Invitation.Secret(home));
                    string hopPassword=Json.Array(Json.Get(invitation.Data,"routes")).Select(x=>Json.Str(Json.Map(Json.Get(Json.Map(x),"hop")),"password")).FirstOrDefault(x=>x.Length>0) ?? "";
                    using(var relay=new PasswordRelay(hopPassword,32))await Step("InviteEnroll",new {path=Invitation.Secret(home),askpassExecutable=Program.Exe,hopPasswordPipe=relay.Name},"Регистрирую ключ этого компьютера…");
                    state["registered"]=true;Json.Write(Invitation.State(home),state);
                }else await Step("InviteVerify",new {},"Проверяю вход своим ключом…");
                // Receipt is durable first: interruption during deletion resumes using our own key.
                string source=Json.Str(state,"source");if(File.Exists(source))File.Delete(source);
                if(File.Exists(Invitation.Secret(home)))File.Delete(Invitation.Secret(home));
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
                if(!choose){
                    var tree=await Step("DiskTree",new {path=""},"Загружаю папки диска…");
                    string[] selected=Json.Strings(Json.Get(state,"folders"));
                    var rows=Json.Array(Json.Get(Json.Map(Json.Get(tree,"union")),"rows")).Select(Json.Map).Where(x=>Json.Str(x,"kind")=="directory").Select(x=>Json.Str(x,"path"));
                    foreach(string path in rows.Concat(selected).Distinct())folders.Items.Add(path,selected.Contains(path));
                    choose=true;folders.Visible=true;line.Text="Выберите папки диска для этого компьютера.";retry.Text="Подключить";return;
                }
                await Step("InviteDisk",new {paths=folders.CheckedItems.Cast<string>().ToArray()},"Подключаю выбранные папки диска…");
                var observed=await Step("Inspect",new {},"Проверяю итоговое состояние…");
                if(!Json.Bool(observed,"ok"))throw new IOException("Есть неподтверждённые этапы. Проверьте связь и повторите.");
                await Step("Activate",new {},"Завершаю настройку…");
                File.Delete(Invitation.State(home));string newKey=Path.Combine(home,"secrets","invite-happier.key");if(File.Exists(newKey))File.Delete(newKey);folders.Visible=false;line.Text="Компьютер подключён. Связь, мост и Happier проверены. Передача файлов продолжается; её состояние видно в Диске.";retry.Visible=false;log.Write("invite.complete");
            } catch(OperationCanceledException){line.Text="Операция остановлена. Закройте окно и запустите RemoteAgents снова для продолжения.";retry.Visible=false;}
            catch(Exception e){line.Text=e.Message;log.Write("invite.failed");retry.Text="Повторить";}
            finally{busy=false;retry.Enabled=true;}
        }
    }
}
