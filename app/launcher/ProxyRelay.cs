using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

namespace RemoteAgents.Launcher
{
    // ssh ProxyCommand helper: `RemoteAgents.exe --proxy-connect <socks|http> <proxyHost> <proxyPort> <destHost> <destPort>`.
    // Windows OpenSSH has no nc, so this tunnels stdin/stdout through a local SOCKS5 (no auth) or HTTP CONNECT proxy.
    internal static class ProxyRelay
    {
        const int ConnectTimeoutMs = 8000;
        internal static int Run(string[] args)
        {
            int proxyPort, destPort;
            if(args.Length!=6 || !int.TryParse(args[3],out proxyPort) || !int.TryParse(args[5],out destPort) || proxyPort<1 || proxyPort>65535 || destPort<1 || destPort>65535){Fail("нужны: тип хост-прокси порт-прокси хост порт");return 2;}
            TcpClient tcp=null;
            try {
                tcp=Connect(args[1],args[2],proxyPort,args[4],destPort,ConnectTimeoutMs);
            }catch(Exception e){Fail(e.Message);if(tcp!=null)tcp.Close();return 1;}
            using(tcp)using(var input=Console.OpenStandardInput())using(var output=Console.OpenStandardOutput())return Relay(tcp,input,output);
        }
        static void Fail(string text){try{var bytes=Encoding.UTF8.GetBytes("proxy-connect: "+text+"\n");using(var e=Console.OpenStandardError()){e.Write(bytes,0,bytes.Length);e.Flush();}}catch{}}
        // Returns a connected tunnel to dest through the proxy; the socket is closed on any failure.
        internal static TcpClient Connect(string type,string proxyHost,int proxyPort,string destHost,int destPort,int timeoutMs)
        {
            if(type!="socks" && type!="http")throw new ArgumentException("тип прокси: socks или http");
            var tcp=new TcpClient();
            try {
                var wait=tcp.BeginConnect(proxyHost,proxyPort,null,null);
                if(!wait.AsyncWaitHandle.WaitOne(timeoutMs))throw new IOException("прокси "+proxyHost+":"+proxyPort+" не отвечает ("+timeoutMs/1000+" с)");
                try{tcp.EndConnect(wait);}catch(SocketException){throw new IOException("не удалось подключиться к прокси "+proxyHost+":"+proxyPort);}
                tcp.ReceiveTimeout=timeoutMs;tcp.SendTimeout=timeoutMs;tcp.NoDelay=true;
                var s=tcp.GetStream();
                try{if(type=="socks")Socks5(s,destHost,destPort);else HttpConnect(s,destHost,destPort);}
                catch(IOException e){if(e.InnerException is SocketException)throw new IOException("прокси не ответил на запрос соединения");throw;}
                tcp.ReceiveTimeout=0;tcp.SendTimeout=0;
                return tcp;
            }catch{tcp.Close();throw;}
        }
        static void ReadExact(Stream s,byte[] buffer,int count)
        {
            int got=0;while(got<count){int n=s.Read(buffer,got,count-got);if(n<=0)throw new IOException("прокси закрыл соединение");got+=n;}
        }
        static void Socks5(Stream s,string host,int port)
        {
            s.Write(new byte[]{5,1,0},0,3);s.Flush();
            var reply=new byte[4];ReadExact(s,reply,2);
            if(reply[0]!=5 || reply[1]!=0)throw new IOException("SOCKS5-прокси требует авторизацию или не поддерживает вход без неё");
            IPAddress ip;var request=new System.Collections.Generic.List<byte>{5,1,0};
            if(IPAddress.TryParse(host,out ip)){var raw=ip.GetAddressBytes();request.Add((byte)(raw.Length==4?1:4));request.AddRange(raw);}
            else{var name=Encoding.ASCII.GetBytes(host);if(name.Length==0 || name.Length>255)throw new ArgumentException("некорректный адрес сервера");request.Add(3);request.Add((byte)name.Length);request.AddRange(name);}
            request.Add((byte)(port>>8));request.Add((byte)port);
            s.Write(request.ToArray(),0,request.Count);s.Flush();
            ReadExact(s,reply,4);
            if(reply[0]!=5)throw new IOException("ответ не SOCKS5: это не SOCKS-прокси?");
            if(reply[1]!=0)throw new IOException("SOCKS5-прокси отказал в соединении с сервером (код "+reply[1]+")");
            int rest=reply[3]==1?6:reply[3]==4?18:reply[3]==3?-1:0;
            if(rest==0)throw new IOException("некорректный ответ SOCKS5");
            if(rest<0){var len=new byte[1];ReadExact(s,len,1);rest=len[0]+2;}
            ReadExact(s,new byte[rest],rest);
        }
        static void HttpConnect(Stream s,string host,int port)
        {
            string target=(host.IndexOf(':')>=0?"["+host+"]":host)+":"+port;
            var bytes=Encoding.ASCII.GetBytes("CONNECT "+target+" HTTP/1.1\r\nHost: "+target+"\r\nProxy-Connection: keep-alive\r\n\r\n");
            s.Write(bytes,0,bytes.Length);s.Flush();
            // Read byte by byte: nothing after the header block (the SSH banner) may be consumed here.
            var head=new StringBuilder();var one=new byte[1];
            while(!head.ToString().EndsWith("\r\n\r\n",StringComparison.Ordinal)){ReadExact(s,one,1);head.Append((char)one[0]);if(head.Length>16384)throw new IOException("ответ прокси слишком длинный");}
            string line=head.ToString().Split('\n')[0].Trim();var parts=line.Split(' ');
            if(parts.Length<2 || !parts[0].StartsWith("HTTP/",StringComparison.Ordinal))throw new IOException("ответ не HTTP: это не HTTP-прокси?");
            if(parts[1].Length!=3 || parts[1][0]!='2')throw new IOException("HTTP-прокси отказал в CONNECT (код "+parts[1]+")");
        }
        internal static int Relay(TcpClient tcp,Stream input,Stream output)
        {
            var net=tcp.GetStream();
            var up=new Thread(()=>{try{var b=new byte[16384];int n;while((n=input.Read(b,0,b.Length))>0){net.Write(b,0,n);net.Flush();}}catch{}try{tcp.Client.Shutdown(SocketShutdown.Send);}catch{}}){IsBackground=true};
            var down=new Thread(()=>{try{var b=new byte[16384];int n;while((n=net.Read(b,0,b.Length))>0){output.Write(b,0,n);output.Flush();}}catch{}}){IsBackground=true};
            up.Start();down.Start();
            // Finished when the server closes; after local EOF the server gets a short moment to flush its last bytes.
            while(down.IsAlive){if(!up.IsAlive){down.Join(2000);break;}Thread.Sleep(20);}
            return 0;
        }
    }
}
