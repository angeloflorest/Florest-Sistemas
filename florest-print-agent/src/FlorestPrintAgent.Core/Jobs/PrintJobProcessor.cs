using System;
using System.Text;
using System.Threading;
using FlorestPrintAgent.Core.Api;
using Microsoft.Extensions.Logging;

namespace FlorestPrintAgent.Core.Jobs
{
    public sealed class PrintOutcome
    {
        public bool Success { get; private set; }
        public string PrinterName { get; private set; } = string.Empty;
        public string ErrorCode { get; private set; } = string.Empty;
        public string Message { get; private set; } = string.Empty;
        /// <summary>True quando repetir não adianta (conteúdo inválido): o servidor encerra o job sem novas tentativas.</summary>
        public bool Definitive { get; private set; }

        public static PrintOutcome Ok(string printerName)
        {
            PrintOutcome o = new PrintOutcome();
            o.Success = true;
            o.PrinterName = printerName;
            return o;
        }

        public static PrintOutcome Fail(string code, string message, bool definitive, string printerName)
        {
            PrintOutcome o = new PrintOutcome();
            o.Success = false;
            o.ErrorCode = code;
            o.Message = message;
            o.Definitive = definitive;
            o.PrinterName = printerName;
            return o;
        }
    }

    /// <summary>Um job -> bytes ESC/POS -> fila do Windows indicada pelo servidor. Bloqueante (chamar fora da thread principal).</summary>
    public sealed class PrintJobProcessor
    {
        private readonly IPrinterResolver _resolver;
        private readonly IRawPrinterWriter _writer;
        private readonly Func<string, TicketLayout> _layoutProvider;
        private readonly ILogger _log;

        public PrintJobProcessor(IPrinterResolver resolver, IRawPrinterWriter writer, Func<string, TicketLayout> layoutProvider, ILogger logger)
        {
            _resolver = resolver;
            _writer = writer;
            _layoutProvider = layoutProvider;
            _log = logger;
        }

        /// <param name="onSpooled">Repassado ao escritor: chamado quando o spooler aceitou o documento (ver IRawPrinterWriter).</param>
        public PrintOutcome Process(PrintJob job, CancellationToken ct, Action? onSpooled = null)
        {
            string wanted = job.Impressora != null ? job.Impressora.Nome : string.Empty;
            try
            {
                TicketData? data;
                string parseError;
                if (!TicketParser.TryParse(job.Tipo, job.Payload, out data, out parseError) || data == null)
                {
                    return PrintOutcome.Fail(PrintErrorCodes.InvalidPayload, parseError, true, wanted);
                }

                PrinterResolution resolution = _resolver.Resolve(job.Impressora ?? new JobPrinter());
                if (!resolution.Found)
                {
                    return PrintOutcome.Fail(resolution.ErrorCode, resolution.Message, false, wanted);
                }

                if (!string.IsNullOrEmpty(resolution.Note))
                {
                    _log.LogWarning("{Aviso}", resolution.Note);
                }

                if (string.Equals(resolution.Status, Printers.PrinterStatus.Offline, StringComparison.Ordinal))
                {
                    // Só aviso: o spooler guarda o documento e a conferência abaixo decide se a impressora realmente não respondeu.
                    _log.LogWarning("A impressora '{Impressora}' aparece como offline no Windows; tentando imprimir mesmo assim.", resolution.Name);
                }

                TicketLayout layout = _layoutProvider(resolution.Name);
                byte[] bytes = TicketBuilder.Build(data, layout);
                string document = DocumentName(job);

                RawPrintResult result = _writer.Write(resolution.Name, document, bytes, ct, onSpooled);
                if (result.Success) return PrintOutcome.Ok(resolution.Name);
                return PrintOutcome.Fail(result.ErrorCode, result.Message, false, resolution.Name);
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception ex)
            {
                _log.LogError("Erro inesperado ao preparar a impressão ({Tipo}).", ex.GetType().Name);
                return PrintOutcome.Fail(PrintErrorCodes.Internal, "Erro inesperado ao preparar a impressão.", false, wanted);
            }
        }

        /// <summary>Nome que aparece na fila do Windows (somente ASCII simples e curto).</summary>
        internal static string DocumentName(PrintJob job)
        {
            StringBuilder sb = new StringBuilder("Florest - ");
            string title = string.IsNullOrWhiteSpace(job.Titulo) ? job.Destino : job.Titulo;
            foreach (char c in title ?? string.Empty)
            {
                if (sb.Length >= 60) break;
                sb.Append(c >= ' ' && c < 0x7F ? c : '?');
            }
            return sb.ToString();
        }
    }
}
