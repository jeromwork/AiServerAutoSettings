using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.Principal;
using System.Threading;
using System.Xml;

namespace RemoteAgents.Launcher
{
    // Only this component's on-demand task is elevated. The tray always stays at normal integrity.
    internal sealed class ElevatedTask : IDisposable
    {
        readonly string home, name, taskName, directory; dynamic service, task;
        public ElevatedTask(string home, string name)
        {
            this.home = home; this.name = name; directory = Path.Combine(home, "state", "elevated"); Directory.CreateDirectory(directory);
            taskName = Program.InstanceName(home, WindowsIdentity.GetCurrent().User) + "." + name;
            service = Activator.CreateInstance(Type.GetTypeFromProgID("Schedule.Service")); service.Connect();
            try { task = service.GetFolder("\\").GetTask(taskName); } catch { task = null; }
        }
        public bool Registered { get { return task != null; } }
        public void Register()
        {
            string target = Path.Combine(home, "RemoteAgents.exe");
            if (!File.Exists(target)) throw new IOException("Сначала установите лаунчер");
            string xml = Path.Combine(directory, name + ".task.xml");
            const string ns = "http://schemas.microsoft.com/windows/2004/02/mit/task";
            using (var w = XmlWriter.Create(xml, new XmlWriterSettings { Indent = true, Encoding = Files.Utf8 })) {
                w.WriteStartElement("Task", ns); w.WriteAttributeString("version", "1.2");
                w.WriteStartElement("Principals"); w.WriteStartElement("Principal"); w.WriteAttributeString("id", "Owner");
                w.WriteElementString("UserId", WindowsIdentity.GetCurrent().User.Value); w.WriteElementString("LogonType", "InteractiveToken"); w.WriteElementString("RunLevel", "HighestAvailable"); w.WriteEndElement(); w.WriteEndElement();
                w.WriteStartElement("Settings"); w.WriteElementString("MultipleInstancesPolicy", "IgnoreNew"); w.WriteElementString("DisallowStartIfOnBatteries", "false"); w.WriteElementString("StopIfGoingOnBatteries", "false"); w.WriteElementString("ExecutionTimeLimit", "PT0S"); w.WriteEndElement();
                w.WriteStartElement("Actions"); w.WriteAttributeString("Context", "Owner"); w.WriteStartElement("Exec");
                w.WriteElementString("Command", target); w.WriteElementString("Arguments", "--elevated-component " + name + " --home " + Files.Quote(home)); w.WriteElementString("WorkingDirectory", home);
                w.WriteEndElement(); w.WriteEndElement(); w.WriteEndElement();
            }
            using (var process = Process.Start(new ProcessStartInfo("schtasks.exe", Files.Arguments(new[] { "/Create", "/TN", taskName, "/XML", xml, "/F" })) { UseShellExecute = true, Verb = "runas", WindowStyle = ProcessWindowStyle.Hidden })) {
                if (!process.WaitForExit(120000) || process.ExitCode != 0) throw new IOException("Задача не создана");
            }
            task = service.GetFolder("\\").GetTask(taskName);
        }
        public bool Alive { get { if (task == null) return false; try { int state = task.State; return state == 4 || state == 2; } catch { return false; } } }
        public void Start()
        {
            if (!Registered) throw new InvalidOperationException("Задача не установлена");
            string stop = Path.Combine(directory, name + ".stop"); if (File.Exists(stop)) File.Delete(stop);
            using (var parent = Process.GetCurrentProcess()) Json.Write(Path.Combine(directory, name + ".request.json"), new { pid = parent.Id, startedTicks = parent.StartTime.ToUniversalTime().Ticks.ToString() });
            task.Run(null);
        }
        public void Dispose()
        {
            if (task != null && Alive) {
                Files.Atomic(Path.Combine(directory, name + ".stop"), "stop\n");
                var watch = Stopwatch.StartNew(); while (Alive && watch.ElapsedMilliseconds < 5000) Thread.Sleep(100);
                if (Alive) task.Stop(0);
            }
            task = null; service = null;
        }
        public static int RunComponent(string home, string name)
        {
            string directory = Path.Combine(home, "state", "elevated");
            var engine = new UpdateEngine(home, Program.Version); string bundle = engine.Folder(engine.Current);
            var c = BundleDefinition.Load(bundle).Components.Single(x => x.Name == name && x.Elevated);
            var request = Json.Read(Path.Combine(directory, name + ".request.json"));
            using (var parent = Process.GetProcessById(Json.Int(request, "pid", 0))) {
                if (parent.StartTime.ToUniversalTime().Ticks.ToString() != Json.Str(request, "startedTicks") || !parent.MainModule.FileName.Equals(Path.Combine(home, "RemoteAgents.exe"), StringComparison.OrdinalIgnoreCase)) return 1;
                Func<string, string> expand = s => Environment.ExpandEnvironmentVariables(s.Replace("{bundle}", bundle).Replace("{home}", home).Replace("{pid}", parent.Id.ToString()));
                using (var job = new NativeJob()) using (var child = job.Start(expand(c.Exe), c.Args.Select(expand).ToArray(), expand(c.Cwd))) {
                    while (!parent.HasExited && !child.WaitForExit(250) && !File.Exists(Path.Combine(directory, name + ".stop"))) { }
                    return child.HasExited ? child.ExitCode : 0;
                }
            }
        }
    }
}
