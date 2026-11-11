using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;

namespace RemoteAgents.Launcher
{
    internal sealed class Invitation
    {
        internal readonly Dictionary<string, object> Data;
        internal Invitation(Dictionary<string, object> data)
        {
            Data=data;
            Need(!(Json.Get(data,"schema") is string) && Json.Int(data,"schema",0)==1,"Неизвестная схема приглашения. Попросите новое приглашение.");
            Need(data.Keys.All(k=>new[]{"schema","id","name","serverAddress","serverPort","workerUser","enrollUser","hostKeys","routes","expiresUtc","happier","folders","passKey","happierAccount","vpn","bootstrap"}.Contains(k)),"Неизвестные поля приглашения.");
            string name=Json.Str(data,"name");Need(name.Length>0 && name.Length<=80 && !name.Any(char.IsControl),"Неверное имя приглашения.");
            Match("id","^[a-f0-9]{32}$"); Match("serverAddress","^[a-zA-Z0-9][a-zA-Z0-9.:-]{0,252}$");
            Match("workerUser","^[a-z_][a-z0-9_-]{0,31}$"); Match("enrollUser","^[a-z_][a-z0-9_-]{0,31}$");
            int port=Json.Int(data,"serverPort",0);Need(!(Json.Get(data,"serverPort") is string) && port>0 && port<=65535,"Неверный порт приглашения.");
            DateTimeOffset expiry;Need(DateTimeOffset.TryParse(Json.Str(data,"expiresUtc"),CultureInfo.InvariantCulture,DateTimeStyles.RoundtripKind,out expiry),"Неверный срок приглашения.");
            Need(!(Json.Get(data,"hostKeys") is string) && !(Json.Get(data,"routes") is string) && !(Json.Get(data,"folders") is string),"Повреждена схема списков приглашения.");
            var keys=Json.Strings(Json.Get(data,"hostKeys"));Need(keys.Length>0 && keys.All(HostKey),"Нет корректных ключей хоста в приглашении.");
            Need(!data.ContainsKey("vpn") || new[]{"on","off"}.Contains(Json.Str(data,"vpn")),"Неверный режим VPN.");
            if(data.ContainsKey("bootstrap"))Need(Json.Int(Json.Map(Json.Get(Json.Map(Json.Get(data,"bootstrap")),"catalog")),"schema",0)==1,"Нет каталога связи приглашения.");
            string mode=Json.Str(data,"happier");Need(mode=="same" || Regex.IsMatch(mode,@"\Anew:[^\x00-\x1f\x7f]{1,80}\z"),"Неверный выбор Happier.");
            foreach(string folder in Json.Strings(Json.Get(data,"folders")))Need(folder.Length>0 && folder.Split('/').All(x=>x.Length>0 && x!="." && x!=".." && x.IndexOfAny(new[]{'\\',':','\r','\n','\0'})<0),"Недопустимая папка приглашения.");
            var routes=Json.Array(Json.Get(data,"routes"));Need(routes.Length>0,"Нет маршрутов приглашения.");
            foreach(var item in routes){var r=Json.Map(item);string kind=Json.Str(r,"kind");Need(kind=="direct" || kind=="proxy" || kind=="hop","Неизвестный маршрут приглашения.");
                if(kind=="proxy"){var p=Json.Map(Json.Get(r,"proxy"));Need((Json.Str(p,"type")=="socks" || Json.Str(p,"type")=="http") && Regex.IsMatch(Json.Str(p,"host"),@"\A[a-zA-Z0-9][a-zA-Z0-9.:-]{0,252}\z") && Json.Int(p,"port",0)>0 && Json.Int(p,"port",0)<=65535,"Повреждён маршрут прокси.");}
                if(kind=="hop"){var h=Json.Map(Json.Get(r,"hop"));Need(Regex.IsMatch(Json.Str(h,"ssh"),@"\A(?:[a-z_][a-z0-9_-]{0,31}@)?[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}(?::\d{1,5})?\z") && HostKey(Json.Str(h,"hostKey")),"Нет корректного адреса или ключа промежуточного сервера.");}}
            Need(Json.Str(data,"passKey").StartsWith("-----BEGIN OPENSSH PRIVATE KEY-----",StringComparison.Ordinal),"Повреждён пропуск приглашения.");
        }
        static bool HostKey(string value){return Regex.IsMatch(value,@"\A(ssh-ed25519|ecdsa-sha2-nistp256|ssh-rsa) [A-Za-z0-9+/=]+\z");}
        void Match(string field,string pattern){Need(Regex.IsMatch(Json.Str(Data,field),@"\A(?:"+pattern.TrimStart('^').TrimEnd('$')+@")\z"),"Повреждено поле приглашения: "+field);}
        static void Need(bool condition,string message){if(!condition)throw new InvalidDataException(message);}
        internal static Invitation Read(string path){Need(new FileInfo(path).Length<=1024*1024,"Файл приглашения слишком велик.");return new Invitation(Json.Read(path));}
        internal static string Find(string[] args,string directory)
        {
            string explicitPath=ProgramOption(args,"--invite") ?? args.FirstOrDefault(a=>a.EndsWith(".rainvite",StringComparison.OrdinalIgnoreCase));
            if(explicitPath!=null)return Path.GetFullPath(explicitPath);
            var files=Directory.GetFiles(directory,"*.rainvite");Need(files.Length<=1,"Рядом с EXE несколько приглашений. Оставьте одно или перетащите нужный файл на EXE.");return files.FirstOrDefault();
        }
        static string ProgramOption(string[] args,string key){int n=Array.IndexOf(args,key);if(n<0)return null;Need(n+1<args.Length,"Укажите путь приглашения.");return args[n+1];}
        internal static string State(string home){return Path.Combine(home,"state","invite-setup.json");}
        internal static string Secret(string home){return Path.Combine(home,"secrets","invite.rainvite");}
        internal static bool Pending(string home){return File.Exists(State(home));}
#if !PORTABLE_TEST
        internal static void Stage(string home,string source)
        {
            var invite=Read(source);AccountDiskSetup.ProtectSecrets(home);
            StageData(home,invite,source,false);
        }
        internal static void StageData(string home,Invitation invite,string source,bool embedded)
        {
            if(Pending(home)){
                if(Json.Str(Json.Read(State(home)),"id")!=Json.Str(invite.Data,"id"))throw new IOException("Сначала завершите текущее приглашение.");
                return;
            }
            if(File.Exists(Path.Combine(home,"state","invite-used-"+Json.Str(invite.Data,"id")+".json")))throw new IOException("Приглашение уже использовано на этом компьютере.");
            Json.Write(Secret(home),invite.Data);
            var visible=Public(invite.Data);visible["source"]=Path.GetFullPath(source);visible["embedded"]=embedded;visible["registered"]=false;Json.Write(State(home),visible);
        }
        internal static void Consume(string home,Dictionary<string,object> state)
        {
            // Receipt first; never retain the enrollment key in the installed EXE/backups.
            Json.Write(Path.Combine(home,"state","invite-used-"+Json.Str(state,"id")+".json"),new {used=true});
            if(File.Exists(Secret(home)))File.Delete(Secret(home));
            string source=Json.Str(state,"source");
            if(File.Exists(source) && !Path.GetFullPath(source).Equals(Path.GetFullPath(Program.Exe),StringComparison.OrdinalIgnoreCase)){
                try{File.Delete(source);}catch(IOException){}catch(UnauthorizedAccessException){}
            }
            // An executing/locked downloaded image cannot reliably be removed on Windows.
            // Reuse is refused locally by receipt and on another PC by ra-enroll.
        }
#endif
        internal static Dictionary<string,object> Public(Dictionary<string,object> value)
        {return value.Where(p=>new[]{"schema","id","name","happier","happierAccount","folders","vpn"}.Contains(p.Key)).ToDictionary(p=>p.Key,p=>p.Value);}
    }
}
