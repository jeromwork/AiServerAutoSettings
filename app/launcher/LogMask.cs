using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;

namespace RemoteAgents.Launcher
{
    // One masking rule set for every log line. The PowerShell (Protect-RaLogText) and Python (mask())
    // copies use the same patterns and the same fixture file (tests/fixtures/logging/mask-cases.json).
    internal static class LogMask
    {
        const string SecretNames = "token|password|passwd|passphrase|pass|secret|key|apikey|api_key|auth|authorization|cookie|uuid|private";
        static readonly Regex PrivateKey = new Regex(@"-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?(?:-----END [^-]*PRIVATE KEY-----|$)", RegexOptions.IgnoreCase);
        static readonly Regex PublicKey = new Regex(@"ssh-(ed25519|rsa) AAAA[A-Za-z0-9+/=]+");
        static readonly Regex Bearer = new Regex(@"Bearer\s+[A-Za-z0-9._~+/=-]+", RegexOptions.IgnoreCase);
        static readonly Regex Field = new Regex(@"(?<![A-Za-z0-9])([""']?)(" + SecretNames + @")\1(\s*[:=]\s*)(""[^""]*""|'[^']*'|[^\s,;&""']+)", RegexOptions.IgnoreCase);
        static readonly Regex Uuid = new Regex(@"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b");
        static readonly Regex Blob = new Regex(@"[A-Za-z0-9+/=_-]{41,}");
        static readonly Regex SecretKey = new Regex("^(?:" + SecretNames + ")$", RegexOptions.IgnoreCase);

        internal static bool IsSecretKey(string key) { return key != null && SecretKey.IsMatch(key); }

        internal static string Clean(string text) { return Clean(text, null); }

        internal static string Clean(string text, IEnumerable<string> knownSecrets)
        {
            if (string.IsNullOrEmpty(text)) return text ?? "";
            if (knownSecrets != null)
                foreach (string secret in knownSecrets.Where(s => !string.IsNullOrEmpty(s) && s.Length >= 4).Distinct(StringComparer.Ordinal).OrderByDescending(s => s.Length))
                    text = text.Replace(secret, "***");
            text = PrivateKey.Replace(text, "[private-key]");
            text = PublicKey.Replace(text, "ssh-$1 [pubkey]");
            text = Bearer.Replace(text, "Bearer ***");
            text = Field.Replace(text, "$1$2$1$3***");
            text = Uuid.Replace(text, m => "uuid:****" + m.Value.Substring(m.Value.Length - 4));
            text = Blob.Replace(text, BlobValue);
            return text;
        }

        static string BlobValue(Match match)
        {
            string token = match.Value;
            bool digit = token.Any(char.IsDigit), upper = token.Any(c => c >= 'A' && c <= 'Z'), lower = token.Any(c => c >= 'a' && c <= 'z');
            bool hex = Regex.IsMatch(token, "^[0-9a-fA-F]+$");
            bool blob = hex || (digit && upper && lower) || (digit && token.IndexOf('/') < 0 && (upper || lower));
            return blob ? "[blob:" + token.Length.ToString(System.Globalization.CultureInfo.InvariantCulture) + "]" : token;
        }
    }
}
