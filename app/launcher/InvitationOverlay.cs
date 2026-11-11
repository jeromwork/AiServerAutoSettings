using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security.Cryptography;
using System.Text;

namespace RemoteAgents.Launcher
{
    // Append-only envelope: PE | marker | ZIP payload | uint64 length | SHA256(prefix) | marker.
    // Hash includes the unmodified release image; integrity is not a publisher signature.
    internal static class InvitationOverlay
    {
        const int Limit = 128 * 1024 * 1024;
        static readonly byte[] Magic = Encoding.ASCII.GetBytes("RAINVITE-OV1\r\n\x1a\n");
        static void Need(bool ok) { if (!ok) throw new InvalidDataException("Файл приглашения повреждён или подменён. Скачайте его заново."); }
        internal static int PeSize(byte[] data)
        {
            try {
                Need(data.Length >= 64 && data[0] == 'M' && data[1] == 'Z');
                int pe = checked((int)BitConverter.ToUInt32(data,60));
                Need(pe >= 64 && pe + 24 <= data.Length && BitConverter.ToUInt32(data,pe) == 0x4550);
                int sections=BitConverter.ToUInt16(data,pe+6), optional=BitConverter.ToUInt16(data,pe+20), start=pe+24;
                long end=BitConverter.ToUInt32(data,start+60);
                for(int n=0;n<sections;n++) { int row=checked(start+optional+n*40); end=Math.Max(end,(long)BitConverter.ToUInt32(data,row+16)+BitConverter.ToUInt32(data,row+20)); }
                int directory=start+(BitConverter.ToUInt16(data,start)==0x20b?112:96);
                if(optional>=directory-start+40)end=Math.Max(end,(long)BitConverter.ToUInt32(data,directory+32)+BitConverter.ToUInt32(data,directory+36));
                Need(end>=64 && end<=data.Length);return (int)end;
            } catch(ArgumentException) { Need(false);throw; } catch(OverflowException) { Need(false);throw; }
        }
        internal static Dictionary<string,byte[]> Read(string file)
        {
            Need(new FileInfo(file).Length<=Limit);
            byte[] data=File.ReadAllBytes(file);int end=PeSize(data);
            if(end==data.Length)return null;
            Need(data.Length>=end+72 && data.Skip(end).Take(16).SequenceEqual(Magic) && data.Skip(data.Length-16).SequenceEqual(Magic));
            Need(BitConverter.ToUInt64(data,data.Length-56)==(ulong)(data.Length-end-72));
            using(var hash=SHA256.Create())Need(hash.ComputeHash(data,0,data.Length-48).SequenceEqual(data.Skip(data.Length-48).Take(32)));
            var result=new Dictionary<string,byte[]>();
            using(var stream=new MemoryStream(data,end+16,data.Length-end-72))
            using(var zip=new ZipArchive(stream,ZipArchiveMode.Read)) {
                long total=0;
                foreach(var entry in zip.Entries) {
                    Need(new[]{"invite.rainvite","sing-box.exe"}.Contains(entry.FullName) && !result.ContainsKey(entry.FullName));
                    total+=entry.Length;Need(total<=Limit);
                    using(var input=entry.Open())using(var output=new MemoryStream()) { input.CopyTo(output);Need(output.Length==entry.Length);result.Add(entry.FullName,output.ToArray()); }
                }
            }
            Need(result.ContainsKey("invite.rainvite"));return result;
        }
        internal static void CopyBase(string source,string target)
        {
            var data=File.ReadAllBytes(source);
            if(data.Length<2 || data[0]!='M' || data[1]!='Z'){File.Copy(source,target,true);return;}
            var payload=Read(source);
            using(var output=File.Create(target))output.Write(data,0,payload==null?data.Length:PeSize(data));
        }
#if !PORTABLE_TEST
        internal static bool Stage(string home,string source)
        {
            var files=Read(source);if(files==null)return false;
            var invite=new Invitation(Json.Map(Json.Parse(Encoding.UTF8.GetString(files["invite.rainvite"]))));
            if(invite.IsRefresh)throw new IOException("Запустите файл обновления обычным двойным щелчком.");
            string receipt=Path.Combine(home,"state","invite-used-"+Json.Str(invite.Data,"id")+".json");
            // Do not overwrite a durable enrollment receipt after interruption.
            if(Invitation.Pending(home)) {
                var pending=Json.Read(Invitation.State(home));
                if(Json.Str(pending,"id")!=Json.Str(invite.Data,"id"))throw new IOException("Сначала завершите текущее приглашение.");
                return true;
            }
            if(File.Exists(receipt))throw new IOException("Приглашение уже использовано на этом компьютере.");
            AccountDiskSetup.ProtectSecrets(home);
            if(files.ContainsKey("sing-box.exe")) {
                string binary=Path.Combine(home,"transport-bin","sing-box.exe");Directory.CreateDirectory(Path.GetDirectoryName(binary));
                File.WriteAllBytes(binary,files["sing-box.exe"]);
            }
            Invitation.StageData(home,invite,source,true);return true;
        }
#endif
    }
}
