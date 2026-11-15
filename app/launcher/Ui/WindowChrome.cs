using System;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Microsoft.Win32;

namespace RemoteAgents.Launcher
{
    internal static class WindowChrome
    {
        // One subscription per form; also reapply after WinForms recreates the HWND.
        static readonly ConditionalWeakTable<Form, ChromeOptions> options = new ConditionalWeakTable<Form, ChromeOptions>();

        internal static void Apply(Form form, bool dark = false, bool mica = true)
        {
            try {
                if (form == null || form.IsDisposed || Environment.OSVersion.Platform != PlatformID.Win32NT) return;
                ChromeOptions state;
                if (!options.TryGetValue(form, out state)) {
                    state = new ChromeOptions();
                    options.Add(form, state);
                    form.HandleCreated += delegate { ApplyToHandle(form, state); };
                }
                state.Dark = dark;
                state.Mica = mica;
                if (form.IsHandleCreated) ApplyToHandle(form, state);
            } catch { /* Optional decoration must never prevent opening the window. */ }
        }

        static void ApplyToHandle(Form form, ChromeOptions state)
        {
            try {
                if (form.IsDisposed || !form.IsHandleCreated) return;
                int build;
                using (var key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion")) {
                    if (key == null || !int.TryParse(Convert.ToString(key.GetValue("CurrentBuildNumber"), CultureInfo.InvariantCulture), out build)) return;
                }
                if (build < 17763) return;
                int dark = state.Dark ? 1 : 0;
                DwmSetWindowAttribute(form.Handle, build >= 18985 ? 20 : 19, ref dark, sizeof(int));
                if (build >= 22000) {
                    int round = 2; // DWMWCP_ROUND
                    DwmSetWindowAttribute(form.Handle, 33, ref round, sizeof(int));
                }
                if (build >= 22621) {
                    int backdrop = state.Mica ? 2 : 1; // DWMSBT_MAINWINDOW / DWMSBT_NONE
                    DwmSetWindowAttribute(form.Handle, 38, ref backdrop, sizeof(int));
                }
                // Keep the client area opaque. No undocumented 1029 attribute or DWM glass margins.
                // Mica, when the OS renders it, is limited to the non-client title bar.
            } catch { /* Windows 10, missing DWM and registry access failures are harmless. */ }
        }

        sealed class ChromeOptions { internal bool Dark, Mica; }

        [DllImport("dwmapi.dll")]
        static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);
    }
}
