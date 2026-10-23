using System;
using System.Collections.Generic;
using System.Text.Json.Serialization;
using FlorestPrintAgent.Core.Printers;
using FlorestPrintAgent.Core.Security;

namespace FlorestPrintAgent.Core.Api
{
    public enum ApiOutcome
    {
        Ok,
        /// <summary>HTTP 4xx com erro de negócio (codigo_invalido, dados_invalidos, instalacao_ja_vinculada...).</summary>
        Rejected,
        /// <summary>HTTP 401 da NOSSA função com erro de credencial (credencial_invalida, agente_revogado...).</summary>
        Unauthorized,
        RateLimited,
        ServerError,
        NetworkError,
        Timeout,
        /// <summary>Resposta fora do contrato (inclui 401/404 do gateway sem corpo da função).</summary>
        InvalidResponse,
    }

    public sealed class ApiResult<T> where T : class
    {
        public ApiOutcome Outcome { get; private set; }
        public int HttpStatus { get; private set; }
        public string? ErrorCode { get; private set; }
        public TimeSpan? RetryAfter { get; private set; }
        public T? Data { get; private set; }

        public bool IsOk
        {
            get { return Outcome == ApiOutcome.Ok; }
        }

        public static ApiResult<T> Success(T data, int httpStatus)
        {
            ApiResult<T> r = new ApiResult<T>();
            r.Outcome = ApiOutcome.Ok;
            r.HttpStatus = httpStatus;
            r.Data = data;
            return r;
        }

        public static ApiResult<T> Failure(ApiOutcome outcome, int httpStatus, string? errorCode, TimeSpan? retryAfter)
        {
            ApiResult<T> r = new ApiResult<T>();
            r.Outcome = outcome;
            r.HttpStatus = httpStatus;
            r.ErrorCode = errorCode;
            r.RetryAfter = retryAfter;
            return r;
        }
    }

    public sealed class EmptyResponse
    {
    }

    public sealed class PairVerifyResponse
    {
        public string EmpresaNome { get; set; } = string.Empty;
        public string? EstacaoNome { get; set; }
        public bool Reinstalacao { get; set; }
        public string? ExpiraEm { get; set; }
    }

    public sealed class PairConfirmRequest
    {
        public string Codigo { get; set; } = string.Empty;
        public string IdentificadorInstalacao { get; set; } = string.Empty;
        public string NomeComputador { get; set; } = string.Empty;
        public string SistemaOperacional { get; set; } = string.Empty;
        public string VersaoAgente { get; set; } = AgentConstants.AgentVersion;
    }

    public sealed class PairConfirmResponse
    {
        public AgentToken Token { get; set; } = null!;
        public string? EmpresaNome { get; set; }
        public string? EstacaoNome { get; set; }
        public bool Reinstalacao { get; set; }
        public int? HeartbeatSegundos { get; set; }
        public bool SincronizarAgora { get; set; }
        public int? LimiteImpressoras { get; set; }
        public int? LimiteBytes { get; set; }
    }

    public sealed class HeartbeatResponse
    {
        public string? EstacaoNome { get; set; }
        public int? HeartbeatSegundos { get; set; }
        public bool SincronizarAgora { get; set; }
        public bool RenovarCredencial { get; set; }
        public bool UsouCredencialAnterior { get; set; }
        public string? HoraServidor { get; set; }
    }

    public sealed class SyncRequest
    {
        public string IdentificadorInstalacao { get; set; } = string.Empty;
        public List<PrinterInfo> Impressoras { get; set; } = new List<PrinterInfo>();
        public string VersaoAgente { get; set; } = AgentConstants.AgentVersion;
        public string NomeComputador { get; set; } = string.Empty;
        public string SistemaOperacional { get; set; } = string.Empty;
    }

    public sealed class SyncResponse
    {
        public int Recebidas { get; set; }
        public int Validas { get; set; }
        public int Rejeitadas { get; set; }
        public int Novas { get; set; }
        public int Alteradas { get; set; }
        public int Desativadas { get; set; }
        public int Ativas { get; set; }
    }

    public sealed class RenewResponse
    {
        public AgentToken Token { get; set; } = null!;
        public int? GracaSegundos { get; set; }
    }

    // ----- corpos enviados (contrato da Edge Function; NUNCA contêm empresa_id/estacao_id) -----

    internal sealed class PairVerifyBody
    {
        [JsonPropertyName("codigo")] public string Codigo { get; set; } = string.Empty;
    }

    internal sealed class PairConfirmBody
    {
        [JsonPropertyName("codigo")] public string Codigo { get; set; } = string.Empty;
        [JsonPropertyName("identificador_instalacao")] public string IdentificadorInstalacao { get; set; } = string.Empty;
        [JsonPropertyName("nome_computador")] public string NomeComputador { get; set; } = string.Empty;
        [JsonPropertyName("sistema_operacional")] public string SistemaOperacional { get; set; } = string.Empty;
        [JsonPropertyName("versao_agente")] public string VersaoAgente { get; set; } = string.Empty;
    }

    internal sealed class HeartbeatBody
    {
        [JsonPropertyName("identificador_instalacao")] public string IdentificadorInstalacao { get; set; } = string.Empty;
        [JsonPropertyName("versao_agente")] public string VersaoAgente { get; set; } = string.Empty;
    }

    internal sealed class InstallationBody
    {
        [JsonPropertyName("identificador_instalacao")] public string IdentificadorInstalacao { get; set; } = string.Empty;
    }

    internal sealed class SyncBody
    {
        [JsonPropertyName("identificador_instalacao")] public string IdentificadorInstalacao { get; set; } = string.Empty;
        [JsonPropertyName("impressoras")] public List<PrinterInfo> Impressoras { get; set; } = new List<PrinterInfo>();
        [JsonPropertyName("versao_agente")] public string VersaoAgente { get; set; } = string.Empty;
        [JsonPropertyName("nome_computador")] public string NomeComputador { get; set; } = string.Empty;
        [JsonPropertyName("sistema_operacional")] public string SistemaOperacional { get; set; } = string.Empty;
    }
}
