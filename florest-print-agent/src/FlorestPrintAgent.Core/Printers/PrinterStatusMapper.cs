using System;

namespace FlorestPrintAgent.Core.Printers
{
    /// <summary>
    /// Converte os flags REAIS do spooler (PRINTER_INFO_2.Status / Attributes) nos valores de status do banco:
    /// disponivel | offline | erro | desconhecido. "disponivel" significa apenas "o spooler não reporta nenhum problema":
    /// para impressoras de rede o spooler nem sempre sabe se o aparelho está ligado (limitação documentada).
    /// </summary>
    public static class PrinterStatusMapper
    {
        // PRINTER_ATTRIBUTE_*
        public const uint AttrNetwork = 0x00000010;
        public const uint AttrWorkOffline = 0x00000400;

        // PRINTER_STATUS_*
        private const uint Paused = 0x00000001;
        private const uint Error = 0x00000002;
        private const uint PendingDeletion = 0x00000004;
        private const uint PaperJam = 0x00000008;
        private const uint PaperOut = 0x00000010;
        private const uint PaperProblem = 0x00000040;
        private const uint Offline = 0x00000080;
        private const uint OutputBinFull = 0x00000800;
        private const uint NotAvailable = 0x00001000;
        private const uint NoToner = 0x00040000;
        private const uint PagePunt = 0x00080000;
        private const uint UserIntervention = 0x00100000;
        private const uint OutOfMemory = 0x00200000;
        private const uint DoorOpen = 0x00400000;
        private const uint ServerUnknown = 0x00800000;
        private const uint ServerOffline = 0x02000000;
        private const uint DriverUpdateNeeded = 0x04000000;

        private const uint OfflineMask = Offline | NotAvailable | ServerOffline | ServerUnknown;
        private const uint ErrorMask = Paused | Error | PendingDeletion | PaperJam | PaperOut | PaperProblem |
                                       OutputBinFull | NoToner | PagePunt | UserIntervention | OutOfMemory |
                                       DoorOpen | DriverUpdateNeeded;

        public static string Map(RawPrinter p)
        {
            if (!p.StatusKnown) return PrinterStatus.Desconhecido;
            if ((p.Attributes & AttrWorkOffline) != 0) return PrinterStatus.Offline;
            if ((p.Status & OfflineMask) != 0) return PrinterStatus.Offline;
            if ((p.Status & ErrorMask) != 0) return PrinterStatus.Erro;
            return PrinterStatus.Disponivel;
        }
    }
}
