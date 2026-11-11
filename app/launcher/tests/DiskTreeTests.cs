using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;

namespace RemoteAgents.Launcher
{
    internal static class DiskTreeTests
    {
        static int count;
        static void Check(bool value, string message) { if (!value) throw new Exception(message); count++; }
        internal static void Run()
        {
            var s = new DiskTreeSelection(new[] {"project"});
            Check(s.Paths.SequenceEqual(new[] {"project"}) && s.Includes("project/unopened/deep"), "unopened folder is recursive without inventory");
            s.Level("project", new[] {"project/src", "project/docs", "project/readme"}, false);
            s.Level("project/src", new[] {"project/src/a", "project/src/b"}, false);
            s.Set("project/src/a", false);
            Check(s.Paths.SequenceEqual(new[] {"project/docs", "project/readme", "project/src/b"}), "deselect nested file preserves unopened siblings");
            Check(s.Partial("project") && s.Partial("project/src"), "partial markers use saved selection");
            s.Set("project", true);Check(s.Paths.SequenceEqual(new[] {"project"}), "reselect collapses descendants");
            s.Set("project", false);Check(s.Paths.Length==0, "unchecked unopened parent clears descendants");
            s = new DiskTreeSelection(new[] {"project/notLoaded/deep.txt", "absent/project"});
            s.Level("project", new[] {"project/notLoaded"}, false);
            Check(s.Partial("project") && s.Paths.Length==2, "saved deep and absent paths survive initial load");
            s.Set("project/notLoaded", false);Check(s.Paths.SequenceEqual(new[] {"absent/project"}), "hidden descendant deselected without fetching");
            s = new DiskTreeSelection(new[] {"project"});s.Level("project", new[] {"project/a"}, true);
            bool refused=false;try{s.Set("project/a", false);}catch(IOException){refused=true;}
            Check(refused && s.Paths.SequenceEqual(new[] {"project"}), "truncation cannot silently unselect omitted siblings");
            s.Set("project",false);Check(s.Paths.Length==0, "truncated parent can be unchecked as a whole");
            int[] order={0,1,4,2,3,6,5,7};var done=new[]{true,false,false,false,true,false,false};
            Check(WizardStep.CanOpen(0,1,true,done,order) && WizardStep.CanOpen(4,1,true,done,order), "first run reopens completed sections");
            Check(WizardStep.CanOpen(1,4,true,done,order) && !WizardStep.CanOpen(2,1,true,done,order) && !WizardStep.CanOpen(7,1,true,done,order), "first run blocks sections after the first unfinished one");
            Check(WizardStep.CanOpen(2,1,false,done,order) && WizardStep.CanOpen(7,1,false,done,order), "settings open any section");
            Check(WizardStep.CanOpen(7,5,true,Enumerable.Repeat(true,7).ToArray(),order), "summary opens once all sections are ready");
            Check(WizardStep.Timeout("DiskTree")==60000 && WizardStep.Timeout("Catalog")==120000 && WizardStep.Timeout("Disk")==300000, "step-specific deadlines");
            // Real portable processes exercise the exact wait used by External.Run. NativeJob's Windows tree kill is a live check.
            for(int mode=0;mode<2;mode++) {
                var psi=new ProcessStartInfo("/bin/sleep", "10") {UseShellExecute=false};
                using(var process=Process.Start(psi))using(var cancel=new CancellationTokenSource()) {
                    var timer=Stopwatch.StartNew();bool interrupted=false;
                    if(mode==1)cancel.CancelAfter(100);
                    try{WizardStep.Wait(process,null,mode==0?150:5000,1024,cancel.Token);}
                    catch(TimeoutException){interrupted=mode==0;}
                    catch(OperationCanceledException){interrupted=mode==1;}
                    finally{if(!process.HasExited){process.Kill();process.WaitForExit();}}
                    Check(interrupted && timer.ElapsedMilliseconds<2000 && process.HasExited,mode==0?"step timeout is bounded":"step cancellation is bounded");
                }
            }
            Console.WriteLine("OK: "+count+" lazy selection / step deadline checks (portable; Windows job kill requires Windows)");
        }
    }
}
