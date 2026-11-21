using System;
using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace RemoteAgents.Launcher
{
    internal sealed class HelperUpdateManifest
    {
        internal readonly string Product, Instance, ExeSha256, SingboxSha256;
        internal readonly long HelperBuild;
        internal HelperUpdateManifest(string product, string instance, long build, string exe, string singbox)
        { Product = product; Instance = instance; HelperBuild = build; ExeSha256 = exe; SingboxSha256 = singbox; }
    }

    internal static class HelperUpdate
    {
        // Public P-256 coordinates X || Y, 32 bytes each, lowercase hex (not a private key).
        // The lead fills these after the owner's key-generation decision. Empty means deny all.
        internal const string MainPublicKeyHex = "";
        internal const string TestPublicKeyHex = "";
        internal const int MaxManifestBytes = 4096;
        static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, true);
        // A deliberately small, fixed-order JSON schema, identical on Framework and portable .NET.
        // No duplicate/unknown keys, escapes, numeric coercion, BOM, or trailing JSON are accepted.
        static readonly Regex Manifest = new Regex(@"\A[ \t\r\n]*\{[ \t\r\n]*""product""[ \t\r\n]*:[ \t\r\n]*""(RemoteAgents|RemoteAgentsTest)""[ \t\r\n]*,[ \t\r\n]*""instance""[ \t\r\n]*:[ \t\r\n]*""(Main|Test)""[ \t\r\n]*,[ \t\r\n]*""helperBuild""[ \t\r\n]*:[ \t\r\n]*([1-9][0-9]{0,18})[ \t\r\n]*,[ \t\r\n]*""exeSha256""[ \t\r\n]*:[ \t\r\n]*""([0-9a-f]{64})""[ \t\r\n]*,[ \t\r\n]*""singboxSha256""[ \t\r\n]*:[ \t\r\n]*""([0-9a-f]{64})""[ \t\r\n]*\}[ \t\r\n]*\z", RegexOptions.CultureInvariant);

        internal static HelperUpdateManifest Verify(byte[] manifest, byte[] signature, byte[] exe, byte[] singbox, long installedBuild)
        {
            if (!string.IsNullOrEmpty(MainPublicKeyHex) && string.Equals(MainPublicKeyHex, TestPublicKeyHex, StringComparison.Ordinal))
                throw new InvalidDataException("helper-update: Main and Test trust anchors must differ");
            // Selection belongs to the installed image, never to the incoming manifest/config.
            string instance = Product.Name == "RemoteAgents" ? "Main" : Product.Name == "RemoteAgentsTest" ? "Test" : "";
            string key = instance == "Main" ? MainPublicKeyHex : instance == "Test" ? TestPublicKeyHex : "";
            return VerifyCore(manifest, signature, exe, singbox, installedBuild, instance, key);
        }

        static HelperUpdateManifest VerifyCore(byte[] manifest, byte[] signature, byte[] exe, byte[] singbox,
            long installedBuild, string instance, string publicKeyHex)
        {
            if (manifest == null || manifest.Length == 0 || manifest.Length > MaxManifestBytes ||
                signature == null || signature.Length != 64 || exe == null || singbox == null || installedBuild < 0)
                throw new InvalidDataException("helper-update: invalid input");
            byte[] key = PublicKey(publicKeyHex);
            if (!SignatureValid(manifest, signature, key)) throw new InvalidDataException("helper-update: invalid signature");
            string text;
            try { text = Utf8.GetString(manifest); }
            catch (DecoderFallbackException) { throw new InvalidDataException("helper-update: invalid UTF-8"); }
            var match = Manifest.Match(text);
            long build;
            if (!match.Success || !long.TryParse(match.Groups[3].Value, NumberStyles.None, CultureInfo.InvariantCulture, out build))
                throw new InvalidDataException("helper-update: invalid manifest");
            string product = instance == "Main" ? "RemoteAgents" : instance == "Test" ? "RemoteAgentsTest" : "";
            if (product.Length == 0 || match.Groups[1].Value != product || match.Groups[2].Value != instance)
                throw new InvalidDataException("helper-update: wrong product/instance");
            if (build <= installedBuild) throw new InvalidDataException("helper-update: build is not newer");
            if (Hash(exe) != match.Groups[4].Value || Hash(singbox) != match.Groups[5].Value)
                throw new InvalidDataException("helper-update: payload SHA-256 mismatch");
            // The caller must write the same byte arrays it supplied, without reopening user paths (P2).
            return new HelperUpdateManifest(product, instance, build, match.Groups[4].Value, match.Groups[5].Value);
        }

        static byte[] PublicKey(string hex)
        {
            if (hex == null || !Regex.IsMatch(hex, @"\A[0-9a-f]{128}\z"))
                throw new InvalidDataException("helper-update: public key is not provisioned");
            byte[] key = new byte[64];
            for (int i = 0; i < key.Length; i++) key[i] = byte.Parse(hex.Substring(i * 2, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture);
            return key;
        }

        static bool SignatureValid(byte[] data, byte[] signature, byte[] key)
        {
            using (var sha = SHA256.Create()) {
                byte[] hash = sha.ComputeHash(data);
                try {
#if PORTABLE_TEST
                    byte[] x = new byte[32], y = new byte[32];
                    Buffer.BlockCopy(key, 0, x, 0, 32); Buffer.BlockCopy(key, 32, y, 0, 32);
                    using (var ecdsa = ECDsa.Create()) {
                        ecdsa.ImportParameters(new ECParameters { Curve = ECCurve.NamedCurves.nistP256, Q = new ECPoint { X = x, Y = y } });
                        return ecdsa.VerifyHash(hash, signature, DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
                    }
#else
                    // BCRYPT_ECCPUBLIC_BLOB: ECDSA P-256 magic, cbKey=32 (little endian), X, Y.
                    byte[] blob = new byte[72];
                    Buffer.BlockCopy(new byte[] { 0x45, 0x43, 0x53, 0x31, 32, 0, 0, 0 }, 0, blob, 0, 8);
                    Buffer.BlockCopy(key, 0, blob, 8, 64);
                    using (var cng = CngKey.Import(blob, CngKeyBlobFormat.EccPublicBlob))
                    using (var ecdsa = new ECDsaCng(cng)) return ecdsa.VerifyHash(hash, signature);
#endif
                } catch (CryptographicException) { return false; }
            }
        }

        internal static string Hash(byte[] data)
        { using (var sha = SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(data)).Replace("-", "").ToLowerInvariant(); }

#if PORTABLE_TEST
        // Compiled out of the service: production callers cannot supply their own trust anchor.
        internal static HelperUpdateManifest VerifyForTests(byte[] manifest, byte[] signature, byte[] exe, byte[] singbox,
            long installedBuild, string instance, string key)
        { return VerifyCore(manifest, signature, exe, singbox, installedBuild, instance, key); }
#endif
    }
}
