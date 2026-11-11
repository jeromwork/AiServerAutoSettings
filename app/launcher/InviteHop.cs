using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;

namespace RemoteAgents.Launcher
{
    // Persistent password hop: only an ACL-protected file path appears in ProxyCommand.
    // The password remains in this process and the existing askpass named pipe.
    internal static class InviteHop
    {
        internal static int Run(string[] args)
        {
            try {
                if(args.Length!=4)return 2;
                var c=Json.Read(args[1]);int port;
                if(!int.TryParse(args[3],out port) || port<1 || port>65535)return 2;
                using(var relay=new PasswordRelay(Json.Str(c,"password"),32)) {
                    var options=new System.Collections.Generic.List<string> {"-F",Json.Str(c,"configPath"),"-T","-o","StrictHostKeyChecking=yes","-o","GlobalKnownHostsFile=none","-o","UserKnownHostsFile="+Files.Quote(Json.Str(c,"knownHostsPath")),"-o","ForwardAgent=no","-o","ConnectTimeout=8","-o","BatchMode=no","-o","NumberOfPasswordPrompts=1","-o","PreferredAuthentications=password,keyboard-interactive","-o","PubkeyAuthentication=no","-p",Json.Str(c,"port"),"-l",Json.Str(c,"user"),"-W",args[2]+":"+port,Json.Str(c,"host")};
                    var si=new ProcessStartInfo(Json.Str(c,"sshExecutable"),Files.Arguments(options)){UseShellExecute=false,CreateNoWindow=true,RedirectStandardInput=true,RedirectStandardOutput=true,RedirectStandardError=true};
                    si.EnvironmentVariables["SSH_ASKPASS"]=Program.Exe;si.EnvironmentVariables["SSH_ASKPASS_REQUIRE"]="force";si.EnvironmentVariables["DISPLAY"]="remoteagents:0";si.EnvironmentVariables["REMOTEAGENTS_PASSWORD_PIPE"]=relay.Name;
                    using(var p=Process.Start(si)) {
                        var input=Console.OpenStandardInput();var output=Console.OpenStandardOutput();
                        var upload=new Thread(()=>{try{input.CopyTo(p.StandardInput.BaseStream);}catch{}try{p.StandardInput.Close();}catch{}}){IsBackground=true};upload.Start();
                        var errors=p.StandardError.ReadToEndAsync();p.StandardOutput.BaseStream.CopyTo(output);output.Flush();p.WaitForExit();
                        if(p.ExitCode!=0)Console.Error.WriteLine("SSH hop: соединение не выполнено; проверьте маршрут и ключ хоста.");return p.ExitCode;
                    }
                }
            }catch{return 1;}
        }
    }
}
