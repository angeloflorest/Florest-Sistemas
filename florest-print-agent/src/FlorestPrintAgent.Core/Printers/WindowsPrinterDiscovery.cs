using System;
using System.Collections.Generic;
using System.Runtime.Versioning;

namespace FlorestPrintAgent.Core.Printers
{
    /// <summary>
    /// Descoberta de impressoras REAIS instaladas no Windows (EnumPrinters / EnumPorts + leitura do registro).
    /// Enxerga as filas do contexto em que roda: o Service (SYSTEM) vê as filas locais; o Tray (usuário) vê também as
    /// conexões do usuário (compartilhadas de outros PCs). O Service faz o merge das duas visões.
    /// </summary>
    [SupportedOSPlatform("windows")]
    public sealed class WindowsPrinterDiscovery : IPrinterDiscovery
    {
        private readonly ITcpIpPortReader _tcpReader;

        public WindowsPrinterDiscovery()
            : this(new RegistryTcpIpPortReader())
        {
        }

        public WindowsPrinterDiscovery(ITcpIpPortReader tcpReader)
        {
            _tcpReader = tcpReader;
        }

        public DiscoveryResult Discover()
        {
            try
            {
                List<RawPrinter> raws;
                string? error;
                if (!WinSpool.TryEnumPrinters(out raws, out error))
                {
                    return DiscoveryResult.Fail(error ?? "Falha ao enumerar impressoras.");
                }

                List<PortDetails> ports = WinSpool.EnumPortsSafe();
                List<PrinterInfo> printers = PrinterCollector.Build(raws, ports, _tcpReader);
                return DiscoveryResult.Ok(printers);
            }
            catch (Exception ex)
            {
                return DiscoveryResult.Fail("Falha ao enumerar impressoras (" + ex.GetType().Name + ").");
            }
        }
    }
}
