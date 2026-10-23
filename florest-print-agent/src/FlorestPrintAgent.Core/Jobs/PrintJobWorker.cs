using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using FlorestPrintAgent.Core.Api;
using FlorestPrintAgent.Core.Security;
using Microsoft.Extensions.Logging;

namespace FlorestPrintAgent.Core.Jobs
{
    /// <summary>Credencial e identificação para consultar a fila. A empresa e a estação NÃO fazem parte: o servidor as deduz da credencial.</summary>
    public sealed class JobAccess
    {
        public JobAccess(AgentToken token, string installationId)
        {
            Token = token;
            InstallationId = installationId;
        }

        public AgentToken Token { get; }
        public string InstallationId { get; }
    }

    /// <summary>Entrega ao worker a credencial vigente (ou null quando não é para consultar: sem vínculo, credencial recusada, identidade com problema).</summary>
    public interface IJobAccessProvider
    {
        JobAccess? GetJobAccess();
    }

    /// <summary>
    /// Laço do SERVIÇO que consulta a fila, reserva (atômico, no servidor), imprime e confirma. Roda no Windows Service, sem o Tray
    /// e sem depender do portão (SemaphoreSlim) do AgentCoordinator: uma sincronização lenta não atrasa a impressão.
    ///
    /// Garantias:
    ///  - "impresso" só é enviado DEPOIS de o Windows aceitar o documento (RAW) e de o spooler não indicar erro;
    ///  - se a confirmação falhar (internet), o job fica no diário local e é confirmado depois, SEM reimprimir;
    ///  - falha de impressão é informada ao servidor (nova tentativa com espera crescente, ou falha final);
    ///  - nada de token/segredo em log.
    /// </summary>
    public sealed class PrintJobWorker
    {
        private static readonly TimeSpan[] ConfirmDelays = { TimeSpan.Zero, TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(5) };
        private static readonly TimeSpan JournalFlushSpacing = TimeSpan.FromSeconds(15);

        private readonly IEdgeApi _api;
        private readonly IJobAccessProvider _access;
        private readonly PrintJobProcessor _processor;
        private readonly IPrintedJournal _journal;
        private readonly IPrintActivity _activity;
        private readonly IClock _clock;
        private readonly ILogger _log;

        private int _failures;
        private DateTime _nextJournalFlushUtc = DateTime.MinValue;

        public Func<double> RandomSource { get; set; } = NextRandom;

        /// <summary>Espera entre tentativas de confirmação (substituível nos testes).</summary>
        public Func<TimeSpan, CancellationToken, Task> Delay { get; set; } = (t, ct) => t > TimeSpan.Zero ? Task.Delay(t, ct) : Task.CompletedTask;

        public PrintJobWorker(
            IEdgeApi api,
            IJobAccessProvider access,
            PrintJobProcessor processor,
            IPrintedJournal journal,
            IPrintActivity activity,
            IClock clock,
            ILogger logger)
        {
            _api = api;
            _access = access;
            _processor = processor;
            _journal = journal;
            _activity = activity;
            _clock = clock;
            _log = logger;
        }

        private static double NextRandom()
        {
            return Random.Shared.NextDouble();
        }

