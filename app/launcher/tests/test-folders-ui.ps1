#requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$AssemblyPath)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System,System.Windows.Forms,System.Drawing,System.Core,System.Web.Extensions -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Reflection;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
public static class FoldersSmoke {
    static BindingFlags flags = BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance;
    static object Call(object o, string name, params object[] args) { return o.GetType().GetMethod(name, flags).Invoke(o, args); }
    static T Field<T>(object o, string name) { return (T)o.GetType().GetField(name, flags).GetValue(o); }
    static void Check(bool ok, string name) { if (!ok) throw new Exception(name); Console.WriteLine("PASS " + name); }
    static TreeNode Node(TreeView tree, string path) { return tree.Nodes.Cast<TreeNode>().SingleOrDefault(n => (n.Tag as string) == path); }
    static void Pump() { for (int i = 0; i < 15; i++) Application.DoEvents(); }
    public static string Run(string path) {
        var asm = Assembly.LoadFrom(path);
        var data = (Dictionary<string, object>)new JavaScriptSerializer().DeserializeObject("{\"union\":{\"rows\":[{\"path\":\"Local\",\"presence\":\"local\",\"kind\":\"directory\"},{\"path\":\"Both\",\"presence\":\"both\",\"kind\":\"directory\"},{\"path\":\"Remote\",\"presence\":\"server\",\"kind\":\"directory\",\"hasChildren\":true}],\"truncated\":false}}");
        Func<string,object,Task<Dictionary<string,object>>> run = (action, request) => Task.FromResult(data);
        Func<Func<Task>,Task> guard = action => action();
        Func<bool> busy = () => false;
        var messages = new List<string>(); Action<string> log = text => messages.Add(text);
        using (var form = new Form { ClientSize = new Size(1024, 720), StartPosition = FormStartPosition.Manual, Location = new Point(0,0), Text = "Folders UI validation" }) {
            var type = asm.GetType("RemoteAgents.Launcher.DiskFoldersView", true);
            var view = (UserControl)Activator.CreateInstance(type, flags, null, new object[] { run, guard, guard, busy, log }, null);
            var choice = Activator.CreateInstance(asm.GetType("RemoteAgents.Launcher.DiskChoice", true), true);
            choice.GetType().GetField("Chosen", flags).SetValue(choice, true);
            form.Controls.Add(view); form.Show(); Pump();
            Call(view,"Initialize", choice, Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + "\\Disk", true, null, null);
            Call(view,"ShowTree",data); Pump();
            var local = Field<TreeView>(view,"computerTree"); var server = Field<TreeView>(view,"tree");
            Check(Node(local,"Local") != null && Node(local,"Both") != null && Node(local,"Remote") == null, "computer pane uses local presence");
            Check(Node(server,"Local") == null && Node(server,"Both") != null && Node(server,"Remote") != null, "server pane uses server presence");
            server.SelectedNode=Node(server,"Remote"); Field<Button>(view,"take").PerformClick(); Pump();
            Check(Node(local,"Remote") != null && Node(local,"Remote").Checked && Node(server,"Remote").Checked, "take updates both panes");
            Field<Button>(view,"stopSync").PerformClick(); Pump();
            Check(Node(local,"Remote") == null && !Node(server,"Remote").Checked, "stop removes pending download");
            local.SelectedNode=Node(local,"Local"); Field<Button>(view,"send").PerformClick(); Pump();
            Check(Node(local,"Local").Checked && Node(server,"Local") == null, "send stages upload without inventing server presence");
            var apply=Field<Button>(view,"apply"); var skip=Field<Button>(view,"skip");
            foreach (float size in new[] {9f, 14f, 18f}) {
                form.Font=new Font("Segoe UI",size); Pump();
                var lb=local.RectangleToScreen(local.ClientRectangle); var rb=server.RectangleToScreen(server.ClientRectangle);
                Check(lb.Top == rb.Top && lb.Right <= rb.Left && lb.Width > form.Font.Height * 5 && rb.Width > form.Font.Height * 5, "separate pane bounds at font " + size);
                Check(local.Height >= form.Font.Height * 10 && server.Height >= form.Font.Height * 10, "readable tree height at font " + size);
                var foot=apply.RectangleToScreen(apply.ClientRectangle);
                Check(form.RectangleToScreen(form.ClientRectangle).Contains(foot) && skip.Visible, "footer remains reachable at font " + size);
                Console.WriteLine("BOUNDS font="+size+" local="+lb+" server="+rb+" footer="+foot);
            }
            Call(view,"Initialize",choice,"C:\\DifferentDisk",false,null,null); Pump();
            Check(local.Nodes.Count == 0 && server.Nodes.Count == 0, "profile initialization clears pane caches");
            Check(messages.All(x => !x.Contains("Exception")), "no UI callback errors");
            form.Close();
        }
        return "PASS Windows WinForms folder smoke checks";
    }
}
'@
[FoldersSmoke]::Run($AssemblyPath)
