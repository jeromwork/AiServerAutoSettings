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
                if (new FileInfo(path).Length > ConfigBundle.MaxLength) throw new IOException();
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
            if (values.Count > 256 || values.Values.Sum(v => (long)(v == null ? 0 : Files.Utf8.GetByteCount(v))) > ConfigBundle.MaxLength) throw ConfigBundle.Bad("Хранилище секретов превышает лимит");
            var data = new Dictionary<string, object>(StringComparer.Ordinal);
            foreach (var pair in values) {
                ConfigBundle.ValidName(pair.Key);
                if (pair.Value == null || pair.Value.Length > ConfigBundle.MaxLength || Files.Utf8.GetByteCount(pair.Value) > ConfigBundle.MaxLength) throw ConfigBundle.Bad("Недопустимое значение секрета");
                data[pair.Key] = Windows ? ProtectValue(pair.Value) : pair.Value;
            }
            string encoded = Json.Encode(ConfigBundle.D("schema", 1, "protection", Windows ? "dpapi-current-user" : "plaintext-linux", "values", data)) + "\n";
            if (Files.Utf8.GetByteCount(encoded) > ConfigBundle.MaxLength) throw ConfigBundle.Bad("Хранилище секретов превышает 4 МиБ");
            WritePrivate(home, VaultPath(home), encoded);
        }
        public static void Set(string home, string name, string value)
        {
            ConfigBundle.ValidName(name);
            if (value == null || value.Length > ConfigBundle.MaxLength || Files.Utf8.GetByteCount(value) > ConfigBundle.MaxLength) throw ConfigBundle.Bad("Недопустимое значение секрета");
            using (var lease = new Lease(home)) { var values = Load(home); values[name] = value; Save(home, values); }
        }
        public static bool Has(string home, string name)
        { ConfigBundle.ValidName(name); using (var lease = new Lease(home)) { var values = Load(home); return values.ContainsKey(name) && values[name].Length > 0; } }
        public static string[] Names(string home)
        { using (var lease = new Lease(home)) return Load(home).Keys.OrderBy(n => n, StringComparer.Ordinal).ToArray(); }
        internal static string Get(string home, string name)
        { ConfigBundle.ValidName(name); using (var lease = new Lease(home)) { string value; return Load(home).TryGetValue(name, out value) ? value : null; } }

        static string Resolve(Dictionary<string, string> values, object reference)
        {
            string name = Json.Str(Json.Map(reference), "secret"), value;
            return name.Length > 0 && values.TryGetValue(name, out value) && value.Length > 0 ? value : null;
        }
        static string SecretJson(string text)
        {
            try {
                if (text.Length > ConfigBundle.MaxLength || !(ConfigBundle.StrictParse(text) is Dictionary<string, object>)) throw new FormatException();
                return Json.Encode(ConfigBundle.StrictParse(text)) + "\n";
            } catch { throw ConfigBundle.Bad("Секрет канала или узла должен содержать JSON-объект"); }
        }
        static string FileId(string name)
        {
            // No user-controlled name becomes a Windows filename (CON, trailing dots, etc.).
            using (var sha = SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(Files.Utf8.GetBytes(name))).Replace("-", "").ToLowerInvariant().Substring(0, 24);
        }
        internal static string MaterializedPath(string home) { return Path.Combine(Path.GetFullPath(home), "secrets", "materialized.json"); }
        public static void Materialize(string home)
        {
            using (var lease = new Lease(home)) {
                var settings = ConfigBundle.ReadSettings(home);
                var profile = ConfigBundle.CurrentProfile(home, settings); var values = Load(home);
                // An empty reference produces no file and no manifest path, so nothing stale is ever used in its place.
                // It is listed as «missing»: the section that needs it fails with a clear reason, the others still work
                // (the server needs its key OR root's password; a new Happier account creates its key itself).
                var missing = ConfigBundle.References(profile).Where(r => Resolve(values, r) == null).Select(r => Json.Str(r, "secret")).Distinct().OrderBy(n => n, StringComparer.Ordinal).ToArray();
                var files = new Dictionary<string, string>(Windows ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal);
                var manifest = ConfigBundle.D("schema", 1);
                if (missing.Length > 0) manifest["missing"] = missing;
                string secretDir = Path.Combine(Path.GetFullPath(home), "secrets");
                Action<string, string> add = (path, content) => {
                    SafePath(home, path);
                    if (string.Equals(path,VaultPath(home),Windows ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal) || string.Equals(path,MaterializedPath(home),Windows ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal)) throw ConfigBundle.Bad("Нельзя перезаписать служебный файл секретом");
                    string previous; if (files.TryGetValue(path, out previous) && previous != content) throw ConfigBundle.Bad("Два секрета направлены в один файл");
                    files[path] = content;
                };
                var server = Json.Map(Json.Get(profile, "server"));
                string key = Resolve(values, Json.Get(server, "key"));
                if (key != null) {
                    string path = Path.Combine(secretDir, "server-key");
                    string sshPath = Json.Str(Json.Map(Json.Get(settings, "transport")), "profilePath");
                    if (sshPath.Length > 0 && File.Exists(sshPath)) {
                        SafePath(home, sshPath); var ssh = Json.Read(sshPath);
                        if (Json.Str(server, "address") == Json.Str(ssh, "serverAddress") && Json.Str(server, "login") == Json.Str(ssh, "login") && Json.Int(server, "port", 22) == ConfigBundle.RuntimePort(ssh)) {
                            string configured = Json.Str(ssh, "keyPath");
                            if (configured.Length > 0) {
                                configured = Path.GetFullPath(configured); SafePath(home,configured);
                                string relative = configured.Substring(Path.GetFullPath(home).TrimEnd(Path.DirectorySeparatorChar,Path.AltDirectorySeparatorChar).Length).TrimStart(Path.DirectorySeparatorChar,Path.AltDirectorySeparatorChar).Replace('\\','/');
                                if (!(relative.StartsWith("secrets/",StringComparison.OrdinalIgnoreCase) || relative.StartsWith("ssh-profiles/",StringComparison.OrdinalIgnoreCase)) || new[]{".json",".ps1",".exe",".dll",".conf",".known_hosts"}.Contains(Path.GetExtension(configured).ToLowerInvariant())) throw ConfigBundle.Bad("Недопустимый путь SSH-ключа");
                                if (!File.Exists(configured) || Files.LF(File.ReadAllText(configured)) == Files.LF(key)) path = configured;
                                else if (string.Equals(path,configured,Windows ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal)) path = Path.Combine(secretDir,"server-key-pending");
                            }
                        }
                    }
                    add(path, Files.LF(key)); manifest["serverKeyFile"] = path;
                }
                string password = Resolve(values, Json.Get(server, "rootPassword"));
                if (password != null) { string path = Path.Combine(secretDir, "server-root-password"); add(path, password); manifest["serverPasswordFile"] = path; }
                string happier = Resolve(values, Json.Get(Json.Map(Json.Get(profile, "happier")), "key"));
                // Keep the active account key intact until Wizard.Account has tested the pending key.
                if (happier != null) { string path = Path.Combine(secretDir, "happier-pending.key"); add(path, happier); manifest["happierKeyFile"] = path; }
                var proxy = Json.Map(Json.Get(profile, "proxyOut"));
                if (profile.ContainsKey("proxyOut")) {
                    string value = Resolve(values, Json.Get(proxy, "password"));
                    string path = Path.Combine(secretDir, "proxy-out.json");
                    if (!proxy.ContainsKey("password") || value != null) { add(path, Json.Encode(ConfigBundle.D("username", Json.Str(proxy, "login"), "password", value ?? "")) + "\n"); manifest["proxyOutFile"] = path; }
                }
                var routes = new List<object>(); int routeIndex = 0;
                foreach (var route in Json.Array(Json.Get(server, "routes")).Select(Json.Map)) {
                    string id = "route-" + routeIndex++; var material = ConfigBundle.D("kind", Json.Str(route,"kind"));
                    var hop = Json.Map(Json.Get(route, "hop"));
                    if (hop.Count > 0) {
                        var row = HopFiles(home, id, hop, values, add);
                        material["hop"] = row;
                    }
                    var px = Json.Map(Json.Get(route, "proxy"));
                    if (px.Count > 0) {
                        var row = ConfigBundle.D("type", Json.Str(px,"type"), "host", Json.Str(px,"server"), "port", Json.Int(px,"port",1080));
                        string value = Resolve(values, Json.Get(px,"password"));
                        if (value != null || px.ContainsKey("login")) {
                            string path = Path.Combine(secretDir, id + "-proxy.json");
                            add(path, Json.Encode(ConfigBundle.D("username",Json.Str(px,"login"),"password",value ?? "")) + "\n"); row["credentialsFile"] = path;
                        }
                        material["proxy"] = row;
                    }
                    routes.Add(material);
                }
                if (routes.Count > 0) manifest["routes"] = routes;
                var bootstrap = Json.Map(Json.Get(Json.Map(Json.Get(profile, "vpn")), "bootstrap"));
                string channel = Resolve(values, Json.Get(bootstrap, "channel"));
                if (channel != null) { string path = Path.Combine(secretDir, "channel.json"); add(path, SecretJson(channel)); manifest["channelPath"] = path; }
                var entries = new Dictionary<string, object>();
                foreach (var entry in Json.Map(Json.Get(bootstrap, "entries"))) {
                    // The existing transport reader uses this exact basename, so reject names
                    // it cannot safely read on Windows instead of silently renaming entries.
                    if (!System.Text.RegularExpressions.Regex.IsMatch(entry.Key, "^[a-zA-Z0-9][a-zA-Z0-9_-]{0,47}$")) throw ConfigBundle.Bad("Имя VPN-узла: латинские буквы, цифры, _ и -, до 48 знаков");
                    if (System.Text.RegularExpressions.Regex.IsMatch(entry.Key, "^(?i:con|prn|aux|nul|com[0-9]|lpt[0-9])$")) throw ConfigBundle.Bad("Зарезервированное имя VPN-узла");
                    string value = Resolve(values, entry.Value); if (value == null) continue;
                    string path = Path.Combine(secretDir, "entries", entry.Key + ".json"); add(path, SecretJson(value)); entries[entry.Key] = path;
                }
                if (entries.Count > 0) manifest["entries"] = entries;
                var hops = new Dictionary<string, object>();
                foreach (var hop in Json.Map(Json.Get(bootstrap, "hops"))) hops[hop.Key] = HopFiles(home, "vpn-hop-" + FileId(hop.Key), Json.Map(hop.Value), values, add);
                if (hops.Count > 0) manifest["hops"] = hops;
                var lans = new List<object>();
                foreach (var lan in Json.Array(Json.Get(profile, "lan")).Select(Json.Map)) {
                    string name = Json.Str(lan,"name"), id = FileId(name);
                    var row = ConfigBundle.D("name", name);
                    string ovpn = Resolve(values, Json.Get(lan,"ovpn"));
                    if (ovpn != null) { string path = Path.Combine(secretDir, "lan", id + ".ovpn"); add(path, Files.LF(ovpn)); row["file"] = path; }
                    string auth = Resolve(values, Json.Get(lan,"password"));
                    if (auth != null) { string path = Path.Combine(secretDir,"lan",id + "-auth.json"); add(path, Json.Encode(ConfigBundle.D("username",Json.Str(lan,"login"),"password",auth)) + "\n"); row["authFile"] = path; }
                    lans.Add(row);
                }
                if (lans.Count > 0) manifest["lan"] = lans;
                // Validate the entire plan before writing the first derived file. Manifest
                // is private too, but contains only paths and public settings, never values.
                foreach (string path in files.Keys) SafePath(home,path);
                foreach (var file in files) WritePrivate(home, file.Key, file.Value);
                manifest["files"] = files.Keys.OrderBy(p => p, StringComparer.Ordinal).ToArray();
                WritePrivate(home, MaterializedPath(home), Json.Encode(manifest) + "\n");
            }
        }
        static Dictionary<string, object> HopFiles(string home, string id, Dictionary<string, object> hop, Dictionary<string, string> values, Action<string, string> add)
        {
            string directory = Path.Combine(Path.GetFullPath(home), "secrets");
            string key = Resolve(values, Json.Get(hop,"key")), password = Resolve(values,Json.Get(hop,"password"));
            string host = Json.Str(hop,"host"), user = Json.Str(hop,"user"); int port = Json.Int(hop,"port",22);
            var row = ConfigBundle.D("name", id, "ssh", user + "@" + host + (port == 22 ? "" : ":" + port));
            if (key != null) { string path = Path.Combine(directory,id); add(path,Files.LF(key)); row["keyFile"] = path; }
            string hostKey = Json.Str(hop,"hostKey");
            if (hostKey.Length > 0) {
                string known = Path.Combine(directory,id + ".known_hosts");
                add(known, (port == 22 ? host : "[" + host + "]:" + port) + " " + hostKey + "\n"); row["knownHostsPath"] = known;
            }
            if (password != null) {
                string path = Path.Combine(directory,id + "-auth.json");
                add(path,Json.Encode(ConfigBundle.D("host",host,"port",port,"user",user,"password",password)) + "\n"); row["passwordFile"] = path;
            }
            return row;
        }

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
