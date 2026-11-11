using System;
using System.Collections.Generic;
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
            // A section waiting for a detached server install (⏳) does not block the next ones.
            var before=new[]{true,true,true,false,true,false,false};var passable=WizardStep.Passable(before,new[]{3});
            Check(WizardStep.CanOpen(6,3,true,passable,order) && !WizardStep.CanOpen(5,3,true,passable,order) && !WizardStep.CanOpen(6,3,true,before,order), "waiting Happier lets the next sections open");
            // Budgets cover the slowest child: Account.ps1 300 s, disk install+apply 900+900 s. Server installs are
            // detached: Server/Account calls stay short, status polling is one short SSH call.
            Check(WizardStep.Timeout("Server")>=(100+60+120+120)*1000 && WizardStep.Timeout("Server")<=600*1000 && WizardStep.Timeout("Account")>=(300+60+60)*1000 && WizardStep.Timeout("Account")<=600*1000 && WizardStep.Timeout("ResumeAccount")==WizardStep.Timeout("Account") && WizardStep.Timeout("Operation")<=60*1000 && WizardStep.Timeout("Disk")>=(120+900+900)*1000, "step budgets cover their slowest child; long server installs are not waited for");
            // Reference vector: Python base64.b32encode(bytes(range(1,33))); server-account.mjs normalizeKey accepts it.
            Check(HappierKey.Format(Enumerable.Range(1,32).Select(i=>(byte)i).ToArray())=="AEBAG-BAFAY-DQQCI-KBMGA-2DQPC-AIREE-YUCUL-BOGAZ-DINRY-HI6D4-QA", "Happier key is grouped base32");
            // «Установка» list: stage k/n and elapsed time, waiting account, failure reason; hidden when all done.
            var ops=(Dictionary<string,object>)Json.Parse("{\"happier\":{\"state\":\"running\",\"stage\":2,\"stages\":3,\"step\":\"Скачиваю Happier\",\"elapsedSec\":185},\"disk\":{\"state\":\"failed\",\"reason\":\"curl: (28) timeout\"}}");
            var list=ServerOperations.Parse(ops,new[]{"happier","disk"},true);
            Check(ServerOperations.Line(list[0])=="⏳ этап 2 из 3: Скачиваю Happier, прошло 3 мин" && ServerOperations.Line(list[1])=="✗ ошибка: curl: (28) timeout" && ServerOperations.Line(list[2])=="ожидает: установка Happier", "install lines show stage, elapsed time and reason");
            Check(ServerOperations.Active(list) && ServerOperations.Visible(list) && ServerOperations.Tooltip(list)=="Идёт установка: 0 из 3", "tooltip counts finished operations");
            var dir=Path.Combine(Path.GetTempPath(),"ra-ops-"+Guid.NewGuid().ToString("N"));
            try {
                ServerOperations.Save(dir,new[]{"happier","disk"},ops,true);
                var back=ServerOperations.FromState(ServerOperations.Load(dir));
                Check(back.Count==3 && back[0].Stage==2 && back[1].State=="failed" && (DateTime.UtcNow-ServerOperations.Updated(ServerOperations.Load(dir))).TotalMinutes<1, "state survives closing the window");
                var allDone=(Dictionary<string,object>)Json.Parse("{\"happier\":{\"state\":\"finished\"},\"disk\":{\"state\":\"finished\"}}");
                var finished=ServerOperations.Parse(allDone,new[]{"happier","disk"},false);
                Check(!ServerOperations.Active(finished) && !ServerOperations.Visible(finished) && ServerOperations.Line(finished[0])=="✓ готово", "item disappears when all installs are done");
                Check(ServerOperations.Parse(allDone,new[]{"happier"},true)[1].State=="running", "finished Happier: account connection runs by itself");
            } finally { if(Directory.Exists(dir))Directory.Delete(dir,true); }
            Check(HappierKey.Create().Replace("-","").Length==52 && HappierKey.Create()!=HappierKey.Create(), "new keys are random 32-byte values");
            Check(WizardStep.Timeout("Connection")>=600*1000 && WizardStep.Timeout("Bridge")>=(300+300+120)*1000 && WizardStep.Timeout("Vpn")>420*1000 && WizardStep.Timeout("DiskTree")>=120*1000 && WizardStep.Timeout("Catalog")==120000, "step-specific deadlines");
            Check(LegacyInstall.Hold(true,"") && LegacyInstall.Hold(true,"rolled-back") && LegacyInstall.Hold(true,"preparing") && !LegacyInstall.Hold(true,"activating") && !LegacyInstall.Hold(true,"pending") && !LegacyInstall.Hold(true,"accepted") && !LegacyInstall.Hold(false,""), "old channel holds new components until cutover");
            Check(LegacyInstall.Held(true,"transport") && LegacyInstall.Held(true,"disk") && LegacyInstall.Held(true,"control") && !LegacyInstall.Held(true,"vpn") && !LegacyInstall.Held(false,"transport"), "only port/sync/bridge owners are held");
            var t0=new DateTime(2026,11,11,10,0,0,DateTimeKind.Utc);
            var p=MigrationProgress.Describe("rolled-back",t0.AddMinutes(-30),true,"old failure",t0.AddMinutes(-30),t0,t0.AddSeconds(3));
            Check(!p.Failed && !p.Handover, "a previous attempt's rollback and error are not reported as the new result");
            p=MigrationProgress.Describe("preparing",t0.AddSeconds(1),false,"",null,t0,t0.AddSeconds(30));
            Check(!p.Failed && !p.Handover && p.Text.Contains("временных портах"), "preflight progress keeps window open");
            p=MigrationProgress.Describe("preparing",t0.AddSeconds(1),true,"",null,t0,t0.AddSeconds(60));
            Check(p.Handover && !p.Failed, "window leaves before migration stops the tray");
            p=MigrationProgress.Describe("rolled-back",t0.AddSeconds(1),false,"Нет рабочего пути к серверу: x",t0.AddSeconds(50),t0,t0.AddSeconds(60));
            Check(p.Failed && p.Text.Contains("Нет рабочего пути"), "preflight failure is shown with its reason");
            p=MigrationProgress.Describe("",null,false,"Переход не выполнен: import",t0.AddSeconds(2),t0,t0.AddSeconds(5));
            Check(p.Failed, "failure before state is written is shown");
            p=MigrationProgress.Describe("",null,false,"",null,t0,t0.AddSeconds(120));
            Check(p.Failed && p.Text.Contains("не начался"), "migration that never started is reported");
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
            Console.WriteLine("OK: "+count+" lazy selection / step deadline / legacy migration checks (portable; Windows job kill requires Windows)");
        }
    }
}
