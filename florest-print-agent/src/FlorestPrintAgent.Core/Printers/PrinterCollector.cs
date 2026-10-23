using System;
using System.Collections.Generic;

namespace FlorestPrintAgent.Core.Printers
{
    /// <summary>Monta a lista final de PrinterInfo a partir de filas, portas e leitor de portas TCP/IP (tudo injetável).</summary>
    public static class PrinterCollector
    {
        public static List<PrinterInfo> Build(
            IEnumerable<RawPrinter> rawPrinters,
            IEnumerable<PortDetails> ports,
            ITcpIpPortReader tcpReader)
        {
            Dictionary<string, PortDetails> portByName = new Dictionary<string, PortDetails>(StringComparer.OrdinalIgnoreCase);
            foreach (PortDetails pd in ports)
            {
                if (!string.IsNullOrEmpty(pd.PortName) && !portByName.ContainsKey(pd.PortName)) portByName[pd.PortName] = pd;
            }

            List<PrinterInfo> result = new List<PrinterInfo>();
            Dictionary<string, int> indexById = new Dictionary<string, int>(StringComparer.Ordinal);

            foreach (RawPrinter raw in rawPrinters)
            {
                PortDetails? details = null;
                TcpIpPortInfo? tcp = null;
                string portName = (raw.PortName ?? string.Empty).Trim();
                if (portName.Length > 0)
                {
                    PortDetails found;
                    if (portByName.TryGetValue(portName, out found)) details = found;

                    bool maybeTcp = details == null ||
                                    string.Equals(details.MonitorName, "Standard TCP/IP Port", StringComparison.OrdinalIgnoreCase);
                    if (maybeTcp) tcp = tcpReader.TryRead(portName);
                }

                PrinterInfo? info = PrinterClassifier.Classify(raw, details, tcp);
                if (info == null) continue;

                int existingIndex;
                if (indexById.TryGetValue(info.Identificador, out existingIndex))
                {
                    if (PrinterMerger.Completeness(info) > PrinterMerger.Completeness(result[existingIndex])) result[existingIndex] = info;
                    continue;
                }
                indexById[info.Identificador] = result.Count;
                result.Add(info);
            }
            return result;
        }
    }
}
