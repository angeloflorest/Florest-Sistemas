using System;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace FlorestPrintAgent.Core.Printers
{
    /// <summary>
    /// Identificador ESTÁVEL de impressora dentro da estação: SHA-256 (hex minúsculo, 64 caracteres) de dados
    /// normalizados do Windows: nome da fila + porta Windows + (quando compartilhada) servidor e compartilhamento.
    /// Não usa índice nem posição. A mesma configuração gera sempre o mesmo identificador.
    /// Exceção deliberada: portas USB (USB001, USB002...) entram como "usb" na identidade, pois o NÚMERO muda quando o
    /// cabo é ligado em outra entrada; o nome da fila continua distinguindo as impressoras. (A porta real continua
    /// sendo enviada em porta_windows.)
    /// </summary>
    public static class PrinterIdentifier
    {
        private static readonly Regex Spaces = new Regex("\\s+", RegexOptions.CultureInvariant | RegexOptions.Compiled);
        private static readonly Regex UsbPort = new Regex("^(usb|dot4_)\\d+$", RegexOptions.CultureInvariant | RegexOptions.IgnoreCase | RegexOptions.Compiled);

        public static string Normalize(string? text)
        {
            if (string.IsNullOrEmpty(text)) return string.Empty;
            string s = text;
            try
            {
                s = s.Normalize(NormalizationForm.FormC);
            }
            catch (ArgumentException)
            {
                // texto com surrogate inválido: usa como está
            }
            s = Spaces.Replace(s.Trim(), " ");
            return s.ToLowerInvariant();
        }

        public static string NormalizePort(string? port)
        {
            string p = Normalize(port);
            if (UsbPort.IsMatch(p)) return "usb";
            return p;
        }

        public static string Compute(string? queueName, string? windowsPort, string? server, string? share)
        {
            StringBuilder sb = new StringBuilder();
            sb.Append("fpa-printer-v1").Append('\n');
            sb.Append(Normalize(queueName)).Append('\n');
            sb.Append(NormalizePort(windowsPort)).Append('\n');
            sb.Append(Normalize(server)).Append('\n');
            sb.Append(Normalize(share));
            byte[] hash = SHA256.HashData(Encoding.UTF8.GetBytes(sb.ToString()));
            return Convert.ToHexString(hash).ToLowerInvariant();
        }
    }
}
