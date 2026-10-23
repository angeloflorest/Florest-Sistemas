using FlorestPrintAgent.Core.Jobs;

namespace FlorestPrintAgent.Core.Printers
{
    /// <summary>
    /// Interpretação dos bits de status do spooler (JOB_INFO_1.Status e PRINTER_INFO_6.dwStatus). Código puro, testado em unidade;
    /// o acesso ao Windows fica em WinSpoolRawWriter.
    /// </summary>
    public static class SpoolerFlags
    {
        public const uint JOB_STATUS_PAUSED = 0x00000001;
        public const uint JOB_STATUS_ERROR = 0x00000002;
        public const uint JOB_STATUS_DELETING = 0x00000004;
        public const uint JOB_STATUS_SPOOLING = 0x00000008;
        public const uint JOB_STATUS_PRINTING = 0x00000010;
        public const uint JOB_STATUS_OFFLINE = 0x00000020;
        public const uint JOB_STATUS_PAPEROUT = 0x00000040;
        public const uint JOB_STATUS_PRINTED = 0x00000080;
        public const uint JOB_STATUS_DELETED = 0x00000100;
        public const uint JOB_STATUS_BLOCKED_DEVQ = 0x00000200;
        public const uint JOB_STATUS_USER_INTERVENTION = 0x00000400;
        public const uint JOB_STATUS_COMPLETE = 0x00001000;

        public const uint PRINTER_STATUS_PAUSED = 0x00000001;
        public const uint PRINTER_STATUS_ERROR = 0x00000002;
        public const uint PRINTER_STATUS_PAPER_JAM = 0x00000008;
        public const uint PRINTER_STATUS_PAPER_OUT = 0x00000010;
        public const uint PRINTER_STATUS_OFFLINE = 0x00000080;
        public const uint PRINTER_STATUS_NOT_AVAILABLE = 0x00001000;
        public const uint PRINTER_STATUS_USER_INTERVENTION = 0x00100000;
        public const uint PRINTER_STATUS_DOOR_OPEN = 0x00400000;

        /// <summary>O documento já saiu da fila com sucesso (impresso/concluído).</summary>
        public static bool JobFinished(uint jobStatus)
        {
            return (jobStatus & (JOB_STATUS_PRINTED | JOB_STATUS_COMPLETE)) != 0;
        }

        /// <summary>O documento foi removido da fila SEM ter sido impresso (alguém apagou).</summary>
        public static bool JobRemovedWithoutPrinting(uint jobStatus)
        {
            return (jobStatus & (JOB_STATUS_DELETED | JOB_STATUS_DELETING)) != 0 && !JobFinished(jobStatus);
        }

        /// <summary>Bits do job que indicam que o papel NÃO está saindo (offline, erro, sem papel, intervenção, pausado).</summary>
        public static bool JobProblem(uint jobStatus, out string code, out string message)
        {
            code = string.Empty;
            message = string.Empty;
            if (JobFinished(jobStatus)) return false;

            if ((jobStatus & JOB_STATUS_PAPEROUT) != 0)
            {
                code = PrintErrorCodes.PrinterError;
                message = "A impressora está sem papel.";
                return true;
            }
            if ((jobStatus & JOB_STATUS_OFFLINE) != 0)
            {
                code = PrintErrorCodes.PrinterOffline;
                message = "A impressora está offline (desligada ou desconectada).";
                return true;
            }
            if ((jobStatus & (JOB_STATUS_ERROR | JOB_STATUS_USER_INTERVENTION | JOB_STATUS_BLOCKED_DEVQ)) != 0)
            {
                code = PrintErrorCodes.PrinterError;
                message = "A impressora informou erro ao imprimir.";
                return true;
            }
            if ((jobStatus & JOB_STATUS_PAUSED) != 0)
            {
                code = PrintErrorCodes.PrinterError;
                message = "A impressão está pausada na fila do Windows.";
                return true;
            }
            return false;
        }

        /// <summary>Bits da IMPRESSORA que indicam que ela não está imprimindo agora.</summary>
        public static bool PrinterProblem(uint printerStatus, out string code, out string message)
        {
            code = string.Empty;
            message = string.Empty;
            if ((printerStatus & PRINTER_STATUS_PAPER_OUT) != 0)
            {
                code = PrintErrorCodes.PrinterError;
                message = "A impressora está sem papel.";
                return true;
            }
            if ((printerStatus & (PRINTER_STATUS_OFFLINE | PRINTER_STATUS_NOT_AVAILABLE)) != 0)
            {
                code = PrintErrorCodes.PrinterOffline;
                message = "A impressora está offline (desligada ou desconectada).";
                return true;
            }
            if ((printerStatus & (PRINTER_STATUS_ERROR | PRINTER_STATUS_PAPER_JAM | PRINTER_STATUS_USER_INTERVENTION | PRINTER_STATUS_DOOR_OPEN)) != 0)
            {
                code = PrintErrorCodes.PrinterError;
                message = "A impressora informou erro (tampa aberta, papel atolado ou intervenção necessária).";
                return true;
            }
            return false;
        }

        /// <summary>Erro do Windows ao abrir a fila -> código para o servidor.</summary>
        public static string CodeForOpenError(int win32Error)
        {
            switch (win32Error)
            {
                case 2:      // ERROR_FILE_NOT_FOUND
                case 3:      // ERROR_PATH_NOT_FOUND
                case 1801:   // ERROR_INVALID_PRINTER_NAME
                case 1722:   // RPC_S_SERVER_UNAVAILABLE (impressora compartilhada de outro PC fora do ar)
                case 53:     // ERROR_BAD_NETPATH
                    return PrintErrorCodes.PrinterNotFound;
                case 5:      // ERROR_ACCESS_DENIED
                    return PrintErrorCodes.AccessDenied;
                default:
                    return PrintErrorCodes.SpoolerError;
            }
        }
    }
}
