using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
namespace RemoteAgents.Launcher
{
    internal static class InvitationTests
    {
        static int count;
        static void Check(bool value){if(!value)throw new Exception("Invitation parser assertion failed");count++;}
        internal static void Run()
        {
            var valid=new Dictionary<string,object>{{"name","Ноутбук"},{"schema",1},{"id",new string('a',32)},{"serverAddress","server.example.invalid"},{"serverPort",2222},{"workerUser","worker"},{"enrollUser","enroll"},{"hostKeys",new[]{"ssh-ed25519 AAAA"}},{"routes",new[]{new Dictionary<string,object>{{"kind","direct"}}}},{"expiresUtc","2020-01-01T00:00:00Z"},{"happier","same"},{"folders",new[]{"Project","Project/docs"}},{"passKey","-----BEGIN OPENSSH PRIVATE KEY-----\nSECRET\n"}};
            new Invitation(valid);count++; // expired invites parse so UI can explain expiry.
            foreach(var pair in new Dictionary<string,object>{{"name",""},{"schema",2},{"id","../bad"},{"serverAddress","-option"},{"serverPort",0},{"workerUser","root;id"},{"enrollUser","a b"},{"hostKeys",new string[0]},{"routes",new object[0]},{"expiresUtc","never"},{"happier","invalid"},{"folders",new[]{"../escape"}},{"passKey","junk"},{"unknown","x"}}){var bad=new Dictionary<string,object>(valid);bad[pair.Key]=pair.Value;bool threw=false;try{new Invitation(bad);}catch(InvalidDataException){threw=true;}Check(threw);}
            Check(!Json.Encode(Invitation.Public(valid)).Contains("SECRET"));Check(!Invitation.Public(valid).ContainsKey("routes"));
            var crlf=Json.Encode(valid).Replace("\n","\r\n");new Invitation(Json.Map(Json.Parse(crlf)));count++;
            Check(Invitation.Find(new[]{"--invite","example.rainvite"},Path.GetTempPath()).EndsWith("example.rainvite"));
            Console.WriteLine("PASS: invitation parser/public receipt: "+count+" assertions");
        }
    }
}
