using System;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;

namespace RemoteAgents.Launcher
{
    // The core's SSH client: openssh/* of this EXE's embedded initial bundle, pinned in build/bundle-binaries.json, written once to
    // <Home>\transport-bin\openssh. OTA bundles never carry it, but every EXE does, so updated PCs get the same version too.
    internal static class PortableTools
    {
        internal static string EnsureOpenSsh(string home)
        {
            using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("RemoteAgents.InitialBundle.zip")) {
                if (stream == null) return "no-bundle";
                using (var zip = new ZipArchive(stream, ZipArchiveMode.Read)) {
                    var pins = zip.GetEntry("build/bundle-binaries.json"); if (pins == null) return "no-pins";
                    string text; using (var reader = new StreamReader(pins.Open())) text = reader.ReadToEnd();
                    var rows = Json.Array(Json.Get(Json.Map(Json.Parse(text)), "binaries")).Select(Json.Map)
                        .Where(r => Json.Str(r, "target").StartsWith("openssh/", StringComparison.Ordinal))
                        .OrderBy(r => Json.Str(r, "target") == "openssh/ssh.exe").ToList();
                    if (rows.Count == 0) return "no-openssh";
                    var data = rows.Select(r => { var e = zip.GetEntry(Json.Str(r, "target")); if (e == null) return null; using (var s = e.Open()) using (var m = new MemoryStream()) { s.CopyTo(m); return m.ToArray(); } }).ToList();
                    for (int i = 0; i < rows.Count; i++) if (data[i] == null || Sha256(data[i]) != Json.Str(rows[i], "memberSha256").ToLowerInvariant()) return "mismatch";
                    string dir = Path.Combine(home, "transport-bin", "openssh"); Directory.CreateDirectory(dir);
                    for (int i = 0; i < rows.Count; i++) {
                        string target = Path.Combine(dir, Path.GetFileName(Json.Str(rows[i], "target")));
                        if (File.Exists(target) && Sha256(File.ReadAllBytes(target)) == Sha256(data[i])) continue;
                        string temp = target + "." + Guid.NewGuid().ToString("N") + ".tmp";
                        File.WriteAllBytes(temp, data[i]);
                        try { if (File.Exists(target)) File.Delete(target); File.Move(temp, target); }
                        catch (IOException) { File.Delete(temp); return "busy"; }   // a running ssh.exe keeps the old copy until the next start
                        catch (UnauthorizedAccessException) { File.Delete(temp); return "busy"; }
                    }
                    return "ok";
                }
            }
        }
        static string Sha256(byte[] data) { using (var h = SHA256.Create()) return BitConverter.ToString(h.ComputeHash(data)).Replace("-", "").ToLowerInvariant(); }
    }
}
