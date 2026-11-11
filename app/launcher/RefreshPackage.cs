using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security.Cryptography;
using System.Threading;

namespace RemoteAgents.Launcher
{
    internal static class RefreshPackage
    {
#if !PORTABLE_TEST
        internal static void RememberDevice(string home,string name)
        {
            var c=Json.Read(Path.Combine(home,"config.json"));var p=Json.Read(Json.Str(Json.Map(Json.Get(c,"transport")),"profilePath"));
            string[] fields=File.ReadAllText(Json.Str(p,"keyPath")+".pub").Trim().Split(new[]{' ','\r','\n'},StringSplitOptions.RemoveEmptyEntries);
            using(var hash=SHA256.Create()){
                string id=BitConverter.ToString(hash.ComputeHash(Convert.FromBase64String(fields[1]))).Replace("-","").ToLowerInvariant().Substring(0,32);
                Json.Write(Path.Combine(home,"state","invite-device.json"),new {name,id});
            }
        }
        internal static void Apply(string home,Dictionary<string,byte[]> files)
        {
            var data=new Invitation(Json.Map(Json.Parse(System.Text.Encoding.UTF8.GetString(files["invite.rainvite"]))));
            if(!data.IsRefresh)throw new InvalidDataException("Нужен файл обновления компьютера.");
            if(Invitation.Pending(home))throw new IOException("Сначала завершите регистрацию компьютера.");
            AccountDiskSetup.ProtectSecrets(home);
            string stage=Path.Combine(home,"secrets","refresh-run-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(stage);
            try{
                string zip=Path.Combine(stage,"bundle.zip");UpgradeInstaller.ExtractEmbedded(zip);
                string bundle=Path.Combine(stage,"bundle");ZipFile.ExtractToDirectory(zip,bundle);
                string path=Path.Combine(stage,"refresh.json");Json.Write(path,data.Data);
                // New helper comes from this EXE, even when installed bundle predates refresh.
                string password=Json.Array(Json.Get(data.Data,"routes")).Select(x=>Json.Str(Json.Map(Json.Get(Json.Map(x),"hop")),"password")).FirstOrDefault(x=>x.Length>0)??"";
                using(var relay=new PasswordRelay(password,32))
                    ServerOperations.Invoke(home,bundle,"InviteRefresh",new {path,askpassExecutable=Path.Combine(home,Product.ExeName),hopPasswordPipe=relay.Name,offlineInstaller=true},CancellationToken.None);
                RememberDevice(home,Json.Str(data.Data,"name"));
            }finally{try{Directory.Delete(stage,true);}catch(IOException){}catch(UnauthorizedAccessException){}}
        }
#endif
    }
}
