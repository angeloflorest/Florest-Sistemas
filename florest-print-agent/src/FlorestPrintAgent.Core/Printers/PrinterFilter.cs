using System;
using System.Text.RegularExpressions;

namespace FlorestPrintAgent.Core.Printers
{
    /// <summary>
    /// Filtro CONSERVADOR de impressoras virtuais (PDF, XPS, OneNote, Fax, etc.). Só exclui quando há
    /// evidência clara (porta/driver/nome conhecidos). Uma impressora de nome ou fabricante desconhecido é MANTIDA.
    /// </summary>
    public static class PrinterFilter
    {
        private static readonly string[] VirtualPorts =
        {
            "portprompt:", "nul:", "file:", "xpsport:", "shrfax:",
        };

        private static readonly string[] VirtualDriverFragments =
        {
            "microsoft print to pdf",
            "microsoft xps document writer",
            "microsoft shared fax driver",
            "microsoft software printer writer",
            "remote desktop easy print",
            "onenote",
            "adobe pdf",
            "foxit",
            "cutepdf",
            "pdfcreator",
            "dopdf",
            "bullzip",
            "pdf24",
            "nitro pdf",
            "primopdf",
            "snagit",
            "webex document loader",
        };

        private static readonly string[] VirtualNameFragments =
        {
            "microsoft print to pdf",
            "microsoft xps document writer",
            "onenote",
            "adobe pdf",
            "cutepdf",
            "pdfcreator",
            "dopdf",
            "bullzip",
            "pdf24",
            "nitro pdf",
            "primopdf",
            "snagit",
            "webex document loader",
            "send to onenote",
            "enviar para o onenote",
            "imprimir em pdf",
            "salvar como pdf",
        };

        // palavras inteiras: "pdf", "xps" e "fax" (evita casar com nomes de fabricantes que apenas contenham as letras)
        private static readonly Regex WholeWordVirtual = new Regex(
            "(^|[^a-z0-9])(pdf|xps|fax)([^a-z0-9]|$)",
            RegexOptions.CultureInvariant | RegexOptions.IgnoreCase | RegexOptions.Compiled);

        private static readonly Regex RemoteDesktopPort = new Regex("^TS\\d{3}$", RegexOptions.CultureInvariant | RegexOptions.IgnoreCase | RegexOptions.Compiled);

        private static readonly Regex HardwarePort = new Regex(
            "^(usb\\d*|ip_.+|wsd-.+|lpt\\d*:?|com\\d+:?|\\d{1,3}(\\.\\d{1,3}){3}(:\\d+)?|\\\\\\\\.+)$",
            RegexOptions.CultureInvariant | RegexOptions.IgnoreCase | RegexOptions.Compiled);

        private static bool IsHardwarePort(string port)
        {
            return port.Length > 0 && HardwarePort.IsMatch(port);
        }

        public static bool IsVirtual(RawPrinter p)
        {
            string name = (p.Name ?? string.Empty).Trim();
            string port = (p.PortName ?? string.Empty).Trim();
            string driver = (p.DriverName ?? string.Empty).Trim();

            string portLower = port.ToLowerInvariant();
            foreach (string v in VirtualPorts)
            {
                if (portLower == v) return true;
            }
            if (portLower.StartsWith("microsoft.office.onenote", StringComparison.Ordinal)) return true;
            if (RemoteDesktopPort.IsMatch(port)) return true; // fila redirecionada do Remote Desktop (não é deste computador)

            string driverLower = driver.ToLowerInvariant();
            foreach (string v in VirtualDriverFragments)
            {
                if (driverLower.Contains(v)) return true;
            }

            string nameLower = name.ToLowerInvariant();
            foreach (string v in VirtualNameFragments)
            {
                if (nameLower.Contains(v)) return true;
            }

            if (WholeWordVirtual.IsMatch(name)) return true;
            // A palavra pdf/xps/fax só no DRIVER não basta se a porta é de hardware real (USB, TCP/IP, WSD, serial/paralela):
            // há equipamentos reais com driver "... PDF" ou "... XPS".
            if (driverLower.Length > 0 && !IsHardwarePort(port) && WholeWordVirtual.IsMatch(driver)) return true;

            return false;
        }
    }
}
