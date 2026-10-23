using System;
using System.Threading;

namespace FlorestPrintAgent.Core.Jobs
{
    /// <summary>Códigos de erro de impressão enviados ao servidor (formato ^[a-z][a-z0-9_]{0,39}$, exigido pela Migration 033).</summary>
    public static class PrintErrorCodes
    {
        public const string PrinterNotFound = "impressora_nao_encontrada";
        public const string PrinterOffline = "impressora_offline";
        public const string PrinterError = "impressora_com_erro";
        public const string AccessDenied = "acesso_negado";
        public const string SpoolerError = "erro_spooler";
        public const string InvalidPayload = "payload_invalido";
        public const string Internal = "erro_interno";
        public const string Timeout = "tempo_esgotado";
    }

    /// <summary>Resultado de uma tentativa de enviar bytes à impressora.</summary>
    public sealed class RawPrintResult
    {
        public bool Success { get; private set; }
        public string ErrorCode { get; private set; } = string.Empty;
        public string Message { get; private set; } = string.Empty;

        public static RawPrintResult Ok()
        {
            RawPrintResult r = new RawPrintResult();
            r.Success = true;
            return r;
        }

        public static RawPrintResult Fail(string code, string message)
        {
            RawPrintResult r = new RawPrintResult();
            r.Success = false;
            r.ErrorCode = code;
            r.Message = message;
            return r;
        }
    }

    /// <summary>
    /// Envia bytes BRUTOS (RAW, sem driver gráfico) para uma fila do Windows. A fila é sempre indicada pelo nome:
    /// a impressora padrão do Windows NUNCA é usada.
    /// </summary>
    public interface IRawPrinterWriter
    {
        /// <param name="onSpooled">
        /// Chamado UMA vez, no instante em que o spooler do Windows ACEITOU o documento por completo (EndDocPrinter) e ANTES de
        /// esperar o papel sair. É o ponto em que o papel passa a estar garantido: o chamador grava o diário local aqui, para que
        /// uma queda de energia/serviço durante a espera não cause reimpressão. Não é chamado se o documento não foi aceito.
        /// </param>
        RawPrintResult Write(string printerName, string documentName, byte[] data, CancellationToken ct, Action? onSpooled = null);
    }
}
