using System;
using System.Text;

namespace FlorestPrintAgent.Core.Security
{
    /// <summary>
    /// Código de pareamento: 8 caracteres do alfabeto ABCDEFGHJKLMNPQRSTUVWXYZ23456789 (sem 0, 1, I, O),
    /// exibido como XXXX-XXXX. O servidor é a autoridade; aqui só normalizamos para evitar chamadas inúteis.
    /// O código NUNCA é gravado em disco nem em log.
    /// </summary>
    public static class PairingCode
    {
        private const string Alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

        public static bool TryNormalize(string? input, out string normalized)
        {
            normalized = string.Empty;
            if (string.IsNullOrWhiteSpace(input) || input.Length > 32) return false;

            StringBuilder sb = new StringBuilder(8);
            foreach (char ch in input)
            {
                if (ch == ' ' || ch == '-' || ch == '\t') continue;
                char up = char.ToUpperInvariant(ch);
                if (Alphabet.IndexOf(up) < 0) return false;
                sb.Append(up);
                if (sb.Length > 8) return false;
            }
            if (sb.Length != 8) return false;

            string raw = sb.ToString();
            normalized = raw.Substring(0, 4) + "-" + raw.Substring(4, 4);
            return true;
        }
    }
}
