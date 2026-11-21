#if PORTABLE_TEST
using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text;

namespace RemoteAgents.Launcher
{
    internal static class HelperUpdateTests
    {
        static int checks;
        static readonly byte[] Exe = Encoding.UTF8.GetBytes("temporary test helper EXE");
        static readonly byte[] Singbox = Encoding.UTF8.GetBytes("temporary test sing-box");
        static void Check(bool ok, string name) { if (!ok) throw new Exception(name); checks++; }
        static void Reject(Action action, string name)
        {
            try { action(); } catch (InvalidDataException) { checks++; return; }
            throw new Exception("Accepted: " + name);
        }
        static string Hex(byte[] value) { return BitConverter.ToString(value).Replace("-", "").ToLowerInvariant(); }
        static string Public(ECDsa key) { var p = key.ExportParameters(false); return Hex(p.Q.X) + Hex(p.Q.Y); }
        static byte[] Manifest(string instance = "Main", string build = "42", string product = null)
        {
            return Encoding.UTF8.GetBytes("{\"product\":\"" + (product ?? (instance == "Main" ? "RemoteAgents" : "RemoteAgentsTest")) +
                "\",\"instance\":\"" + instance + "\",\"helperBuild\":" + build + ",\"exeSha256\":\"" + HelperUpdate.Hash(Exe) +
                "\",\"singboxSha256\":\"" + HelperUpdate.Hash(Singbox) + "\"}\n");
        }
        static byte[] Sign(ECDsa key, byte[] data)
        { return key.SignData(data, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation); }
        static HelperUpdateManifest Verify(ECDsa key, byte[] data, byte[] signature, byte[] exe = null, byte[] singbox = null,
            long installed = 41, string instance = "Main")
        { return HelperUpdate.VerifyForTests(data, signature, exe ?? Exe, singbox ?? Singbox, installed, instance, Public(key)); }

        static int Main(string[] args)
        {
            using (var main = ECDsa.Create(ECCurve.NamedCurves.nistP256))
            using (var test = ECDsa.Create(ECCurve.NamedCurves.nistP256)) {
                byte[] data = Manifest(), signature = Sign(main, data);
                Check(Verify(main, data, signature).HelperBuild == 42, "valid Main signature");
                for (int i = 0; i < data.Length; i++) {
                    byte[] changed = (byte[])data.Clone(); changed[i] ^= 1;
                    Reject(() => Verify(main, changed, signature), "manifest byte " + i);
                }
                for (int i = 0; i < Exe.Length; i++) {
                    byte[] changed = (byte[])Exe.Clone(); changed[i] ^= 1;
                    Reject(() => Verify(main, data, signature, changed), "EXE byte " + i);
                }
                for (int i = 0; i < Singbox.Length; i++) {
                    byte[] changed = (byte[])Singbox.Clone(); changed[i] ^= 1;
                    Reject(() => Verify(main, data, signature, singbox: changed), "sing-box byte " + i);
                }
                Reject(() => Verify(main, data, signature, installed: 42), "equal build");
                Reject(() => Verify(main, data, signature, installed: 43), "older build");
                Reject(() => Verify(main, data, signature, installed: -1), "invalid installed build");
                Reject(() => Verify(test, data, signature), "wrong public key");
                byte[] testData = Manifest("Test"), testSig = Sign(test, Manifest("Test"));
                Check(Verify(test, testData, testSig, instance: "Test").Instance == "Test", "valid Test signature");
                Reject(() => Verify(main, testData, testSig), "Test key cannot sign Main");
                Reject(() => Verify(main, testData, Sign(main, testData)), "foreign instance even with matching key");
                byte[] wrongProduct = Manifest("Main", product: "RemoteAgentsTest");
                Reject(() => Verify(main, wrongProduct, Sign(main, wrongProduct)), "foreign product");
                byte[] sigChanged = (byte[])signature.Clone(); sigChanged[0] ^= 1;
                Reject(() => Verify(main, data, sigChanged), "corrupt signature");
                Reject(() => Verify(main, data, new byte[63]), "short signature");
                Reject(() => HelperUpdate.Verify(data, signature, Exe, Singbox, 41), "unprovisioned/real anchor rejects fixture");
                foreach (string build in new[] { "0", "-1", "1.5", "1e2", "\"42\"", "9223372036854775808" }) {
                    byte[] bad = Manifest(build: build);
                    Reject(() => Verify(main, bad, Sign(main, bad)), "invalid build " + build);
                }
                foreach (string text in new[] {
                    Encoding.UTF8.GetString(data).Replace("\"instance\":\"Main\"", "\"instance\":\"Main\",\"instance\":\"Main\""),
                    Encoding.UTF8.GetString(data).Replace("\"helperBuild\"", "\"unknown\""),
                    Encoding.UTF8.GetString(data) + "{}", "\uFEFF" + Encoding.UTF8.GetString(data) }) {
                    byte[] bad = Encoding.UTF8.GetBytes(text);
                    Reject(() => Verify(main, bad, Sign(main, bad)), "invalid schema");
                }
                byte[] crlf = Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(data).Replace("\n", "\r\n"));
                Check(Verify(main, crlf, Sign(main, crlf)).HelperBuild == 42, "signed CRLF accepted as exact bytes");
                Reject(() => Verify(main, crlf, signature), "line-ending change invalidates signature");
                byte[] utf8 = (byte[])data.Clone(); utf8[0] = 0xff;
                Reject(() => Verify(main, utf8, Sign(main, utf8)), "invalid UTF-8");
                byte[] huge = new byte[HelperUpdate.MaxManifestBytes + 1];
                Reject(() => Verify(main, huge, Sign(main, huge)), "oversize manifest");
                SignerTests(main, test);
            }
            Console.WriteLine("PASS: HelperUpdate P1, " + checks + " checks; no waits, network, SCM or real keys");
            return 0;
        }

