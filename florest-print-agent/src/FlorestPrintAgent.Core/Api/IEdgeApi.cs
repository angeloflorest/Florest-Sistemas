using System.Threading;
using System.Threading.Tasks;
using FlorestPrintAgent.Core.Security;

namespace FlorestPrintAgent.Core.Api
{
    /// <summary>Contrato do servidor (Edge Function florest-print-agent). Abstraído para testes sem rede.</summary>
    public interface IEdgeApi
    {
        Task<ApiResult<PairVerifyResponse>> PairVerifyAsync(string codigo, CancellationToken ct);

        Task<ApiResult<PairConfirmResponse>> PairConfirmAsync(PairConfirmRequest request, CancellationToken ct);

        Task<ApiResult<HeartbeatResponse>> HeartbeatAsync(AgentToken token, string installationId, string agentVersion, CancellationToken ct);

        Task<ApiResult<SyncResponse>> SyncAsync(AgentToken token, SyncRequest request, CancellationToken ct);

        Task<ApiResult<RenewResponse>> RenewAsync(AgentToken token, string installationId, CancellationToken ct);

        Task<ApiResult<EmptyResponse>> UnlinkAsync(AgentToken token, string installationId, CancellationToken ct);

        // ----- Fila de impressão (Fase C). A empresa e a estação NUNCA são enviadas: saem da credencial, no servidor. -----

        /// <summary>Reserva (atômico) os jobs da estação deste agente. waitSeconds &gt; 0 = long-poll no servidor.</summary>
        Task<ApiResult<ClaimJobsResponse>> ClaimJobsAsync(AgentToken token, string installationId, int limit, int waitSeconds, CancellationToken ct);

        /// <summary>Confirma que o job foi impresso. Só chamar DEPOIS de o Windows aceitar o documento.</summary>
        Task<ApiResult<JobAckResponse>> CompleteJobAsync(AgentToken token, string installationId, string jobId, CancellationToken ct);

        /// <summary>Registra a falha do job (o servidor decide: nova tentativa com backoff ou falha definitiva).</summary>
        Task<ApiResult<JobAckResponse>> FailJobAsync(AgentToken token, string installationId, string jobId, string errorCode, string errorMessage, bool definitive, CancellationToken ct);
    }
}
