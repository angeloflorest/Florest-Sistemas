using System;
using System.Collections.Generic;
using System.Linq;

namespace FlorestPrintAgent.Core.Printers
{
    /// <summary>
    /// União das impressoras vistas pelo Service (conjunto A) e pelas sessões de usuário via Tray (conjuntos B):
    /// deduplica pelo identificador determinístico. Impressora que o Service enxerga: a versão do Service SEMPRE vale.
    /// Impressoras só de sessões de usuário: havendo duas versões, vale a mais completa.
    /// Saída ordenada e limitada ao máximo aceito pelo servidor.
    /// </summary>
    public static class PrinterMerger
    {
        public static List<PrinterInfo> Merge(
            IEnumerable<PrinterInfo> servicePrinters,
            IEnumerable<IEnumerable<PrinterInfo>> userPrinterLists,
            int max,
            out bool truncated)
        {
            Dictionary<string, PrinterInfo> byId = new Dictionary<string, PrinterInfo>(StringComparer.Ordinal);

            foreach (PrinterInfo p in servicePrinters)
            {
                if (string.IsNullOrEmpty(p.Identificador)) continue;
                PrinterInfo existing;
                if (!byId.TryGetValue(p.Identificador, out existing) || Completeness(p) > Completeness(existing))
                {
                    byId[p.Identificador] = p;
                }
            }

            // Identificadores vistos pelo Service (fonte confiável: roda como LocalSystem). Um usuário comum NUNCA sobrescreve
            // uma impressora que o Service enxerga (o identificador é determinístico e público: sem esta regra, um usuário
            // poderia calcular o id de uma impressora real e enviar outro IP/porta para ela).
            HashSet<string> trusted = new HashSet<string>(byId.Keys, StringComparer.Ordinal);

            foreach (IEnumerable<PrinterInfo> list in userPrinterLists)
            {
                foreach (PrinterInfo p in list)
                {
                    if (string.IsNullOrEmpty(p.Identificador)) continue;
                    if (trusted.Contains(p.Identificador)) continue;
                    PrinterInfo existing;
                    if (!byId.TryGetValue(p.Identificador, out existing))
                    {
                        byId[p.Identificador] = p;
                    }
                    else if (Completeness(p) > Completeness(existing))
                    {
                        byId[p.Identificador] = p; // duas sessões de usuário: vale a mais completa
                    }
                }
            }

            List<PrinterInfo> ordered = byId.Values
                .OrderBy(p => p.Nome, StringComparer.OrdinalIgnoreCase)
                .ThenBy(p => p.Identificador, StringComparer.Ordinal)
                .ToList();

            truncated = ordered.Count > max;
            if (truncated) ordered = ordered.Take(max).ToList();
            return ordered;
        }

        public static int Completeness(PrinterInfo p)
        {
            int score = 0;
            if (!string.IsNullOrEmpty(p.Ip)) score += 2;
            if (p.Porta.HasValue) score += 1;
            if (!string.IsNullOrEmpty(p.PortaWindows)) score += 1;
            if (!string.Equals(p.Status, PrinterStatus.Desconhecido, StringComparison.Ordinal)) score += 1;
            if (!string.Equals(p.Conexao, PrinterConnection.Outro, StringComparison.Ordinal)) score += 1;
            return score;
        }
    }
}
