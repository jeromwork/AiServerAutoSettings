using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
#if !PORTABLE_TEST
using Microsoft.Win32;
using System.Diagnostics;
using System.Management;
using Microsoft.Win32.SafeHandles;
#endif

namespace RemoteAgents.Launcher
{
    internal interface ILegacyDiskSystem
    {
        bool FileExists(string path);
        bool DirectoryExists(string path);
        string Read(string path);
        IEnumerable<string> Entries(string path);
        FileAttributes Attributes(string path);
        void Attributes(string path, FileAttributes value);
        void DeleteFile(string path);
        void DeleteDirectory(string path); // never recursive; junction targets must survive
        string JunctionTarget(string path);
        IEnumerable<string> Keys(string key);
        IEnumerable<string> Values(string key);
        string Value(string key, string name);
        void DeleteKey(string key);
        void DeleteValue(string key, string name);
        void StopProcesses(string home);
        void RemoveShortcuts(string home);
        void Notify();
    }
    // Retirement only. Receipts establish ownership; unrecognized data/links/registry values stay.
    internal sealed class LegacyDiskMigration
    {
        internal const string Owner = "RemoteAgents.Disk.v1";
        internal const string Menu = @"Software\Classes\Directory\shell";
        internal const string Run = @"Software\Microsoft\Windows\CurrentVersion\Run";
        internal const string NavId = "{5D8A825B-EDEA-4B5E-97FC-96ABDC8A78E9}";
        readonly ILegacyDiskSystem system;
        internal LegacyDiskMigration(ILegacyDiskSystem system) { this.system = system; }
        bool Safe(string path)
        {
            for (string p = Path.GetFullPath(path); !string.IsNullOrEmpty(p); p = Path.GetDirectoryName(p))
                if ((system.FileExists(p) || system.DirectoryExists(p)) && (system.Attributes(p) & FileAttributes.ReparsePoint) != 0) return false;
            return true;
        }
        static bool Same(string a, string b)
        { return string.Equals(Path.GetFullPath(a).TrimEnd('\\', '/'), Path.GetFullPath(b).TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase); }
        internal static bool OwnedExecutable(string value, string home)
        {
            string text = (value ?? "").Trim(), exe;
            if (text.StartsWith("\"")) { int end = text.IndexOf('"', 1); if (end < 0) return false; exe = text.Substring(1, end - 1); }
            else { int end = text.IndexOf(' '); exe = end < 0 ? text : text.Substring(0, end); }
            try { return new[] { "tray/syncthingtray.exe", "bin/syncthing.exe", "syncthing.exe" }.Any(p => Same(exe.Replace('/', Path.DirectorySeparatorChar), Path.Combine(home, p.Replace('/', Path.DirectorySeparatorChar)))); }
            catch { return false; }
        }
        internal static bool OwnedProcess(string executable, string command, string home)
        {
            if (string.IsNullOrWhiteSpace(command) || !OwnedExecutable(Files.Quote(executable), home)) return false;
            string line = (command ?? "").Replace('/', '\\');
            if (!Path.GetFileName(executable).Equals("syncthing.exe", StringComparison.OrdinalIgnoreCase) && !Regex.IsMatch(line, @"(?:^|\s)""?syncthing""?(?:\s|$)", RegexOptions.IgnoreCase)) return true;
            string state = Path.GetFullPath(Path.Combine(home, "state")).Replace('/', '\\');
            return Regex.IsMatch(line, @"(?:^|\s)""?--home(?:""?\s+|=)""?" + Regex.Escape(state) + @"""?(?=\s|$)", RegexOptions.IgnoreCase);
        }
        internal void Clean(string legacyHome, IEnumerable<string> roots)
        {
            if (!Safe(legacyHome)) throw new IOException("Служебная папка прежнего Диска является ссылкой");
            system.StopProcesses(legacyHome);
            foreach (string name in system.Values(Run).ToArray())
                if (OwnedExecutable(system.Value(Run, name), legacyHome)) system.DeleteValue(Run, name);
            system.RemoveShortcuts(legacyHome);
            foreach (string child in system.Keys(Menu).Where(k => k.StartsWith("RemoteAgents.Disk.", StringComparison.Ordinal)).ToArray()) {
                string key = Menu + "\\" + child;
                if (system.Value(key, "RemoteAgentsOwner") == Owner) system.DeleteKey(key);
            }
            // This fixed product CLSID was allocated by Disk.NavPane.ps1 in both registry views.
            foreach (string prefix in new[] { @"Software\Classes\CLSID\", @"Software\Classes\Wow6432Node\CLSID\" }) system.DeleteKey(prefix + NavId);
            system.DeleteKey(@"Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\" + NavId);
            system.DeleteValue(@"Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel", NavId);
            var bases = roots.Where(p => !string.IsNullOrWhiteSpace(p)).ToList();
            string baseReceipt = Path.Combine(legacyHome, "base.txt");
            if (system.FileExists(baseReceipt) && Safe(baseReceipt)) bases.Add(Files.LF(system.Read(baseReceipt)).Trim());
            string external = Path.Combine(legacyHome, "external.json");
            if (system.FileExists(external) && Safe(external)) {
                var receipt = Json.Map(Json.Parse(Files.LF(system.Read(external))));
                if (Json.Int(receipt, "schema", 0) != 1) throw new IOException("Неизвестный формат прежних соединений каталогов");
                foreach (var item in Json.Array(Json.Get(receipt, "items")).Select(Json.Map)) {
                    string link = Json.Str(item, "junction"), target = Json.Str(item, "path"), remote = Json.Str(item, "remote");
                    if (target.Length > 0) CleanupMetadata(target);
                    // Only the junction at the recorded Disk root, still pointing to the recorded target.
                    if (link.Length == 0 || target.Length == 0 || string.IsNullOrEmpty(remote) || Path.GetFileName(remote) != remote) continue;
                    if (!bases.Any(b => Same(link, Path.Combine(b, remote)))) continue;
                    string parent = Path.GetDirectoryName(Path.GetFullPath(link));
                    if (!Safe(parent)) continue;
                    string current = system.JunctionTarget(link);
                    if (current != null && Same(current, target)) system.DeleteDirectory(link);
                }
            }
            foreach (string root in bases.Where(p => !string.IsNullOrWhiteSpace(p)).Distinct(StringComparer.OrdinalIgnoreCase)) {
                if (!system.DirectoryExists(root) || !Safe(root)) continue;
                CleanupMetadata(root);
                foreach (string path in system.Entries(root).ToArray()) if (system.DirectoryExists(path)) CleanupMetadata(path);
            }
            string icons = Path.Combine(Path.GetDirectoryName(legacyHome), "RemoteAgents", "icons");
            if (system.DirectoryExists(icons) && Safe(icons)) foreach (string path in system.Entries(icons).ToArray())
                if (Path.GetFileName(path).StartsWith("RemoteAgents.Disk.", StringComparison.Ordinal) && system.FileExists(path) && Safe(path)) DeleteFile(path);
            foreach (string name in new[] { "state", "tray", "bin", "selection-policies", "logs" }) DeleteService(Path.Combine(legacyHome, name));
            foreach (string name in new[] { "selection.json", "external.json", "external-exclusions.json", "base.txt", "server.txt", "profile.txt", "folders.lock", "managed-folders.json", "status.json", "syncthing.pid" }) DeleteService(Path.Combine(legacyHome, name));
            if (system.DirectoryExists(legacyHome)) foreach (string path in system.Entries(legacyHome).ToArray())
                if (Path.GetFileName(path).EndsWith(".log", StringComparison.OrdinalIgnoreCase) || Path.GetFileName(path).EndsWith(".log.1", StringComparison.OrdinalIgnoreCase)) DeleteService(path);
            system.Notify();
        }
        void CleanupMetadata(string folder)
        {
            if (!system.DirectoryExists(folder) || !Safe(folder)) return;
            string ini = Path.Combine(folder, "desktop.ini");
            if (!system.FileExists(ini) || !Safe(ini)) return;
            string section = ""; var fields = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (string raw in Files.LF(system.Read(ini)).Split('\n')) {
                string line = raw.Trim();
                if (line.StartsWith("[") && line.EndsWith("]")) { section = line; continue; }
                int eq = line.IndexOf('=');
                if (section.Equals("[RemoteAgents]", StringComparison.OrdinalIgnoreCase) && eq > 0) fields[line.Substring(0, eq).Trim()] = line.Substring(eq + 1).Trim();
            }
            string owner, original;
            if (!fields.TryGetValue("Owner", out owner) || owner != Owner || !fields.TryGetValue("OriginalReadOnly", out original) || (original != "0" && original != "1")) return;
            var attributes = system.Attributes(folder);
            system.Attributes(folder, original == "1" ? attributes | FileAttributes.ReadOnly : attributes & ~FileAttributes.ReadOnly);
            DeleteFile(ini);
        }
        void DeleteFile(string path) { system.Attributes(path, FileAttributes.Normal); system.DeleteFile(path); }
        void DeleteService(string path)
        {
            if (!Safe(path)) throw new IOException("Служебный путь прежнего Диска является ссылкой");
            if (system.DirectoryExists(path)) { foreach (string child in system.Entries(path).ToArray()) DeleteService(child); system.Attributes(path, FileAttributes.Normal); system.DeleteDirectory(path); }
            else if (system.FileExists(path)) DeleteFile(path);
        }
#if !PORTABLE_TEST
        internal static void RunWindows(string home, Action<string> log, bool force = false)
        {
            string marker = Path.Combine(home, "state", "legacy-disk-removed-v1");
            if (!force && File.Exists(marker)) return;
            string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            var settings = new Configuration(home).Data; var profile = Json.Map(Json.Get(settings, "profile"));
            var roots = new[] { Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Disk"), Json.Str(Json.Map(Json.Get(profile, "disk")), "base") };
            try {
                new LegacyDiskMigration(new WindowsSystem()).Clean(Path.Combine(local, "RemoteDisk"), roots);
                new Configuration(home).Edit(c => { c.Remove("disk"); var oldProfile = Json.Map(Json.Get(c, "profile")); oldProfile.Remove("disk");
                    Json.Map(Json.Get(oldProfile, "components")).Remove("disk"); Json.Map(Json.Get(c, "components")).Remove("disk");
                    var wizard = Json.Map(Json.Get(c, "wizard")); foreach (string key in new[] { "skipDisk", "diskPreviousProfile", "diskKeepPrevious" }) wizard.Remove(key); });
                Files.Atomic(marker, "1\n"); log("migration.disk.removed");
            } catch { log("migration.disk.failed"); throw new IOException("Не удалось убрать прежний Диск. Файлы пользователя сохранены. Закройте Syncthing и повторите запуск; подробности — в журнале лаунчера."); }
        }
        sealed class WindowsSystem : ILegacyDiskSystem
        {
            public bool FileExists(string p) { return File.Exists(p); }
            public bool DirectoryExists(string p) { return Directory.Exists(p); }
            public string Read(string p) { return File.ReadAllText(p); }
            public IEnumerable<string> Entries(string p) { return Directory.GetFileSystemEntries(p); }
            public FileAttributes Attributes(string p) { return File.GetAttributes(p); }
            public void Attributes(string p, FileAttributes a) { File.SetAttributes(p, a); }
            public void DeleteFile(string p) { File.Delete(p); }
            public void DeleteDirectory(string p) { Directory.Delete(p, false); }
            RegistryKey Hive() { return RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, Environment.Is64BitOperatingSystem ? RegistryView.Registry64 : RegistryView.Default); }
            public IEnumerable<string> Keys(string k) { using (var h = Hive()) using (var key = h.OpenSubKey(k)) return key == null ? new string[0] : key.GetSubKeyNames(); }
            public IEnumerable<string> Values(string k) { using (var h = Hive()) using (var key = h.OpenSubKey(k)) return key == null ? new string[0] : key.GetValueNames(); }
            public string Value(string k, string n) { using (var h = Hive()) using (var key = h.OpenSubKey(k)) return key == null ? null : Convert.ToString(key.GetValue(n)); }
            public void DeleteKey(string k) { using (var h = Hive()) h.DeleteSubKeyTree(k, false); }
            public void DeleteValue(string k, string n) { using (var h = Hive()) using (var key = h.OpenSubKey(k, true)) if (key != null) key.DeleteValue(n, false); }
            public void Notify() { SHChangeNotify(0x08000000, 0, IntPtr.Zero, IntPtr.Zero); }
            public void StopProcesses(string home)
            {
                using (var query = new ManagementObjectSearcher("SELECT ProcessId,ExecutablePath,CommandLine,CreationDate FROM Win32_Process WHERE Name='syncthingtray.exe' OR Name='syncthing.exe'")) {
                    var rows = query.Get().Cast<ManagementObject>().OrderBy(p => Convert.ToString(p["CommandLine"]).Contains("serve") ? 1 : 0).ToArray();
                    foreach (var row in rows) using (row) {
                        string executable = Convert.ToString(row["ExecutablePath"]), command = Convert.ToString(row["CommandLine"]);
                        if (!OwnedProcess(executable, command, home)) continue;
                        using (var live = new ManagementObject("Win32_Process.Handle='" + row["ProcessId"] + "'")) {
                            try { live.Get(); } catch (ManagementException) { continue; }
                            if (Convert.ToString(live["CreationDate"]) != Convert.ToString(row["CreationDate"]) || Convert.ToString(live["ExecutablePath"]) != executable) continue;
                            using (var p = Process.GetProcessById(Convert.ToInt32(row["ProcessId"]))) { p.Kill(); if (!p.WaitForExit(10000)) throw new IOException("Прежний Syncthing ещё работает"); }
                        }
                    }
                }
            }
            public void RemoveShortcuts(string home)
            {
                foreach (var place in new[] { Environment.SpecialFolder.Startup, Environment.SpecialFolder.DesktopDirectory, Environment.SpecialFolder.Programs }) {
                    string directory = Environment.GetFolderPath(place); if (!Directory.Exists(directory)) continue;
                    // Only these product shortcuts, each with a verified executable target.
                    foreach (string name in new[] { "RemoteDisk.lnk", "Syncthing.lnk", "Syncthing Tray.lnk", "RemoteAgents Disk.lnk" }) {
                        string file = Path.Combine(directory, name); if (!File.Exists(file)) continue;
                        dynamic shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell")); dynamic link = null;
                        try { link = shell.CreateShortcut(file); if (OwnedExecutable(Files.Quote((string)link.TargetPath), home)) File.Delete(file); }
                        finally { if (link != null) Marshal.FinalReleaseComObject(link); Marshal.FinalReleaseComObject(shell); }
                    }
                }
            }
            public string JunctionTarget(string path)
            {
                using (var file = CreateFile(path, 0, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero)) {
                    if (file.IsInvalid) return null;
                    var buffer = new byte[16384]; int size;
                    if (!DeviceIoControl(file, 0x900A8, IntPtr.Zero, 0, buffer, buffer.Length, out size, IntPtr.Zero) || size < 16 || BitConverter.ToUInt32(buffer, 0) != 0xA0000003) return null;
                    int offset = BitConverter.ToUInt16(buffer, 8), length = BitConverter.ToUInt16(buffer, 10);
                    if (16 + offset + length > size) return null;
                    string target = Encoding.Unicode.GetString(buffer, 16 + offset, length);
                    return target.StartsWith(@"\??\UNC\") ? @"\\" + target.Substring(8) : target.StartsWith(@"\??\") ? target.Substring(4) : target;
                }
            }
            [DllImport("shell32.dll")] static extern void SHChangeNotify(int ev, uint flags, IntPtr a, IntPtr b);
            [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint mode, uint flags, IntPtr template);
            [DllImport("kernel32.dll", SetLastError = true)] static extern bool DeviceIoControl(SafeFileHandle file, uint code, IntPtr input, int inputLength, byte[] output, int outputLength, out int returned, IntPtr overlapped);
        }
#endif
    }
}
