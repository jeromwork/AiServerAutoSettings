using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32;

namespace RemoteAgents.Launcher
{
    internal interface ILegacyPacBrowser
    {
        string Pac { get; }
        void SetPac(string value); // null restores the absence of a value
    }
    internal sealed class LegacyPacBrowser : ILegacyPacBrowser
    {
        const string PathName = @"Software\Microsoft\Windows\CurrentVersion\Internet Settings";
        object Get(string name) { using (var k = Registry.CurrentUser.OpenSubKey(PathName)) return k == null ? null : k.GetValue(name); }
        public string Pac { get { return Convert.ToString(Get("AutoConfigURL")); } }
        public void SetPac(string value)
        {
            using (var k = Registry.CurrentUser.CreateSubKey(PathName)) { if (value == null) k.DeleteValue("AutoConfigURL", false); else k.SetValue("AutoConfigURL", value, RegistryValueKind.String); }
            InternetSetOption(IntPtr.Zero, 39, IntPtr.Zero, 0); InternetSetOption(IntPtr.Zero, 37, IntPtr.Zero, 0);
        }
        [DllImport("wininet.dll", SetLastError = true)] static extern bool InternetSetOption(IntPtr handle, int option, IntPtr buffer, int length);
    }
    // Temporary recovery of the previous browser setting; never installs a proxy.
    internal static class LegacyPacCleanup
    {
        internal static void Recover(string home, ILegacyPacBrowser browser)
        {
            string path = System.IO.Path.Combine(home, "state", "lan-pac.json");
            if (!File.Exists(path)) return;
            var saved = Json.Read(path);
            string url = Json.Str(saved, "url");
            Uri parsed;
            if (!Uri.TryCreate(url, UriKind.Absolute, out parsed) || parsed.Scheme != "http" || parsed.Host != "127.0.0.1" || !parsed.AbsolutePath.EndsWith("/proxy.pac", StringComparison.Ordinal)) throw new InvalidDataException("Повреждён учёт PAC программы");
            if (browser.Pac == url) browser.SetPac(Json.Bool(saved, "hadPrevious") ? Json.Str(saved, "previous") : null);
            File.Delete(path);
        }
    }
}
