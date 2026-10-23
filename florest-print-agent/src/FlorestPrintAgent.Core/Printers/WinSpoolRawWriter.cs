using System;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Threading;
using FlorestPrintAgent.Core.Jobs;

namespace FlorestPrintAgent.Core.Printers
{
    /// <summary>
    /// Envia bytes RAW (ESC/POS) a uma fila do Windows pelo spooler (OpenPrinter / StartDocPrinter "RAW" / WritePrinter).
    /// Impressão silenciosa: sem diálogo, sem driver gráfico, sem navegador. USB, TCP/IP e compartilhada funcionam porque o
    /// Windows cuida da porta. A impressora padrão do Windows NUNCA é usada: a fila é sempre indicada pelo nome.
    ///
    /// "Sucesso" = o spooler aceitou o documento E, observando o job, a fila não indicou erro/offline/sem papel. Se a impressora
    /// estiver com problema, o job é REMOVIDO da fila do Windows (para não sair duplicado quando a impressora voltar) e a
    /// falha é devolvida para que o servidor reagende.
    /// </summary>
    [SupportedOSPlatform("windows")]
    public sealed class WinSpoolRawWriter : IRawPrinterWriter
    {
        private const uint JOB_CONTROL_DELETE = 5;
        private const int ERROR_INVALID_DATATYPE = 1804;
        private static readonly TimeSpan PollInterval = TimeSpan.FromMilliseconds(250);
        private static readonly TimeSpan ProblemPersistsFor = TimeSpan.FromSeconds(6);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct DOC_INFO_1
        {
            public string pDocName;
            public string? pOutputFile;
            public string pDatatype;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct SYSTEMTIME
        {
            public ushort wYear, wMonth, wDayOfWeek, wDay, wHour, wMinute, wSecond, wMilliseconds;
        }

#pragma warning disable CS0649
        [StructLayout(LayoutKind.Sequential)]
        private struct JOB_INFO_1
        {
            public uint JobId;
            public IntPtr pPrinterName;
            public IntPtr pMachineName;
            public IntPtr pUserName;
            public IntPtr pDocument;
            public IntPtr pDatatype;
            public IntPtr pStatus;
            public uint Status;
            public uint Priority;
            public uint Position;
            public uint TotalPages;
            public uint PagesPrinted;
            public SYSTEMTIME Submitted;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PRINTER_INFO_6
        {
            public uint dwStatus;
        }
#pragma warning restore CS0649

        [DllImport("winspool.drv", EntryPoint = "OpenPrinterW", SetLastError = true, CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern bool OpenPrinter(string pPrinterName, out IntPtr phPrinter, IntPtr pDefault);

        [DllImport("winspool.drv", EntryPoint = "ClosePrinter", SetLastError = true, ExactSpelling = true)]
        private static extern bool ClosePrinter(IntPtr hPrinter);

        [DllImport("winspool.drv", EntryPoint = "StartDocPrinterW", SetLastError = true, CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern int StartDocPrinter(IntPtr hPrinter, int level, ref DOC_INFO_1 di);

        [DllImport("winspool.drv", EntryPoint = "EndDocPrinter", SetLastError = true, ExactSpelling = true)]
        private static extern bool EndDocPrinter(IntPtr hPrinter);

        [DllImport("winspool.drv", EntryPoint = "AbortPrinter", SetLastError = true, ExactSpelling = true)]
        private static extern bool AbortPrinter(IntPtr hPrinter);

        [DllImport("winspool.drv", EntryPoint = "StartPagePrinter", SetLastError = true, ExactSpelling = true)]
        private static extern bool StartPagePrinter(IntPtr hPrinter);

        [DllImport("winspool.drv", EntryPoint = "EndPagePrinter", SetLastError = true, ExactSpelling = true)]
        private static extern bool EndPagePrinter(IntPtr hPrinter);

        [DllImport("winspool.drv", EntryPoint = "WritePrinter", SetLastError = true, ExactSpelling = true)]
        private static extern bool WritePrinter(IntPtr hPrinter, byte[] pBuf, int cbBuf, out int pcWritten);

        [DllImport("winspool.drv", EntryPoint = "GetJobW", SetLastError = true, CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern bool GetJob(IntPtr hPrinter, uint jobId, uint level, IntPtr pJob, uint cbBuf, out uint pcbNeeded);

        [DllImport("winspool.drv", EntryPoint = "SetJobW", SetLastError = true, CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern bool SetJob(IntPtr hPrinter, uint jobId, uint level, IntPtr pJob, uint command);

        [DllImport("winspool.drv", EntryPoint = "GetPrinterW", SetLastError = true, CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern bool GetPrinter(IntPtr hPrinter, uint level, IntPtr pPrinter, uint cbBuf, out uint pcbNeeded);

        private readonly TimeSpan _timeout;

        public WinSpoolRawWriter()
            : this(AgentConstants.SpoolerJobTimeout)
        {
        }

        public WinSpoolRawWriter(TimeSpan timeout)
        {
            _timeout = timeout;
        }

        public RawPrintResult Write(string printerName, string documentName, byte[] data, CancellationToken ct, Action? onSpooled = null)
        {
            if (string.IsNullOrWhiteSpace(printerName)) return RawPrintResult.Fail(PrintErrorCodes.PrinterNotFound, "Nome da impressora não informado.");
            if (data == null || data.Length == 0) return RawPrintResult.Fail(PrintErrorCodes.InvalidPayload, "Nada a imprimir.");

            IntPtr handle;
            if (!OpenPrinter(printerName, out handle, IntPtr.Zero))
            {
                int err = Marshal.GetLastWin32Error();
                string code = SpoolerFlags.CodeForOpenError(err);
                string msg = code == PrintErrorCodes.PrinterNotFound
                    ? "Impressora " + printerName + " não encontrada neste computador."
                    : code == PrintErrorCodes.AccessDenied
                        ? "Sem permissão para usar a impressora " + printerName + "."
                        : "O Windows não abriu a impressora " + printerName + " (erro " + err.ToString(CultureInfo.InvariantCulture) + ").";
                return RawPrintResult.Fail(code, msg);
            }

            try
            {
                DOC_INFO_1 di = new DOC_INFO_1();
                di.pDocName = documentName;
                di.pOutputFile = null;
                di.pDatatype = "RAW";

                int jobId = StartDocPrinter(handle, 1, ref di);
                if (jobId <= 0)
                {
                    int err = Marshal.GetLastWin32Error();
                    if (err == ERROR_INVALID_DATATYPE)
                    {
                        return RawPrintResult.Fail(PrintErrorCodes.SpoolerError,
                            "O driver da impressora " + printerName + " não aceita impressão RAW. Use o driver do fabricante ou 'Generic / Text Only'.");
                    }
                    return RawPrintResult.Fail(PrintErrorCodes.SpoolerError, "O Windows recusou o documento para " + printerName + " (erro " + err.ToString(CultureInfo.InvariantCulture) + ").");
                }

                bool written = false;
                bool ended = false;
                try
                {
                    if (!StartPagePrinter(handle))
                    {
                        int err = Marshal.GetLastWin32Error();
                        AbortPrinter(handle);
                        return RawPrintResult.Fail(PrintErrorCodes.SpoolerError, "Falha ao iniciar a página na fila (erro " + err.ToString(CultureInfo.InvariantCulture) + ").");
                    }

                    int offset = 0;
                    while (offset < data.Length)
                    {
                        byte[] chunk = data;
                        int length = data.Length - offset;
                        if (offset > 0)
                        {
                            chunk = new byte[length];
                            Buffer.BlockCopy(data, offset, chunk, 0, length);
                        }
                        int done;
                        if (!WritePrinter(handle, chunk, length, out done) || done <= 0)
                        {
                            int err = Marshal.GetLastWin32Error();
                            AbortPrinter(handle);
                            return RawPrintResult.Fail(PrintErrorCodes.SpoolerError, "Falha ao enviar os dados para a fila (erro " + err.ToString(CultureInfo.InvariantCulture) + ").");
                        }
                        offset += done;
                    }

                    EndPagePrinter(handle);
                    written = true;
                }
                finally
                {
                    if (written) ended = EndDocPrinter(handle);
                }

                if (!ended)
                {
                    int err = Marshal.GetLastWin32Error();
                    return RawPrintResult.Fail(PrintErrorCodes.SpoolerError, "O Windows não concluiu o documento na fila (erro " + err.ToString(CultureInfo.InvariantCulture) + ").");
                }

                // O spooler guardou o documento inteiro (em disco): o papel está garantido. Daqui em diante, mesmo que o serviço seja
                // encerrado, o computador desligue ou a internet caia, o Windows imprime sozinho quando a impressora responder.
                // O chamador grava o diário local AGORA (antes da espera abaixo) para nunca reimprimir esse job.
                if (onSpooled != null)
                {
                    try
                    {
                        onSpooled();
                    }
                    catch (Exception)
                    {
                        // falha ao gravar o diário não pode derrubar a impressão em andamento
                    }
                }

                return WaitForSpooler(handle, (uint)jobId, printerName, ct);
            }
            finally
            {
                ClosePrinter(handle);
            }
        }

        /// <summary>
        /// Acompanha o job na fila. Sumiu da fila ou "impresso/concluído" = sucesso. Com erro/offline/sem papel persistente
        /// (ou ainda na fila ao fim do prazo com a impressora indisponível) = remove o job e devolve falha.
        /// </summary>
        private RawPrintResult WaitForSpooler(IntPtr handle, uint jobId, string printerName, CancellationToken ct)
        {
            Stopwatch total = Stopwatch.StartNew();
            Stopwatch? problemSince = null;
            string problemCode = string.Empty;
            string problemMessage = string.Empty;

            while (true)
            {
                uint status;
                if (!TryReadJobStatus(handle, jobId, out status))
                {
                    return RawPrintResult.Ok(); // o job já não está na fila: o spooler terminou (padrão da RAW em porta local/TCP)
                }

                if (SpoolerFlags.JobFinished(status)) return RawPrintResult.Ok();

                if (SpoolerFlags.JobRemovedWithoutPrinting(status))
                {
                    return RawPrintResult.Fail(PrintErrorCodes.SpoolerError, "O documento foi removido da fila do Windows antes de imprimir.");
                }

                string code;
                string message;
                if (SpoolerFlags.JobProblem(status, out code, out message))
                {
                    if (problemSince == null || code != problemCode) problemSince = Stopwatch.StartNew();
                    problemCode = code;
                    problemMessage = message;
                    if (problemSince.Elapsed >= ProblemPersistsFor)
                    {
                        return Abandon(handle, jobId, printerName, problemCode, problemMessage);
                    }
                }
                else
                {
                    problemSince = null;
                }

                if (ct.IsCancellationRequested) ct.ThrowIfCancellationRequested();

                if (total.Elapsed >= _timeout)
                {
                    // Ainda na fila e sem erro no job: confere a impressora. Indisponível = falha; senão o spooler segue imprimindo.
                    uint printerStatus;
                    if (TryReadPrinterStatus(handle, out printerStatus) && SpoolerFlags.PrinterProblem(printerStatus, out code, out message))
                    {
                        return Abandon(handle, jobId, printerName, code, message);
                    }
                    if (problemSince != null) return Abandon(handle, jobId, printerName, problemCode, problemMessage);
                    return RawPrintResult.Ok();
                }

                Thread.Sleep(PollInterval);
            }
        }

        private static RawPrintResult Abandon(IntPtr handle, uint jobId, string printerName, string code, string message)
        {
            // Remove da fila do Windows para que a nova tentativa do servidor não imprima em dobro quando a impressora voltar.
            SetJob(handle, jobId, 0, IntPtr.Zero, JOB_CONTROL_DELETE);
            return RawPrintResult.Fail(code, message + " (" + printerName + ")");
        }

        private static bool TryReadJobStatus(IntPtr handle, uint jobId, out uint status)
        {
            status = 0;
            uint needed;
            GetJob(handle, jobId, 1, IntPtr.Zero, 0, out needed);
            if (needed == 0) return false;
            IntPtr buffer = Marshal.AllocHGlobal((int)needed);
            try
            {
                uint ignored;
                if (!GetJob(handle, jobId, 1, buffer, needed, out ignored))
                {
                    return false; // qualquer falha ao ler = o job não está mais na fila (o caso normal é o erro 87)
                }
                JOB_INFO_1 info = Marshal.PtrToStructure<JOB_INFO_1>(buffer);
                status = info.Status;
                return true;
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }

        private static bool TryReadPrinterStatus(IntPtr handle, out uint status)
        {
            status = 0;
            uint needed;
            GetPrinter(handle, 6, IntPtr.Zero, 0, out needed);
            if (needed == 0) return false;
            IntPtr buffer = Marshal.AllocHGlobal((int)needed);
            try
            {
                uint ignored;
                if (!GetPrinter(handle, 6, buffer, needed, out ignored)) return false;
                PRINTER_INFO_6 info = Marshal.PtrToStructure<PRINTER_INFO_6>(buffer);
                status = info.dwStatus;
                return true;
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }
    }
}