        public async Task RunAsync(CancellationToken ct)
        {
            _log.LogInformation("Serviço de impressão iniciado (consulta da fila de impressão).");
            while (!ct.IsCancellationRequested)
            {
                TimeSpan wait;
                try
                {
                    wait = await RunOnceAsync(ct).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (ct.IsCancellationRequested)
                {
                    break;
                }
                catch (Exception ex)
                {
                    // nunca deixa o laço morrer
                    _failures++;
                    wait = BackoffDelay(_failures);
                    _log.LogError("Erro inesperado no laço de impressão ({Tipo}).", ex.GetType().Name);
                }

                try
                {
                    if (wait > TimeSpan.Zero) await Task.Delay(wait, ct).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
            }
            _log.LogInformation("Serviço de impressão encerrado.");
        }

        /// <summary>Uma volta: confirma pendências, consulta a fila, imprime. Devolve quanto esperar antes da próxima.</summary>
        public async Task<TimeSpan> RunOnceAsync(CancellationToken ct)
        {
            JobAccess? access = _access.GetJobAccess();
            if (access == null) return AgentConstants.JobNotLinkedDelay;

            await FlushJournalAsync(access, ct).ConfigureAwait(false);

            ApiResult<ClaimJobsResponse> claim = await _api.ClaimJobsAsync(
                access.Token, access.InstallationId, AgentConstants.JobClaimLimit, AgentConstants.JobLongPollSeconds, ct).ConfigureAwait(false);

            switch (claim.Outcome)
            {
                case ApiOutcome.Ok:
                {
                    _failures = 0;
                    ClaimJobsResponse data = claim.Data ?? new ClaimJobsResponse();
                    if (data.Jobs.Count == 0) return AgentConstants.JobMinPollSpacing;

                    DateTime receivedUtc = _clock.UtcNow;
                    foreach (PrintJob job in data.Jobs)
                    {
                        ct.ThrowIfCancellationRequested();
                        await HandleJobAsync(access, job, receivedUtc, ct).ConfigureAwait(false);
                    }
                    return TimeSpan.Zero;
                }
                case ApiOutcome.Unauthorized:
                    _log.LogWarning("O servidor recusou a credencial ao consultar a fila de impressão ({Codigo}). Nova tentativa em alguns minutos.", claim.ErrorCode ?? "-");
                    return AgentConstants.JobCredentialRejectedDelay;
                case ApiOutcome.RateLimited:
                {
                    TimeSpan wait = claim.RetryAfter ?? TimeSpan.FromSeconds(30);
                    if (wait < TimeSpan.FromSeconds(5)) wait = TimeSpan.FromSeconds(5);
                    _log.LogWarning("Muitas consultas à fila de impressão; aguardando {Segundos} s.", (int)wait.TotalSeconds);
                    return wait;
                }
                case ApiOutcome.NetworkError:
                case ApiOutcome.Timeout:
                case ApiOutcome.ServerError:
                {
                    _failures++;
                    TimeSpan wait = BackoffDelay(_failures);
                    if (_failures == 1 || _failures % 10 == 0)
                    {
                        _log.LogWarning("Sem acesso à fila de impressão: {Resultado} (HTTP {Status}). Nova tentativa em {Segundos} s.", claim.Outcome, claim.HttpStatus, (int)wait.TotalSeconds);
                    }
                    return wait;
                }
                default:
                    _failures++;
                    _log.LogWarning("A função do servidor não respondeu como esperado à fila de impressão ({Resultado}, HTTP {Status}, {Codigo}). Publique a versão nova da função florest-print-agent e aplique a migration 033.", claim.Outcome, claim.HttpStatus, claim.ErrorCode ?? "-");
                    return AgentConstants.JobUnsupportedServerDelay;
            }
        }

        // ----------------------------------------------------------------------------------------------------------

        private async Task HandleJobAsync(JobAccess access, PrintJob job, DateTime receivedUtc, CancellationToken ct)
        {
            string printerName = job.Impressora != null ? job.Impressora.Nome : string.Empty;
            _log.LogInformation("Job recebido: {Job} ({Titulo}), destino {Destino}, impressora '{Impressora}', tentativa {Tentativa}/{Max}.",
                job.Id, job.Titulo, job.Destino, printerName, job.Tentativa, job.MaxTentativas);

            // Já impresso antes (a confirmação não chegou ao servidor): só confirma, NUNCA reimprime.
            if (_journal.Contains(job.Id))
            {
                _log.LogInformation("Job {Job} já foi impresso neste computador; apenas confirmando ao servidor.", job.Id);
                await ConfirmAsync(access, job.Id, true, ct).ConfigureAwait(false);
                return;
            }

            // A reserva vale poucos segundos: se não dá mais tempo de imprimir, deixa o servidor reciclar o job.
            if (job.ReservaSegundos > 0)
            {
                TimeSpan left = TimeSpan.FromSeconds(job.ReservaSegundos) - (_clock.UtcNow - receivedUtc);
                if (left < AgentConstants.JobLeaseSafetyMargin)
                {
                    _log.LogWarning("Job {Job} não será impresso agora: a reserva está perto de vencer; o servidor o devolverá à fila.", job.Id);
                    return;
                }
            }

            // O diário local é gravado no instante em que o spooler do Windows ACEITA o documento (callback abaixo), ANTES da espera
            // do papel: se a energia/o serviço cair durante a espera, o job volta pela fila e é só confirmado, nunca reimpresso.
            string jobId = job.Id;
            bool spooled = false;
            PrintOutcome outcome;
            try
            {
                outcome = await Task.Run(() => _processor.Process(job, ct, () => { _journal.Add(jobId); spooled = true; }), ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception ex)
            {
                outcome = PrintOutcome.Fail(PrintErrorCodes.Internal, "Erro inesperado ao imprimir.", false, printerName);
                _log.LogError("Erro inesperado ao imprimir o job {Job} ({Tipo}).", job.Id, ex.GetType().Name);
            }

            if (!outcome.Success && spooled && outcome.ErrorCode == PrintErrorCodes.Internal)
            {
                // Erro INESPERADO depois de o spooler já ter aceitado o documento: o papel está garantido (o Windows imprime sozinho).
                // Reportar falha faria o servidor reenviar e o papel sairia em dobro; então segue como impresso.
                _log.LogWarning("Job {Job}: erro inesperado depois de o spooler aceitar o documento; considerado impresso.", job.Id);
                outcome = PrintOutcome.Ok(string.IsNullOrEmpty(outcome.PrinterName) ? printerName : outcome.PrinterName);
            }

            if (outcome.Success)
            {
                _log.LogInformation("Job {Job} impresso na impressora '{Impressora}'.", job.Id, outcome.PrinterName);
                _activity.RecordSuccess(job.Titulo, job.Destino, outcome.PrinterName);
                _journal.Add(job.Id); // já gravado pelo callback do spooler; repetido aqui por garantia (idempotente) antes de confirmar
                await ConfirmAsync(access, job.Id, true, ct).ConfigureAwait(false);
            }
            else
            {
                _log.LogWarning("Job {Job} não foi impresso: {Codigo} - {Mensagem}", job.Id, outcome.ErrorCode, outcome.Message);
                // o callback do spooler pode ter gravado o diário antes de a impressora acusar problema (documento removido da fila do
                // Windows): como o papel NÃO saiu, o job precisa poder ser impresso de novo na próxima tentativa.
                _journal.Remove(job.Id);
                _activity.RecordFailure(job.Titulo, job.Destino, outcome.Message);
                await ReportFailureAsync(access, job, outcome, ct).ConfigureAwait(false);
            }
        }

        /// <summary>Confirma "impresso". Devolve true quando o servidor aceitou (ou o job não existe mais para este agente).</summary>
        private async Task<bool> ConfirmAsync(JobAccess access, string jobId, bool withRetries, CancellationToken ct)
        {
            int attempts = withRetries ? ConfirmDelays.Length : 1;
            for (int i = 0; i < attempts; i++)
            {
                await Delay(ConfirmDelays[i], ct).ConfigureAwait(false);
                ApiResult<JobAckResponse> r = await _api.CompleteJobAsync(access.Token, access.InstallationId, jobId, ct).ConfigureAwait(false);

                if (r.Outcome == ApiOutcome.Ok)
                {
                    _journal.Remove(jobId);
                    return true;
                }

                if (r.Outcome == ApiOutcome.Rejected && IsFinalRejection(r.ErrorCode))
                {
                    // O servidor não vai aceitar nunca mais (cancelado, reciclado para outro agente...). Não adianta insistir.
                    _log.LogWarning("O servidor não aceitou a confirmação do job {Job} ({Codigo}); removido do diário local.", jobId, r.ErrorCode ?? "-");
                    _journal.Remove(jobId);
                    return true;
                }

                if (r.Outcome == ApiOutcome.Unauthorized)
                {
                    _log.LogWarning("Credencial recusada ao confirmar o job {Job}; a confirmação será repetida depois.", jobId);
                    break;
                }
            }

            _log.LogWarning("Job {Job} está impresso, mas a confirmação ao servidor ainda não foi aceita; será repetida (sem reimprimir).", jobId);
            return false;
        }

        private static bool IsFinalRejection(string? code)
        {
            return code == "job_inexistente" || code == "job_nao_reservado" || code == "job_cancelado";
        }

        private async Task ReportFailureAsync(JobAccess access, PrintJob job, PrintOutcome outcome, CancellationToken ct)
        {
            for (int i = 0; i < ConfirmDelays.Length; i++)
            {
                await Delay(ConfirmDelays[i], ct).ConfigureAwait(false);
                ApiResult<JobAckResponse> r = await _api.FailJobAsync(
                    access.Token, access.InstallationId, job.Id, outcome.ErrorCode, outcome.Message, outcome.Definitive, ct).ConfigureAwait(false);

                if (r.Outcome == ApiOutcome.Ok) return;
                if (r.Outcome == ApiOutcome.Rejected) return;       // job_cancelado / job_nao_reservado...: nada mais a fazer
                if (r.Outcome == ApiOutcome.Unauthorized) break;
            }
            // Se não deu para avisar, a reserva vence sozinha e o servidor devolve o job à fila (com espera crescente).
            _log.LogWarning("Não foi possível informar ao servidor a falha do job {Job}; a reserva vai vencer e o job voltará à fila.", job.Id);
        }

        private async Task FlushJournalAsync(JobAccess access, CancellationToken ct)
        {
            IReadOnlyList<string> pending = _journal.Pending();
            if (pending.Count == 0) return;
            DateTime now = _clock.UtcNow;
            if (now < _nextJournalFlushUtc) return;
            _nextJournalFlushUtc = now + JournalFlushSpacing;

            foreach (string id in pending)
            {
                ct.ThrowIfCancellationRequested();
                bool ok = await ConfirmAsync(access, id, false, ct).ConfigureAwait(false);
                if (!ok) break; // sem internet/credencial: tenta de novo no próximo ciclo
            }
        }

        private TimeSpan BackoffDelay(int failures)
        {
            double seconds = AgentConstants.JobBackoffStart.TotalSeconds * Math.Pow(2, Math.Max(0, Math.Min(failures, 10) - 1));
            seconds = Math.Min(seconds, AgentConstants.JobBackoffCap.TotalSeconds);
            double jitter = 0.8 + 0.4 * RandomSource();
            return TimeSpan.FromSeconds(Math.Max(1, seconds * jitter));
        }
    }
}
