using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
#if !PORTABLE_TEST
using System.Security.AccessControl;
using System.Security.Principal;
#endif

namespace RemoteAgents.Launcher
{
    internal static class SecretVault
    {
        internal static bool Windows { get { return Environment.OSVersion.Platform == PlatformID.Win32NT; } }
        internal static string VaultPath(string home) { return Path.Combine(Path.GetFullPath(home), "secrets", "vault.json"); }
        internal sealed class Lease : IDisposable
        {
            readonly Mutex mutex;
            internal Lease(string home)
            {
                string path = Path.GetFullPath(home).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar).ToLowerInvariant();
                string fingerprint;
                using (var sha = SHA256.Create()) fingerprint = BitConverter.ToString(sha.ComputeHash(Files.Utf8.GetBytes("CONFIG\n" + path))).Replace("-", "").ToLowerInvariant();
                mutex = new Mutex(false, "Global\\RemoteAgentsConfig-" + fingerprint);
                bool owned; try { owned = mutex.WaitOne(5000); } catch (AbandonedMutexException) { owned = true; }
                if (!owned) { mutex.Dispose(); throw new IOException("Конфиг занят"); }
            }
            public void Dispose() { mutex.ReleaseMutex(); mutex.Dispose(); }
        }
        internal static void SafePath(string home, string path)
        {
            home = Path.GetFullPath(home).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            path = Path.GetFullPath(path);
            var comparison = Windows ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
            if (path != home && !path.StartsWith(home + Path.DirectorySeparatorChar, comparison)) throw ConfigBundle.Bad("Секретный путь должен быть внутри каталога программы");
            // Reject reparse points (including parent links), never follow a redirected secret path.
            for (string p = path; !string.IsNullOrEmpty(p); p = Path.GetDirectoryName(p)) {
                try { if ((File.GetAttributes(p) & FileAttributes.ReparsePoint) != 0) throw ConfigBundle.Bad("Секретный путь не должен быть ссылкой"); }
                catch (FileNotFoundException) { } catch (DirectoryNotFoundException) { }
            }
        }
        [DllImport("libc", SetLastError = true, EntryPoint = "chmod")]
        static extern int Chmod(string path, uint mode);
        internal static void Protect(string path, bool directory)
        {
            if (!Windows) { if (Chmod(path, directory ? 448u : 384u) != 0) throw new IOException("Не удалось ограничить права секретов"); return; }
#if !PORTABLE_TEST
            var sid = WindowsIdentity.GetCurrent().User;
            if (directory) {
                var acl = new DirectorySecurity(); acl.SetAccessRuleProtection(true, false);
                acl.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
                Directory.SetAccessControl(path, acl);
            } else {
                var acl = new FileSecurity(); acl.SetAccessRuleProtection(true, false);
                acl.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, AccessControlType.Allow));
                File.SetAccessControl(path, acl);
            }
#else
            throw new PlatformNotSupportedException("Проверка Windows ACL требует сборки .NET Framework");
