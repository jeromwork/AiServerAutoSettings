using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace RemoteAgents.Launcher
{
    internal static class NetHelperVersionTests
    {
        // Service implementation, wire protocol and shared dependencies. New LAN/VPN/helper
        // source files are included automatically. Launcher setup/UI code is not installed code.
        static string[] Sources(string root)
        {
            string launcher = Path.Combine(root, "app", "launcher");
            var service = new[] { "NetHelper*.cs", "Lan*.cs", "Vpn*.cs" }
                .SelectMany(pattern => Directory.GetFiles(launcher, pattern))
                .Where(path => Path.GetFileName(path) != "NetHelperSetup.cs")
                .Select(path => "app/launcher/" + Path.GetFileName(path));
            return service.Concat(new[] {
                "app/launcher/Data.cs", "app/launcher/EntryPoint.cs",
                "app/launcher/HelperBusBridge.cs", "app/launcher/EventBus.cs", "app/launcher/BusTopics.cs", "app/launcher/NativeJob.cs",
                "app/launcher/PinnedTransport.cs", "app/launcher/Program.cs", "app/launcher/StatusView.cs",
                "app/launcher/TickFailureLog.cs", "app/launcher/TrayMenuModel.cs", "app/launcher/RaLog.cs", "app/launcher/LogMask.cs",
                "app/launcher/RemoteAgents.Launcher.csproj", "build/bundle-binaries.json",
                "transport/product-features.json"
            }).Distinct().OrderBy(path => path, StringComparer.Ordinal).ToArray();
        }

        // Hash names as well as contents, so additions, removals and renames also invalidate the pin.
        // Ignore checkout line endings, UTF-8 BOMs and launcher version values; preserve all other source text.
        static string Fingerprint(IEnumerable<string> sources, Func<string, string> read)
        {
            var text = new StringBuilder();
            foreach (string source in sources) {
                string content = Files.LF(read(source).TrimStart('\uFEFF'));
                if (source == "app/launcher/RemoteAgents.Launcher.csproj")
                    content = Regex.Replace(content, @"(<(Version|AssemblyVersion|FileVersion)>)[^<]*(</\2>)", "$1$3");
                text.Append(source).Append('\n').Append(content).Append('\0');
            }
            using (var sha = SHA256.Create())
                return BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(text.ToString()))).Replace("-", "").ToLowerInvariant();
        }

        static void RequireMatch(string version, string fingerprint, string pinnedVersion, string pinnedFingerprint)
        {
            if (version != pinnedVersion || fingerprint != pinnedFingerprint)
                throw new InvalidDataException("Net helper sources/version changed. Bump NetHelperInstall.HelperVersion when service/protocol changes, " +
                    "then update app/launcher/NetHelperSources.json. Current version=" + version + ", SHA-256=" + fingerprint);
        }

        static void MustReject(Action check, string scenario)
        {
            try { check(); }
            catch (InvalidDataException) { return; }
            throw new Exception("NetHelperVersion guard accepted " + scenario);
        }

        internal static void Run([CallerFilePath] string caller = "")
        {
            string root = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(caller), "../../.."));
            var pin = Json.Read(Path.Combine(root, "app", "launcher", "NetHelperSources.json"));
            string[] sources = Sources(root);
            string actual = Fingerprint(sources, path => File.ReadAllText(Path.Combine(root, path)));
            RequireMatch(NetHelperInstall.HelperVersion, actual, Json.Str(pin, "helperVersion"), Json.Str(pin, "sha256"));

            // Regression checks run in memory; the real source tree is never modified.
            var fixture = new Dictionary<string, string> { { "NetHelper.cs", "service\n" }, { "NetHelperProtocol.cs", "protocol\n" } };
            string[] names = fixture.Keys.OrderBy(path => path, StringComparer.Ordinal).ToArray();
            string original = Fingerprint(names, path => fixture[path]);
            RequireMatch("6", original, "6", original);
            foreach (string name in names) {
                string before = fixture[name]; fixture[name] += "changed\n";
                MustReject(() => RequireMatch("6", Fingerprint(names, path => fixture[path]), "6", original), "changed " + name + " without a version bump");
                fixture[name] = before;
            }
            MustReject(() => RequireMatch("7", original, "6", original), "a version bump without an updated pin");
            MustReject(() => RequireMatch("6", Fingerprint(names.Take(1), path => fixture[path]), "6", original), "a removed source");
            if (original != Fingerprint(names, path => "\uFEFF" + fixture[path].Replace("\n", "\r\n")))
                throw new Exception("NetHelperVersion fingerprint depends on checkout line endings/BOM");
            Console.WriteLine("PASS: NetHelperVersion source/version pin (" + sources.Length + " files), service/protocol mutation regressions");
        }
    }
}
