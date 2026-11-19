using System;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;

namespace RemoteAgents.Launcher
{
    internal static class PinnedTransport
    {
        internal const string Target = "transport/sing-box.exe";
        internal static string ExpectedHash
        {
            get {
                // The trust anchor belongs to the EXE, never to a writable bundle/transport-bin.
                using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("RemoteAgents.BundleBinaries.json")) {
                    if (stream == null) throw new InvalidDataException("В программе нет пина SHA-256 сетевого помощника; обновите RemoteAgents.exe");
                    using (var reader = new StreamReader(stream)) {
                        var rows = Json.Array(Json.Get(Json.Map(Json.Parse(reader.ReadToEnd())), "binaries")).Select(Json.Map).Where(r => Json.Str(r, "target") == Target).ToArray();
                        if (rows.Length != 1) throw new InvalidDataException("Неверный пин сетевого помощника");
                        string hash = Json.Str(rows[0], "memberSha256"); Files.HashValid(hash); return hash.ToLowerInvariant();
                    }
                }
            }
        }
        internal static string Hash(byte[] data)
        { using (var hash = SHA256.Create()) return BitConverter.ToString(hash.ComputeHash(data)).Replace("-", "").ToLowerInvariant(); }
        internal static byte[] Verify(byte[] data, string expected)
        {
            if (!string.Equals(Hash(data), expected, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("SHA-256 sing-box.exe не совпадает с пином программы. Обновите RemoteAgents.exe; помощник не установлен");
            return data;
        }
        internal static byte[] ReadVerified(string home, string bundle, string expected)
        {
            var candidates = new[] { Path.Combine(home, "transport-bin", "sing-box.exe"), Path.Combine(bundle, "transport", "sing-box.exe") };
            string root = Path.Combine(home, Product.BundleDirectory);
            if (Directory.Exists(root)) candidates = candidates.Concat(Directory.GetDirectories(root).OrderByDescending(p => Path.GetFileName(p), StringComparer.Ordinal).Select(p => Path.Combine(p, "transport", "sing-box.exe"))).Distinct().ToArray();
            bool mismatch = false;
            foreach (string path in candidates) {
                if (!File.Exists(path)) continue;
                try {
                    // Retain the very bytes hashed: reopening a user-owned path when elevated is a TOCTOU bug.
                    using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read)) {
                        if (stream.Length > 256L * 1024 * 1024) { mismatch = true; continue; }
                        using (var memory = new MemoryStream()) { stream.CopyTo(memory); return Verify(memory.ToArray(), expected); }
                    }
                } catch (InvalidDataException) { mismatch = true; }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
            if (mismatch) throw new InvalidDataException("Не найден sing-box.exe с верным SHA-256. Обновите RemoteAgents.exe; файлы помощника не изменены");
            throw new FileNotFoundException("Нет проверенного sing-box.exe в transport-bin и бандлах. Запустите полную обновлённую сборку RemoteAgents.exe");
        }
        internal static string Ensure(string home, string bundle)
        {
            using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("RemoteAgents.InitialBundle.zip"))
                return Restore(home, bundle, ExpectedHash, stream);
        }
        internal static string Restore(string home, string bundle, string expected, Stream embedded)
        {
            string target = Path.Combine(home, "transport-bin", "sing-box.exe");
            if (File.Exists(target) && Hash(File.ReadAllBytes(target)) == expected) return "ok";
            byte[] data = null;
            // Every full EXE retains its initial bundle, including after OTA activation.
            if (embedded != null) {
                using (var zip = new ZipArchive(embedded, ZipArchiveMode.Read, true)) {
                    var entry = zip.GetEntry(Target);
                    if (entry != null) using (var source = entry.Open()) using (var memory = new MemoryStream()) { source.CopyTo(memory); data = Verify(memory.ToArray(), expected); }
                }
            }
            if (data == null) data = ReadVerified(home, bundle, expected);
            Directory.CreateDirectory(Path.GetDirectoryName(target));
            string temp = target + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try {
                File.WriteAllBytes(temp, data);
                if (File.Exists(target)) File.Delete(target);
                File.Move(temp, target);
            } finally { if (File.Exists(temp)) File.Delete(temp); }
            return "restored";
        }
    }
}
