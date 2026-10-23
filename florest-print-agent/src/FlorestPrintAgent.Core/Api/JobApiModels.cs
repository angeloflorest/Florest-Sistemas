using System.Collections.Generic;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace FlorestPrintAgent.Core.Api
{
    /// <summary>Impressora que o servidor resolveu para o job (destino -> impressora da ESTAÇÃO deste agente).</summary>
    public sealed class JobPrinter
    {
        public string? Id { get; set; }
        /// <summary>Nome da fila no Windows (como o agente a informou na sincronização).</summary>
        public string Nome { get; set; } = string.Empty;
        /// <summary>Identificador estável calculado pelo agente (SHA-256); é a chave principal de resolução.</summary>
        public string Identificador { get; set; } = string.Empty;
        public string? Conexao { get; set; }
        public string? PortaWindows { get; set; }
    }

    /// <summary>Um papel a imprimir, reservado para este agente pelo servidor.</summary>
    public sealed class PrintJob
    {
        public string Id { get; set; } = string.Empty;
        public string Destino { get; set; } = string.Empty;
        public string Tipo { get; set; } = string.Empty;
        public string Titulo { get; set; } = string.Empty;
        public int Tentativa { get; set; }
        public int MaxTentativas { get; set; }
        /// <summary>Quanto tempo o servidor guarda a reserva; passado isso o job volta para a fila.</summary>
        public int ReservaSegundos { get; set; }
        /// <summary>Dados estruturados do papel (já independente do JsonDocument original).</summary>
        public JsonElement Payload { get; set; }
        public JobPrinter Impressora { get; set; } = new JobPrinter();
    }

    public sealed class ClaimJobsResponse
    {
        public List<PrintJob> Jobs { get; set; } = new List<PrintJob>();
    }

    /// <summary>Resposta de complete/fail.</summary>
    public sealed class JobAckResponse
    {
        public string? Status { get; set; }
        public bool JaConfirmado { get; set; }
        public int? Tentativas { get; set; }
        public int? MaxTentativas { get; set; }
    }

    // ----- corpos enviados (NUNCA contêm empresa_id/estacao_id: a empresa e a estação saem da credencial, no banco) -----

    internal sealed class ClaimJobsBody
    {
        [JsonPropertyName("identificador_instalacao")] public string IdentificadorInstalacao { get; set; } = string.Empty;
        [JsonPropertyName("limite")] public int Limite { get; set; }
        [JsonPropertyName("espera_segundos")] public int EsperaSegundos { get; set; }
    }

    internal sealed class JobCompleteBody
    {
        [JsonPropertyName("identificador_instalacao")] public string IdentificadorInstalacao { get; set; } = string.Empty;
        [JsonPropertyName("job_id")] public string JobId { get; set; } = string.Empty;
    }

    internal sealed class JobFailBody
    {
        [JsonPropertyName("identificador_instalacao")] public string IdentificadorInstalacao { get; set; } = string.Empty;
        [JsonPropertyName("job_id")] public string JobId { get; set; } = string.Empty;
        [JsonPropertyName("erro_codigo")] public string ErroCodigo { get; set; } = string.Empty;
        [JsonPropertyName("erro_mensagem")] public string ErroMensagem { get; set; } = string.Empty;
        [JsonPropertyName("definitivo")] public bool Definitivo { get; set; }
    }
}
