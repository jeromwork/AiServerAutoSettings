using System;
using System.IO;
using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Threading.Tasks;

namespace RemoteAgents.Launcher
{
    // One askpass response, current Windows SID only. Neither password nor payload touches disk/argv/env.
    internal sealed class PasswordRelay : IDisposable
    {
        readonly NamedPipeServerStream server;
        internal readonly string Name;
        // uses>1: one root/sudo password for one operation (several SSH sessions), still memory only.
        internal PasswordRelay(string password, int uses = 1)
        {
            if(string.IsNullOrEmpty(password)){Name="";return;}
            Name="RemoteAgents.Password."+Guid.NewGuid().ToString("N");
            var security=new PipeSecurity();security.SetAccessRuleProtection(true,false);
            security.AddAccessRule(new PipeAccessRule(WindowsIdentity.GetCurrent().User,PipeAccessRights.FullControl,AccessControlType.Allow));
            server=new NamedPipeServerStream(Name,PipeDirection.Out,1,PipeTransmissionMode.Byte,PipeOptions.Asynchronous,4096,4096,security);
            _ = Serve(password, Math.Max(1, uses));
        }
        async Task Serve(string password, int uses)
        {
            try {
                for(int i=0;i<uses;i++) {
                    await server.WaitForConnectionAsync();
                    using(var writer=new StreamWriter(server,new UTF8Encoding(false),4096,true)){await writer.WriteLineAsync(password);await writer.FlushAsync();}
                    server.WaitForPipeDrain();server.Disconnect();
                }
            }catch(ObjectDisposedException){}catch(IOException){}catch(InvalidOperationException){}
            finally{password=null;}
        }
        internal static int Answer(string name)
        {
            if(!name.StartsWith("RemoteAgents.Password.",StringComparison.Ordinal))return 1;
            try {
                using(var pipe=new NamedPipeClientStream(".",name,PipeDirection.In,PipeOptions.None,TokenImpersonationLevel.Identification)){
                    pipe.Connect(5000);using(var reader=new StreamReader(pipe,new UTF8Encoding(false))){string password=reader.ReadLine();if(password==null)return 1;var bytes=new UTF8Encoding(false).GetBytes(password+"\n");using(var output=Console.OpenStandardOutput()){output.Write(bytes,0,bytes.Length);output.Flush();}Array.Clear(bytes,0,bytes.Length);return 0;}
                }
            }catch{return 1;}
        }
        public void Dispose(){if(server!=null)server.Dispose();}
    }
}
