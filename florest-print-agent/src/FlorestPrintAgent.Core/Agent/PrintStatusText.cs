using System;
using System.Globalization;

namespace FlorestPrintAgent.Core.Agent
{
    /// <summary>Texto de "última impressão / erro de impressão" mostrado no Tray (código puro, testado em unidade).</summary>
    public static class PrintStatusText
    {
        /// <summary>
        /// Erro mais novo que a última impressão: "Erro de impressão: ..."; senão "Pedido 123 - COZINHA - Sucesso (14:32)".
        /// Sem nenhum evento: "—".
        /// </summary>
        public static string Describe(AgentStatusDto? status, out bool isError)
        {
            isError = false;
            if (status == null) return "—";

            if (status.UltimoErroImpressao != null)
            {
                isError = true;
                string message = string.IsNullOrWhiteSpace(status.UltimoErroImpressao.Mensagem)
                    ? "falha ao imprimir " + status.UltimoErroImpressao.Titulo
                    : status.UltimoErroImpressao.Mensagem!.Trim();
                return "Erro de impressão: " + message;
            }

            if (status.UltimaImpressao != null)
            {
                PrintEventDto e = status.UltimaImpressao;
                string title = string.IsNullOrWhiteSpace(e.Titulo) ? e.Destino : e.Titulo;
                string time = DateTime.SpecifyKind(e.EmUtc, DateTimeKind.Utc).ToLocalTime().ToString("HH:mm", CultureInfo.InvariantCulture);
                return title + " - Sucesso (" + time + ")";
            }

            return "—";
        }
    }
}
