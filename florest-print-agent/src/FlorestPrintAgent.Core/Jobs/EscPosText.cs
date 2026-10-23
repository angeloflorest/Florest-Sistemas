using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace FlorestPrintAgent.Core.Jobs
{
    /// <summary>Texto -> bytes da página de código da impressora. Caractere que a página não tem vira a letra sem acento (ou '?').</summary>
    public static class EscPosText
    {
        static EscPosText()
        {
            try
            {
                Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
            }
            catch (Exception)
            {
                // se não registrar, o ramo de segurança abaixo (ASCII) continua funcionando
            }
        }

        public static byte[] Encode(string text, int codePage)
        {
            Encoding? enc = null;
            try
            {
                enc = Encoding.GetEncoding(codePage, EncoderFallback.ExceptionFallback, DecoderFallback.ExceptionFallback);
            }
            catch (Exception)
            {
                enc = null;
            }

            List<byte> result = new List<byte>(text.Length + 8);
            foreach (Rune rune in text.EnumerateRunes())
            {
                string s = rune.ToString();
                if (rune.Value < 0x80)
                {
                    result.Add((byte)rune.Value);
                    continue;
                }

                if (enc != null)
                {
                    try
                    {
                        result.AddRange(enc.GetBytes(s));
                        continue;
                    }
                    catch (EncoderFallbackException)
                    {
                        // cai para a letra sem acento
                    }
                }

                // travessão e meia-risca não existem nas páginas de código da impressora: viram hífen (em vez de '?')
                string plain = (rune.Value == 0x2014 || rune.Value == 0x2013) ? "-" : StripDiacritics(s);
                foreach (char ch in plain)
                {
                    result.Add(ch < 0x80 ? (byte)ch : (byte)'?');
                }
            }
            return result.ToArray();
        }

        /// <summary>"Ç" -> "C", "ã" -> "a"; o que não decompõe vira "?".</summary>
        public static string StripDiacritics(string s)
        {
            string decomposed;
            try
            {
                decomposed = s.Normalize(NormalizationForm.FormD);
            }
            catch (ArgumentException)
            {
                return "?";
            }
            StringBuilder sb = new StringBuilder(decomposed.Length);
            foreach (char ch in decomposed)
            {
                UnicodeCategory cat = CharUnicodeInfo.GetUnicodeCategory(ch);
                if (cat == UnicodeCategory.NonSpacingMark) continue;
                sb.Append(ch < 0x80 ? ch : '?');
            }
            return sb.Length == 0 ? "?" : sb.ToString();
        }
    }
}
