using System;
using System.IO;
using System.IO.Pipes;
using System.Security.Principal;
using System.Web.Script.Serialization;
using System.Windows.Forms;

// Маленький клиент меню Проводника Диска (V9b): без прав администратора, ничего не запускает.
// Строка запроса и имя pipe те же, что у ForwardShell в LabDiskGlue.cs.
namespace RemoteAgents.Lab.Shell
{
    internal static class Shell
    {
        [STAThread]
        static int Main(string[] args)
        {
            if (args.Length < 2 || Array.IndexOf(new[] { "download", "sync", "keep-server", "add" }, args[0]) < 0) return 1;
            try {
                var id = WindowsIdentity.GetCurrent();
                using (var pipe = new NamedPipeClientStream(".", "RemoteAgents-Lab-disk-" + (id.User != null ? id.User.Value : id.Name), PipeDirection.Out)) {
                    pipe.Connect(750);
                    var line = new JavaScriptSerializer().Serialize(new[] { args[0], args[1] });
                    using (var writer = new StreamWriter(pipe, new System.Text.UTF8Encoding(false), 4096, true)) { writer.WriteLine(line); writer.Flush(); }
                }
                return 0;
            } catch (Exception) {
                MessageBox.Show("Запустите Лабораторию (RemoteAgents-Lab) и повторите.", "RemoteAgents-Lab");
                return 1;
            }
        }
    }
}
