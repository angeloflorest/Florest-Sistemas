using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;
using FlorestPrintAgent.Core.Security;

namespace FlorestPrintAgent.Core.Printers
{
    /// <summary>
    /// Revalida impressoras vindas de FORA do processo (Tray via IPC): qualquer usuário local pode falar com o pipe,
    /// então nada é aceito "como veio". O identificador precisa ter o formato do esquema do agente (SHA-256 hex).
    /// </summary>
    public static class PrinterSanitizer
    {
        private static readonly Regex Hex64 = new Regex("^[0-9a-f]{64}$", RegexOptions.CultureInvariant | RegexOptions.Compiled);
        private static readonly Regex EnumFormat = new Regex("^[a-z][a-z0-9_]{0,29}$", RegexOptions.CultureInvariant | RegexOptions.Compiled);

        public static PrinterInfo? Sanitize(PrinterInfo? p)
        {
            if (p == null) return null;
            if (p.Identificador == null || !Hex64.IsMatch(p.Identificador)) return null;

            string name = PrinterClassifier.CleanText(p.Nome, AgentConstants.MaxPrinterNameLength);
            if (name.Length == 0) return null;

            PrinterInfo c = new PrinterInfo();
            c.Identificador = p.Identificador;
            c.Nome = name;
            c.Conexao = NormalizeEnum(p.Conexao, PrinterConnection.Outro);
            c.Status = NormalizeEnum(p.Status, PrinterStatus.Desconhecido);

            string normalizedIp;
            c.Ip = IpValidator.TryNormalize(p.Ip, out normalizedIp) ? normalizedIp : null;

            c.Porta = (p.Porta.HasValue && p.Porta.Value >= 1 && p.Porta.Value <= 65535) ? p.Porta : null;

            string portName = PrinterClassifier.CleanText(p.PortaWindows, AgentConstants.MaxPortNameLength);
            c.PortaWindows = portName.Length > 0 ? portName : null;
            return c;
        }

        /// <summary>Sanitiza a lista; descarta inválidos e duplicados (vale o primeiro) e limita ao máximo.</summary>
        public static List<PrinterInfo> SanitizeList(IEnumerable<PrinterInfo>? items, int max)
        {
            List<PrinterInfo> result = new List<PrinterInfo>();
            if (items == null) return result;
            HashSet<string> seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (PrinterInfo item in items)
            {
                PrinterInfo? clean = Sanitize(item);
                if (clean == null) continue;
                if (!seen.Add(clean.Identificador)) continue;
                result.Add(clean);
                if (result.Count >= max) break;
            }
            return result;
        }

        private static string NormalizeEnum(string? value, string fallback)
        {
            if (string.IsNullOrEmpty(value)) return fallback;
            string v = value.Trim().ToLowerInvariant();
            return EnumFormat.IsMatch(v) ? v : fallback;
        }
    }
}
