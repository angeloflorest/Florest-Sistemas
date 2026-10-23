using System;
using System.Text;
using System.Text.RegularExpressions;
using FlorestPrintAgent.Core.Security;

namespace FlorestPrintAgent.Core.Printers
{
    /// <summary>
    /// Transforma dados brutos do spooler em PrinterInfo (contrato do servidor) ou null quando a fila é virtual.
    /// Regras de conexão:
    ///   compartilhada  conexão a impressora de outro computador (atributo NETWORK ou nome \\servidor\fila)
    ///   usb            porta USBnnn / DOT4_nnn ou monitor "USB Monitor"
    ///   rede           Standard TCP/IP Port, LPR Port ou WSD (IP/porta só se o Windows os informar)
    ///   outro          porta COM/LPT, porta ilegível/ausente
    ///   windows        qualquer outra fila local
    /// Nunca infere IP pelo nome da impressora ou da porta e nunca assume a porta 9100.
    /// </summary>
    public static class PrinterClassifier
    {
        private static readonly Regex UsbPort = new Regex("^(usb|dot4_)\\d+$", RegexOptions.CultureInvariant | RegexOptions.IgnoreCase | RegexOptions.Compiled);
        private static readonly Regex SerialOrParallel = new Regex("^(com|lpt)\\d+:?$", RegexOptions.CultureInvariant | RegexOptions.IgnoreCase | RegexOptions.Compiled);

        public static PrinterInfo? Classify(RawPrinter raw, PortDetails? port, TcpIpPortInfo? tcp)
        {
            string name = CleanText(raw.Name, AgentConstants.MaxPrinterNameLength);
            if (name.Length == 0) return null;
            if (PrinterFilter.IsVirtual(raw)) return null;

            string portName = CleanText(raw.PortName, AgentConstants.MaxPortNameLength);
            string monitor = CleanText(port != null ? port.MonitorName : null, 100);
            string connection = ClassifyConnection(raw, name, portName, monitor, tcp);

            string? ip = null;
            int? tcpPort = null;
            if (connection == PrinterConnection.Rede && tcp != null)
            {
                string normalizedIp;
                if (IpValidator.TryNormalize(tcp.IpAddress, out normalizedIp))
                {
                    ip = normalizedIp;
                }
                else if (IpValidator.TryNormalize(tcp.HostName, out normalizedIp))
                {
                    ip = normalizedIp; // o HostName já é um IP literal
                }
                // HostName que não é literal de IP: NÃO é IP, fica null (sem DNS e sem suposição)

                // só reporta porta quando o Windows configurou RAW e informou o número
                if (tcp.Protocol.HasValue && tcp.Protocol.Value == 1 &&
                    tcp.PortNumber.HasValue && tcp.PortNumber.Value >= 1 && tcp.PortNumber.Value <= 65535)
                {
                    tcpPort = tcp.PortNumber.Value;
                }
            }

            bool shared = connection == PrinterConnection.Compartilhada;

            PrinterInfo info = new PrinterInfo();
            info.Identificador = PrinterIdentifier.Compute(
                raw.Name,
                raw.PortName,
                shared ? raw.ServerName : null,
                shared ? raw.ShareName : null);
            info.Nome = name;
            info.Conexao = connection;
            info.Ip = ip;
            info.Porta = tcpPort;
            info.PortaWindows = portName.Length > 0 ? portName : null;
            info.Status = PrinterStatusMapper.Map(raw);
            return info;
        }

        private static string ClassifyConnection(RawPrinter raw, string name, string portName, string monitor, TcpIpPortInfo? tcp)
        {
            if ((raw.Attributes & PrinterStatusMapper.AttrNetwork) != 0 || name.StartsWith("\\\\", StringComparison.Ordinal))
                return PrinterConnection.Compartilhada;

            if (portName.Length == 0) return PrinterConnection.Outro;

            if (UsbPort.IsMatch(portName) || monitor.Equals("USB Monitor", StringComparison.OrdinalIgnoreCase))
                return PrinterConnection.Usb;

            if (tcp != null ||
                monitor.Equals("Standard TCP/IP Port", StringComparison.OrdinalIgnoreCase) ||
                monitor.Equals("LPR Port", StringComparison.OrdinalIgnoreCase) ||
                monitor.StartsWith("WSD", StringComparison.OrdinalIgnoreCase) ||
                portName.StartsWith("WSD-", StringComparison.OrdinalIgnoreCase))
                return PrinterConnection.Rede;

            if (portName.StartsWith("\\\\", StringComparison.Ordinal)) return PrinterConnection.Compartilhada;

            if (SerialOrParallel.IsMatch(portName)) return PrinterConnection.Outro;

            return PrinterConnection.Windows;
        }

        /// <summary>Remove caracteres de controle, apara e limita o tamanho.</summary>
        public static string CleanText(string? text, int maxLength)
        {
            if (string.IsNullOrEmpty(text)) return string.Empty;
            StringBuilder sb = new StringBuilder(Math.Min(text.Length, maxLength));
            foreach (char ch in text)
            {
                if (char.IsControl(ch)) continue;
                sb.Append(ch);
                if (sb.Length >= maxLength) break;
            }
            return sb.ToString().Trim();
        }
    }
}
