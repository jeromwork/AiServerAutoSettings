using System;
using System.IO;
using System.Linq;
using System.Reflection;
namespace RemoteAgents.Launcher
{
    internal static class OverlayTests
    {
        internal static int Run(string directory)
        {
            int checks=0;
            foreach(string file in Directory.GetFiles(directory,"*.exe")) {
                bool bad=Path.GetFileName(file).StartsWith("bad"),plain=Path.GetFileName(file)=="plain.exe",failed=false;
                try {
                    var payload=InvitationOverlay.Read(file);
                    if((payload==null)!=plain)throw new Exception("Wrong payload presence");
                    if(payload!=null)new Invitation(Json.Map(Json.Parse(System.Text.Encoding.UTF8.GetString(payload["invite.rainvite"]))));
                    // Exercise the real CLR PE loader and embedded resources with and without overlay.
                    var assembly=Assembly.Load(File.ReadAllBytes(file));
                    if(assembly.GetName().Name!="RemoteAgents" || !assembly.GetManifestResourceNames().Contains("RemoteAgents.InitialBundle.zip"))throw new Exception("PE loader/resources failed");
                    using(var resource=assembly.GetManifestResourceStream("RemoteAgents.InitialBundle.zip"))if(resource.ReadByte()!='P' || resource.ReadByte()!='K')throw new Exception("Bundle resource failed");
                    // Once final release is built, also invoke its actual parser through the loaded PE.
                    var type=assembly.GetType("RemoteAgents.Launcher.InvitationOverlay");
                    if(type!=null)type.GetMethod("Read",BindingFlags.NonPublic|BindingFlags.Static).Invoke(null,new object[]{file});
                    if(!plain){string clean=file+".clean";InvitationOverlay.CopyBase(file,clean);if(!File.ReadAllBytes(clean).SequenceEqual(File.ReadAllBytes(Path.Combine(directory,"plain.exe"))))throw new Exception("Installed image retained overlay");File.Delete(clean);}
                } catch(InvalidDataException) {failed=true;} catch(ArgumentException) {failed=true;}
                if(bad!=failed)throw new Exception("Unexpected overlay result: "+Path.GetFileName(file));checks++;
            }
            Console.WriteLine("PASS: cross-language overlay integrity, CLR PE loading/resources, installed image stripping: "+checks+" files");return 0;
        }
    }
}