        static void WriteKey(string path, ECDsa key)
        {
            File.WriteAllText(path, "-----BEGIN PRIVATE KEY-----\n" + Convert.ToBase64String(key.ExportPkcs8PrivateKey(), Base64FormattingOptions.InsertLineBreaks) +
                "\n-----END PRIVATE KEY-----\n");
            File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        }
        static void Zip(string path, string name, byte[] data)
        {
            using (var zip = ZipFile.Open(path, ZipArchiveMode.Create)) {
                using (var stream = zip.CreateEntry(name).Open()) stream.Write(data, 0, data.Length);
                using (var stream = zip.CreateEntry("bundle-version.txt").Open()) {
                    byte[] version = Encoding.UTF8.GetBytes("20261121.123456-fixture\n"); stream.Write(version, 0, version.Length);
                }
            }
        }
        static int RunSigner(string script, string key, string instance, string archive, string exe, string initial)
        {
            var start = new ProcessStartInfo("bash") { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true };
            foreach (string arg in new[] { script, key, instance, "auto", archive, exe, initial }) start.ArgumentList.Add(arg);
            using (var process = Process.Start(start)) {
                string output = process.StandardOutput.ReadToEnd(), error = process.StandardError.ReadToEnd(); process.WaitForExit();
                if (process.ExitCode != 0) Console.WriteLine("Expected signer rejection: " + error.Trim());
                else Check(output.Length == 0 || output.Contains("helper-update: signed"), "signer output");
                return process.ExitCode;
            }
        }
        static void SignerTests(ECDsa main, ECDsa test, [CallerFilePath] string source = "")
        {
            string tests = Path.GetDirectoryName(source), root = Path.GetFullPath(Path.Combine(tests, "../../.."));
            string temp = Path.Combine(tests, ".helper-update-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(temp);
            try {
                Directory.CreateDirectory(Path.Combine(temp, "build")); Directory.CreateDirectory(Path.Combine(temp, "app/launcher"));
                string script = Path.Combine(temp, "build/sign-helper.sh"), anchorFile = Path.Combine(temp, "app/launcher/HelperUpdate.cs");
                File.Copy(Path.Combine(root, "build/sign-helper.sh"), script);
                string anchors = "const string MainPublicKeyHex = \"" + Public(main) + "\";\nconst string TestPublicKeyHex = \"" + Public(test) + "\";\n";
                File.WriteAllText(anchorFile, anchors);
                string key = Path.Combine(temp, "fixture.key"), otherKey = Path.Combine(temp, "other.key"), initial = Path.Combine(temp, "initial.zip");
                WriteKey(key, main); WriteKey(otherKey, test); Zip(initial, "transport/sing-box.exe", Singbox);
                foreach (string instance in new[] { "Main", "Test" }) {
                    string exeName = instance == "Main" ? "RemoteAgents.exe" : "RemoteAgentsTest.exe";
                    string exe = Path.Combine(temp, exeName), archive = Path.Combine(temp, instance + ".zip");
                    File.WriteAllBytes(exe, Exe); Zip(archive, exeName, Exe);
                    string signingKey = instance == "Main" ? key : otherKey;
                    Check(RunSigner(script, signingKey, instance, archive, exe, initial) == 0, "OpenSSL signer " + instance);
                    using (var zip = ZipFile.OpenRead(archive)) {
                        Func<string, byte[]> read = name => { using (var stream = zip.GetEntry(name).Open()) using (var memory = new MemoryStream()) { stream.CopyTo(memory); return memory.ToArray(); } };
                        Check(Verify(instance == "Main" ? main : test, read("helper-update.json"), read("helper-update.sig"), instance: instance).HelperBuild == 20261121123456,
                            "OpenSSL P1363 interoperates with verifier " + instance);
                        Check(Encoding.UTF8.GetString(read("bundle-files.txt")).Contains("helper-update.sig\n"), "ZIP extraction allowlist");
                    }
                    string before = HelperUpdate.Hash(File.ReadAllBytes(archive));
                    Check(RunSigner(script, signingKey, instance, archive, exe, initial) == 0 && HelperUpdate.Hash(File.ReadAllBytes(archive)) == before,
                        "prepared bundle remains byte-identical");
                    Check(RunSigner(script, instance == "Main" ? otherKey : key, instance, archive, exe, initial) != 0, "wrong signing key refused");
                    File.SetUnixFileMode(signingKey, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.GroupRead);
                    Check(RunSigner(script, signingKey, instance, archive, exe, initial) != 0, "unsafe key permissions refused");
                    File.SetUnixFileMode(signingKey, UnixFileMode.UserRead | UnixFileMode.UserWrite);
                    File.WriteAllText(anchorFile, anchors.Replace(Public(test), Public(main)));
                    Check(RunSigner(script, key, "Main", archive, exe, initial) != 0, "identical instance anchors refused");
                    File.WriteAllText(anchorFile, anchors.Replace(Public(main), ""));
                    Check(RunSigner(script, key, "Main", archive, exe, initial) != 0, "empty anchor refused");
                    File.WriteAllText(anchorFile, anchors);
                    Check(HelperUpdate.Hash(File.ReadAllBytes(archive)) == before, "rejections preserve bundle");
                }
            } finally { Directory.Delete(temp, true); }
        }
    }
}
#endif
