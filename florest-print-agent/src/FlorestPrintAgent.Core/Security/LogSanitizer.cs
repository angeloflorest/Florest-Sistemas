using System;
using System.Text.RegularExpressions;

namespace FlorestPrintAgent.Core.Security
{
    /// <summary>
    /// Última linha de defesa dos logs: mascara qualquer coisa que pareça token, Authorization, hash,
    /// JWT ou código de pareamento. O código do agente NÃO deve registrar esses valores; isto é a rede de proteção.
    /// </summary>
    public static class LogSanitizer
    {
        private static readonly Regex Token = new Regex("fpa_[0-9A-Fa-f-]{36}\\.[A-Za-z0-9_-]{10,}", RegexOptions.CultureInvariant | RegexOptions.Compiled);
        private static readonly Regex Bearer = new Regex("(?i)bearer\\s+[A-Za-z0-9._~+/=-]+", RegexOptions.CultureInvariant | RegexOptions.Compiled);
        private static readonly Regex AuthHeader = new Regex("(?i)authorization\\s*[:=]\\s*\\S+", RegexOptions.CultureInvariant | RegexOptions.Compiled);
        private static readonly Regex Jwt = new Regex("eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{4,}", RegexOptions.CultureInvariant | RegexOptions.Compiled);
        // segredo "solto" do token: 43 caracteres base64url (32 bytes)
        private static readonly Regex BareSecret = new Regex("(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{43}(?![A-Za-z0-9_-])", RegexOptions.CultureInvariant | RegexOptions.Compiled);
        private static readonly Regex Hex64 = new Regex("\\b[0-9a-fA-F]{64}\\b", RegexOptions.CultureInvariant | RegexOptions.Compiled);
        private static readonly Regex PairingCode = new Regex("\\b[A-HJ-NP-Za-hj-np-z2-9]{4}-[A-HJ-NP-Za-hj-np-z2-9]{4}\\b", RegexOptions.CultureInvariant | RegexOptions.Compiled);

        public static string Scrub(string? text)
        {
            if (string.IsNullOrEmpty(text)) return string.Empty;
            string s = text;
            s = Token.Replace(s, "fpa_[REDACTED]");
            s = Bearer.Replace(s, "Bearer [REDACTED]");
            s = AuthHeader.Replace(s, "authorization:[REDACTED]");
            s = Jwt.Replace(s, "[REDACTED-JWT]");
            s = Hex64.Replace(s, "[REDACTED-HASH]");
            s = BareSecret.Replace(s, "[REDACTED-SECRET]");
            s = PairingCode.Replace(s, "[REDACTED-CODE]");
            return s;
        }
    }
}
