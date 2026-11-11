using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace RemoteAgents.Launcher
{
    // Server network sections: «Выход в интернет» (proxy-out) and «Локальные сети».
    // Root actions: the existing key as root -> a root key -> root/sudo password once (memory only)
    // -> an exact command for the administrator. Secrets never go to request files or the journal.
    internal sealed partial class SetupWizard
    {
        ComboBox proxyType; TextBox proxyServer, proxyPort, proxyUser, proxyPassword, proxyCheckUrl;
        ListView lanList; string proxyCommand = "";
        string ProxySecretFile { get { return Path.Combine(home, "secrets", "proxy-out.json"); } }

        void ProxyPage(Dictionary<string,object> config)
        {
            var c=Json.Map(Json.Get(config,"proxy"));
            Question(8,"Через какой прокси сервер выходит в интернет?");
            Hint(8,"Интернет сервера идёт только через этот прокси и никогда через локальные сети.",80,22);
            Hint(8,"Тип",104,21);
            proxyType=new ComboBox {Left=16,Top=126,Width=160,DropDownStyle=ComboBoxStyle.DropDownList};proxyType.Items.AddRange(new object[]{"SOCKS5","HTTP"});
            proxyType.SelectedIndex=Json.Str(c,"type")=="http"?1:0;sections[8].Controls.Add(proxyType);
            proxyServer=Field(8,"Адрес прокси",152,Json.Str(c,"server"));proxyServer.Width=420;
            proxyPort=Field(8,"Порт",152,Json.Str(c,"port"));proxyPort.Left=450;proxyPort.Width=141;
            sections[8].Controls.Cast<Control>().Last(x=>x is Label).Left=450;
            string savedUser="";try{if(File.Exists(ProxySecretFile))savedUser=Json.Str(Json.Read(ProxySecretFile),"username");}catch{}
            proxyUser=Field(8,"Логин (необязательно)",204,savedUser);proxyUser.Width=280;
            proxyPassword=Field(8,"Пароль (пусто — сохранённый)",204,"",true);proxyPassword.Left=311;proxyPassword.Width=280;
            sections[8].Controls.Cast<Control>().Last(x=>x is Label).Left=311;
            proxyCheckUrl=Field(8,"Ваш HTTPS-адрес проверки IP (отвечает только IP)",256,Json.Text(c,"ipCheckUrl",Json.Str(Json.Map(Json.Get(config,"vpn")),"checkUrl")));
            proxyType.SelectedIndexChanged+=(a,b)=>Changed(8);
            Button(8,"Пропустить",310,()=>Skip("Proxy",8),16,120);
            Button(8,"Скопировать команду",310,()=>CopyCommand(proxyCommand),146,200);
            Button(8,"Обновить состояние",310,RefreshNetwork,356,180);
        }
        void LanPage()
        {
            Question(6,"Какие локальные сети доступны серверу?");
            Hint(6,"Интернет всегда идёт через прокси, не через эти сети. Можно добавить несколько подключений.",80,22);
            lanList=new ListView {Left=16,Top=106,Width=575,Height=170,View=View.Details,FullRowSelect=true,MultiSelect=false,HideSelection=false};
            lanList.Columns.Add("Имя",110);lanList.Columns.Add("Тип",90);lanList.Columns.Add("Состояние",350);sections[6].Controls.Add(lanList);
            try{foreach(var row in Json.Array(Json.Get(Json.Map(Json.Get(new Configuration(home).Data,"lan")),"connections")).Select(Json.Map))
                lanList.Items.Add(new ListViewItem(new[]{Json.Str(row,"name"),"OpenVPN","не проверено"}){Name=Json.Str(row,"name")});}catch{}
            Button(6,"Добавить…",284,AddLan,16,110);
            Button(6,"Удалить",284,RemoveLan,134,90);
            Button(6,"Обновить состояние",284,RefreshNetwork,232,160);
            Button(6,"Скопировать команду",284,()=>CopyCommand(lanCommand),400,191);
            Button(6,"Пропустить",318,()=>Skip("Lan",6),16,110);
        }
        Task CopyCommand(string command)
        {
            if(command.Length==0)throw new IOException("Команды для администратора нет: права root получены этим окном или операция не запускалась");
            Clipboard.SetText(command);Append("Команда скопирована. Её выполняет администратор сервера; секреты команда спросит сама.");return Task.FromResult(0);
        }
        void InspectNetwork(Dictionary<string,object> wizard)
        {
            var config=new Configuration(home).Data;var proxy=Json.Map(Json.Get(config,"proxy"));
            int lans=Json.Array(Json.Get(Json.Map(Json.Get(config,"lan")),"connections")).Length;
            if(!dirty[6]){applied[6]=lans>0 || Json.Bool(wizard,"skipLan") || Json.Bool(wizard,"configured");results[6]=lans>0?"Добавлено сетей: "+lans+" (состояние — «Обновить состояние»)":"Не настроены (необязательно)";}
            if(!dirty[8]){applied[8]=Json.Bool(proxy,"confirmed") || Json.Bool(wizard,"skipProxy") || Json.Bool(wizard,"configured");
                results[8]=Json.Bool(proxy,"confirmed")?"Прокси подтверждён при применении (текущее — «Обновить состояние»)":Json.Bool(wizard,"skipProxy")?"Пропущено: сервер выходит в интернет как сейчас":"Не настроен (необязательно)";}
        }
        async Task RefreshNetwork()
        {
            var status=await Run("NetStatus",new {});
            var rows=Json.Array(Json.Get(status,"lans")).Select(Json.Map).ToArray();
            lanList.Items.Clear();
            foreach(var row in rows)lanList.Items.Add(new ListViewItem(new[]{Json.Str(row,"name"),"OpenVPN",Json.Str(row,"state")}){Name=Json.Str(row,"name"),ForeColor=Json.Bool(row,"ok")?SystemColors.WindowText:Color.Firebrick});
            var proxy=Json.Map(Json.Get(status,"proxy"));
            results[8]="Сейчас на сервере: "+Json.Str(proxy,"summary");
            results[6]=rows.Length==0?"Сетей на сервере нет":"Подключено "+rows.Count(r=>Json.Bool(r,"ok"))+" из "+rows.Length;
            Append(titles[currentPage]+": "+results[currentPage]);
        }
        // Returns the root mode and, if a password is needed and typed, a relay that serves it a few times.
        async Task<Tuple<string,string,PasswordRelay>> RootAccess()
        {
            string mode=Json.Str(await Run("AdminProbe",new {}),"mode");
            if(mode!="command")return Tuple.Create(mode,"",(PasswordRelay)null);
            using(var form=new Form {Text="Права root на сервере",ClientSize=new Size(470,215),StartPosition=FormStartPosition.CenterParent,FormBorderStyle=FormBorderStyle.FixedDialog,MaximizeBox=false,MinimizeBox=false,AutoScaleMode=AutoScaleMode.Dpi,Font=Font}) {
                form.Controls.Add(new Label {Left=12,Top=10,Width=446,Height=48,Text="Ключ этого компьютера не входит на сервер как root. Введите пароль root (или sudo-пароль администратора) — он используется один раз и не сохраняется."});
                form.Controls.Add(new Label {Left=12,Top=62,Width=200,Height=20,Text="Логин администратора"});
                var user=new TextBox {Left=12,Top=82,Width=446,Text="root"};form.Controls.Add(user);
                form.Controls.Add(new Label {Left=12,Top=110,Width=200,Height=20,Text="Пароль"});
                var secret=new TextBox {Left=12,Top=130,Width=446,UseSystemPasswordChar=true};form.Controls.Add(secret);
                var ok=new Button {Text="Выполнить",Left=12,Top=172,Width=120,DialogResult=DialogResult.OK};
                var admin=new Button {Text="Команда для администратора",Left=140,Top=172,Width=220,DialogResult=DialogResult.Ignore};
                var cancel=new Button {Text="Отмена",Left=368,Top=172,Width=90,DialogResult=DialogResult.Cancel};
                form.Controls.Add(ok);form.Controls.Add(admin);form.Controls.Add(cancel);form.AcceptButton=ok;form.CancelButton=cancel;
                var answer=form.ShowDialog(this);
                if(answer==DialogResult.Cancel)throw new OperationCanceledException();
                if(answer==DialogResult.OK && secret.Text.Length>0){
                    string login=user.Text.Trim();if(!Regex.IsMatch(login,"^[a-z_][a-z0-9_-]{0,31}$"))throw new IOException("Некорректный логин администратора");
                    var relay=new PasswordRelay(secret.Text,8);secret.Clear();return Tuple.Create("password",login,relay);
                }
                return Tuple.Create("command","",(PasswordRelay)null);
            }
        }
        void ProtectSecrets()
        {
            string directory=Path.Combine(home,"secrets");Directory.CreateDirectory(directory);
            var acl=new System.Security.AccessControl.DirectorySecurity();acl.SetAccessRuleProtection(true,false);
            acl.AddAccessRule(new System.Security.AccessControl.FileSystemAccessRule(System.Security.Principal.WindowsIdentity.GetCurrent().User,System.Security.AccessControl.FileSystemRights.FullControl,System.Security.AccessControl.InheritanceFlags.ContainerInherit|System.Security.AccessControl.InheritanceFlags.ObjectInherit,System.Security.AccessControl.PropagationFlags.None,System.Security.AccessControl.AccessControlType.Allow));
            Directory.SetAccessControl(directory,acl);
        }
        async Task<Dictionary<string,object>> ExecuteProxy()
        {
            int port;if(proxyServer.Text.Trim().Length==0 || !int.TryParse(proxyPort.Text.Trim(),out port) || port<1 || port>65535)throw new IOException("Укажите адрес и порт прокси или нажмите «Пропустить»");
            string user=proxyUser.Text.Trim();
            if(user.Length==0){if(File.Exists(ProxySecretFile))File.Delete(ProxySecretFile);}
            else if(proxyPassword.Text.Length>0 || !File.Exists(ProxySecretFile) || Json.Str(Json.Read(ProxySecretFile),"username")!=user) {
                if(proxyPassword.Text.Length==0)throw new IOException("Введите пароль прокси");
                // Same protected secrets folder as the Happier key; the request file never holds it.
                ProtectSecrets();
                Files.Atomic(ProxySecretFile,Json.Encode(new Dictionary<string,object>{{"username",user},{"password",proxyPassword.Text}})+"\n");
            }
            proxyPassword.Clear();
            var access=await RootAccess();
            using(access.Item3) {
                var result=await Run("Proxy",new {type=proxyType.SelectedIndex==1?"http":"socks",server=proxyServer.Text.Trim(),port=proxyPort.Text.Trim(),ipCheckUrl=proxyCheckUrl.Text.Trim(),mode=access.Item1,adminLogin=access.Item2,passwordPipe=access.Item3==null?"":access.Item3.Name,askpassExecutable=Program.Exe});
                proxyCommand=Json.Str(result,"command");return result;
            }
        }
        async Task<Dictionary<string,object>> ExecuteLan()
        {
            if(lanList.Items.Count==0)return new Dictionary<string,object>{{"summary","Локальные сети не добавлены (необязательно)"}};
            await RefreshNetwork();return new Dictionary<string,object>{{"summary",results[6]}};
        }
        async Task AddLan()
        {
            string file="",name="",hostAddress="",port="",lanUser="",lanPassword="";
            using(var form=new Form {Text="Добавить локальную сеть",ClientSize=new Size(470,390),StartPosition=FormStartPosition.CenterParent,FormBorderStyle=FormBorderStyle.FixedDialog,MaximizeBox=false,MinimizeBox=false,AutoScaleMode=AutoScaleMode.Dpi,Font=Font}) {
                Func<string,int,bool,TextBox> field=(title,top,secret)=>{form.Controls.Add(new Label {Left=12,Top=top,Width=446,Height=20,Text=title});var t=new TextBox {Left=12,Top=top+20,Width=446,UseSystemPasswordChar=secret};form.Controls.Add(t);return t;};
                form.Controls.Add(new Label {Left=12,Top=10,Width=100,Height=20,Text="Тип"});
                var kind=new ComboBox {Left=12,Top=30,Width=200,DropDownStyle=ComboBoxStyle.DropDownList};kind.Items.Add("OpenVPN");kind.SelectedIndex=0;form.Controls.Add(kind);
                var nameBox=field("Имя (1–7 латинских строчных букв/цифр)",58,false);
                var fileBox=field("Файл .ovpn (ca/cert/key рядом подставятся сами)",104,false);fileBox.ReadOnly=true;fileBox.Width=340;
                var browse=new Button {Text="Выбрать…",Left=358,Top=123,Width=100};form.Controls.Add(browse);
                browse.Click+=(a,b)=>{using(var d=new OpenFileDialog {Filter="OpenVPN (*.ovpn)|*.ovpn",CheckFileExists=true})if(d.ShowDialog(form)==DialogResult.OK){fileBox.Text=d.FileName;if(nameBox.Text.Length==0){var n=Regex.Replace(Path.GetFileNameWithoutExtension(d.FileName).ToLowerInvariant(),"[^a-z0-9]","");n=Regex.Replace(n,"^[0-9]+","");nameBox.Text=n.Length>7?n.Substring(0,7):n;}}};
                var hostBox=field("IPv4 компьютера в этой сети для проверки",150,false);hostBox.Width=330;
                form.Controls.Add(new Label {Left=352,Top=150,Width=100,Height=20,Text="Порт (необяз.)"});var portBox=new TextBox {Left=352,Top=170,Width=106,Text="22"};form.Controls.Add(portBox);
                var userBox=field("Логин сети — если профиль его требует",196,false);
                var passBox=field("Пароль сети (хранится только на сервере, root)",242,true);
                form.Controls.Add(new Label {Left=12,Top=290,Width=446,Height=40,Text="Проверка IP: "+(proxyCheckUrl.Text.Trim().Length>0?proxyCheckUrl.Text.Trim():"укажите адрес в разделе «Выход в интернет»")});
                var ok=new Button {Text="Подключить",Left=246,Top=345,Width=120,DialogResult=DialogResult.OK};var cancel=new Button {Text="Отмена",Left=374,Top=345,Width=84,DialogResult=DialogResult.Cancel};
                form.Controls.Add(ok);form.Controls.Add(cancel);form.AcceptButton=ok;form.CancelButton=cancel;
                if(form.ShowDialog(this)!=DialogResult.OK)return;
                file=fileBox.Text;name=nameBox.Text.Trim();hostAddress=hostBox.Text.Trim();port=portBox.Text.Trim();lanUser=userBox.Text.Trim();lanPassword=passBox.Text;passBox.Clear();
            }
            if(file.Length==0)throw new IOException("Выберите файл .ovpn");
            if(proxyCheckUrl.Text.Trim().Length==0)throw new IOException("Сначала укажите HTTPS-адрес проверки IP в разделе «Выход в интернет»");
            var access=await RootAccess();
            using(access.Item3)
            using(var lanSecret=new PasswordRelay(lanUser.Length>0?Json.Encode(new Dictionary<string,object>{{"username",lanUser},{"password",lanPassword}}):"")) {
                lanPassword="";
                var result=await Run("Lan",new {kind="openvpn",name,file,host=hostAddress,port,ipCheckUrl=proxyCheckUrl.Text.Trim(),secretPipe=lanSecret.Name,mode=access.Item1,adminLogin=access.Item2,passwordPipe=access.Item3==null?"":access.Item3.Name,askpassExecutable=Program.Exe});
                lanCommand=Json.Str(result,"command");results[6]=Json.Str(result,"summary");Append(results[6]);
                string added=Json.Str(result,"name");if(lanList.Items.ContainsKey(added))lanList.Items.RemoveByKey(added);
                lanList.Items.Add(new ListViewItem(new[]{added,"OpenVPN",Json.Bool(result,"ok")?"подключена ✓":"ждёт администратора"}){Name=added});
                applied[6]=Json.Bool(result,"ok");dirty[6]=false;
            }
        }
        async Task RemoveLan()
        {
            if(lanList.SelectedItems.Count==0)throw new IOException("Выберите сеть в списке");
            string name=lanList.SelectedItems[0].Name;
            if(MessageBox.Show(this,"Отключить и удалить сеть «"+name+"» на сервере?","Локальные сети",MessageBoxButtons.YesNo,MessageBoxIcon.Question)!=DialogResult.Yes)return;
            var access=await RootAccess();
            using(access.Item3) {
                var result=await Run("LanRemove",new {name,mode=access.Item1,adminLogin=access.Item2,passwordPipe=access.Item3==null?"":access.Item3.Name,askpassExecutable=Program.Exe});
                lanCommand=Json.Str(result,"command");Append(Json.Str(result,"summary"));
                if(Json.Bool(result,"ok"))lanList.Items.RemoveByKey(name);
            }
        }
    }
}