#endif
        }
        internal static void WritePrivate(string home, string path, string text)
        {
            SafePath(home, path);
            string directory = Path.GetDirectoryName(path);
            Directory.CreateDirectory(directory); Protect(directory, true);
            string temp = Path.Combine(directory, "." + Guid.NewGuid().ToString("N") + ".tmp");
            try {
                using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None)) {
                    Protect(temp, false); // Permissions are set BEFORE any plaintext is written.
                    byte[] bytes = Files.Utf8.GetBytes(text);
                    try { stream.Write(bytes, 0, bytes.Length); stream.Flush(true); }
                    finally { Array.Clear(bytes, 0, bytes.Length); }
                }
                SafePath(home, path);
                if (File.Exists(path)) File.Replace(temp, path, null); else File.Move(temp, path);
                Protect(path, false);
            } finally { if (File.Exists(temp)) File.Delete(temp); }
        }
        internal static Dictionary<string, string> Load(string home)
        {
            string path = VaultPath(home); SafePath(home, path);
            var result = new Dictionary<string, string>(StringComparer.Ordinal);
            if (!File.Exists(path)) return result;
            try {
                if (new FileInfo(path).Length > 16 * 1024 * 1024) throw new IOException();
                var root = Json.Read(path);
                string protection = Json.Str(root, "protection");
                if (Json.Int(root, "schema", 0) != 1 || protection != (Windows ? "dpapi-current-user" : "plaintext-linux")) throw new IOException();
                var values = Json.Get(root, "values") as Dictionary<string, object>;
                if (values == null) throw new IOException();
                foreach (var pair in values) {
                    ConfigBundle.ValidName(pair.Key);
                    string value = pair.Value as string; if (value == null) throw new IOException();
                    result[pair.Key] = Windows ? UnprotectValue(value) : value;
                }
            } catch { throw ConfigBundle.Bad("Не удалось открыть хранилище секретов текущего пользователя"); }
            return result;
        }
        internal static void Save(string home, Dictionary<string, string> values)
        {
            var data = new Dictionary<string, object>(StringComparer.Ordinal);
            foreach (var pair in values) {
                ConfigBundle.ValidName(pair.Key);
                if (pair.Value == null || pair.Value.Length > ConfigBundle.MaxLength) throw ConfigBundle.Bad("Недопустимое значение секрета");
                data[pair.Key] = Windows ? ProtectValue(pair.Value) : pair.Value;
            }
            WritePrivate(home, VaultPath(home), Json.Encode(ConfigBundle.D("schema", 1, "protection", Windows ? "dpapi-current-user" : "plaintext-linux", "values", data)) + "\n");
        }
        public static void Set(string home, string name, string value)
        {
            ConfigBundle.ValidName(name);
            if (value == null || value.Length > ConfigBundle.MaxLength) throw ConfigBundle.Bad("Недопустимое значение секрета");
            using (var lease = new Lease(home)) { var values = Load(home); values[name] = value; Save(home, values); }
        }
        public static bool Has(string home, string name)
        { ConfigBundle.ValidName(name); using (var lease = new Lease(home)) { var values = Load(home); return values.ContainsKey(name) && values[name].Length > 0; } }
        public static string[] Names(string home)
        { using (var lease = new Lease(home)) return Load(home).Keys.OrderBy(n => n, StringComparer.Ordinal).ToArray(); }
        internal static string Get(string home, string name)
        { ConfigBundle.ValidName(name); using (var lease = new Lease(home)) { string value; return Load(home).TryGetValue(name, out value) ? value : null; } }

        // DPAPI is in Windows itself; calling it directly avoids adding a runtime/package
        // dependency to the single net48 EXE. Flags=1 forbids UI; no machine scope flag.
        [StructLayout(LayoutKind.Sequential)] struct Blob { internal int Length; internal IntPtr Data; }
        [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool CryptProtectData(ref Blob input, string description, IntPtr entropy, IntPtr reserved, IntPtr prompt, int flags, out Blob output);
        [DllImport("crypt32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool CryptUnprotectData(ref Blob input, IntPtr description, IntPtr entropy, IntPtr reserved, IntPtr prompt, int flags, out Blob output);
        [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
        static byte[] Dpapi(byte[] input, bool protect)
        {
            var blob = new Blob { Length = input.Length, Data = Marshal.AllocHGlobal(Math.Max(1, input.Length)) };
            var output = new Blob();
            try {
                Marshal.Copy(input, 0, blob.Data, input.Length);
                bool ok = protect ? CryptProtectData(ref blob, null, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output) : CryptUnprotectData(ref blob, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output);
                if (!ok) throw new CryptographicException("DPAPI текущего пользователя недоступен");
                var result = new byte[output.Length]; Marshal.Copy(output.Data, result, 0, result.Length); return result;
            } finally {
                for (int i = 0; i < input.Length; i++) Marshal.WriteByte(blob.Data, i, 0);
                Marshal.FreeHGlobal(blob.Data);
                if (output.Data != IntPtr.Zero) { for (int i = 0; i < output.Length; i++) Marshal.WriteByte(output.Data, i, 0); LocalFree(output.Data); }
            }
        }
        static string ProtectValue(string value)
        {
            byte[] bytes = Files.Utf8.GetBytes(value);
            try { return Convert.ToBase64String(Dpapi(bytes, true)); } finally { Array.Clear(bytes, 0, bytes.Length); }
        }
        static string UnprotectValue(string value)
        {
            byte[] bytes = Dpapi(Convert.FromBase64String(value), false);
            try { return new UTF8Encoding(false, true).GetString(bytes); } finally { Array.Clear(bytes, 0, bytes.Length); }
        }
    }
}
