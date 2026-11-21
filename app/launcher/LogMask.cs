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
        const string SecretNames = "token|password|passwd|passphrase|pass|secret|key|apikey|api_key|auth|authorization|cookie|uuid|private|psk";
        static readonly Regex PrivateKey = new Regex(@"-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?(?:-----END [^-]*PRIVATE KEY-----|$)", RegexOptions.IgnoreCase);
        static readonly Regex PublicKey = new Regex(@"ssh-(ed25519|rsa) AAAA[A-Za-z0-9+/=]+");
        static readonly Regex UserInfo = new Regex(@"://[^/\s@]+@");
        static readonly Regex Basic = new Regex(@"(Authorization[:=]\s*)Basic\s+\S+", RegexOptions.IgnoreCase);
        static readonly Regex Bearer = new Regex(@"Bearer\s+[A-Za-z0-9._~+/=-]+", RegexOptions.IgnoreCase);
        // Любое «имя: значение»; решает IsSecretName (camelCase: accessToken, secretKey, privateKey; psk).
        static readonly Regex Field = new Regex(@"(?<![A-Za-z0-9_.-])([""']?)([A-Za-z0-9_.-]{1,256})\1(\s*[:=]\s*)(""[^""]*""|'[^']*'|[^\s,;&""']+)");
        static readonly Regex Uuid = new Regex(@"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b");
        static readonly Regex Blob = new Regex(@"[A-Za-z0-9+/=_-]{41,}");
        static readonly Regex SubstringNames = new Regex("token|password|passwd|passphrase|secret|authorization|cookie|uuid", RegexOptions.IgnoreCase);
        static readonly Regex WordNames = new Regex(@"(?:^|[_.-])(?:key|pass|auth|psk|apikey)(?:$|[_.-])", RegexOptions.IgnoreCase);

        internal static bool IsSecretName(string name)
        {
            if (string.IsNullOrEmpty(name) || Regex.IsMatch(name, @"^\w*(?:Error|Exception)$")) return false; // KeyError: имя исключения, не ключ
            if (SubstringNames.IsMatch(name)) return true;
            return WordNames.IsMatch(Regex.Replace(name, "([a-z0-9])([A-Z])", "$1_$2"));
        }
        internal static bool IsSecretKey(string key) { return IsSecretName(key); }

        internal static string Clean(string text) { return Clean(text, null); }

        internal static string Clean(string text, IEnumerable<string> knownSecrets)
        {
            if (string.IsNullOrEmpty(text)) return text ?? "";
            if (knownSecrets != null)
                foreach (string secret in knownSecrets.Where(s => !string.IsNullOrEmpty(s) && s.Length >= 4).Distinct(StringComparer.Ordinal).OrderByDescending(s => s.Length))
                    text = text.Replace(secret, "***");
            text = PrivateKey.Replace(text, "[private-key]");
            text = PublicKey.Replace(text, "ssh-$1 [pubkey]");
            text = UserInfo.Replace(text, "://***@");
            text = Basic.Replace(text, "$1Basic ***");
            text = Bearer.Replace(text, "Bearer ***");
            text = Field.Replace(text, m => IsSecretName(m.Groups[2].Value) ? m.Groups[1].Value + m.Groups[2].Value + m.Groups[1].Value + m.Groups[3].Value + "***" : m.Value);
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
