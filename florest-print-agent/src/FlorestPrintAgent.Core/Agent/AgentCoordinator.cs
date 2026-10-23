using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using FlorestPrintAgent.Core.Api;
using FlorestPrintAgent.Core.Jobs;
using FlorestPrintAgent.Core.Printers;
using FlorestPrintAgent.Core.Security;
using FlorestPrintAgent.Core.Storage;
using Microsoft.Extensions.Logging;

namespace FlorestPrintAgent.Core.Agent
{
    /// <summary>Dados do computador (injetável para testes).</summary>
    public sealed class HostInfo
    {
        public string MachineName { get; }
        public string OsDescription { get; }

        public HostInfo(string machineName, string osDescription)
        {
            MachineName = machineName;
            OsDescription = osDescription;
        }

        public static HostInfo FromEnvironment()
        {
            return new HostInfo(Environment.MachineName, RuntimeInformation.OSDescription);
        }
    }

    /// <summary>Resultado de uma tentativa de detectar e sincronizar impressoras.</summary>
    public sealed class SyncAttemptResult
    {
        /// <summary>False quando outra operação estava em andamento (nada foi feito).</summary>
        public bool Ran { get; set; }
        public bool DiscoverySucceeded { get; set; }
        /// <summary>True quando houve chamada ao servidor.</summary>
        public bool ServerCalled { get; set; }
        /// <summary>True quando o servidor aceitou a lista.</summary>
        public bool Synced { get; set; }
        public string? ErrorCode { get; set; }
        public string? Message { get; set; }
        public List<PrinterInfo> Printers { get; set; } = new List<PrinterInfo>();
        public SyncSummary? Summary { get; set; }
    }

    /// <summary>
    /// O "cérebro" do agente (roda dentro do Service). É a ÚNICA parte que fala com o servidor e a única que enxerga o token.
    ///
    /// Garantias:
    ///  - UM portão (SemaphoreSlim) serializa pareamento, heartbeat, renovação, sincronização e desvinculação:
    ///    nunca há dois heartbeats nem duas sincronizações ao mesmo tempo;
    ///  - falha de descoberta NUNCA vira "lista vazia" no servidor (lista vazia só após varredura completa bem-sucedida);
    ///  - offline, 5xx, credencial recusada, Tray fechado ou reinício NUNCA apagam o vínculo automaticamente;
    ///  - renovação: o novo token é gravado (DPAPI, atômico) ANTES de substituir o da memória;
    ///  - desvincular: a credencial local só é apagada depois do sucesso no servidor;
    ///  - nenhum token, segredo, hash de credencial ou código de pareamento é registrado em log.
    /// </summary>
    public sealed class AgentCoordinator : IAgentController, IJobAccessProvider
    {
        private static readonly TimeSpan GateTimeout = TimeSpan.FromSeconds(60);
        private static readonly TimeSpan MaxWait = TimeSpan.FromMinutes(5);
        private static readonly TimeSpan StateSaveThrottle = TimeSpan.FromMinutes(5);
        private static readonly TimeSpan DiscoveryStuckAfter = TimeSpan.FromMinutes(10);

        private readonly IEdgeApi _api;
        private readonly IPrinterDiscovery _discovery;
        private readonly CredentialVault _vault;
        private readonly AgentStateStore _stateStore;
        private volatile string _installationId;
        private string? _identityProblem;
        private Func<string>? _identityProvider;
        private PendingPairing? _pendingPairing;
        private readonly HostInfo _host;
        private readonly IClock _clock;
        private readonly ILogger _log;

        private readonly object _stateLock = new object();
        private readonly SemaphoreSlim _gate = new SemaphoreSlim(1, 1);
        private readonly SemaphoreSlim _wake = new SemaphoreSlim(0, 1);
        private readonly object _discoveryLock = new object();

        private AgentState _state = new AgentState();
        private CredentialLoadStatus _credentialStatus = CredentialLoadStatus.Missing;
        private List<PrinterInfo> _lastPrinters = new List<PrinterInfo>();
        private bool _initialized;

        private volatile bool _syncRequested;
        private DateTime _lastManualScanUtc = DateTime.MinValue;
        private volatile bool _renewRequested;
        private DateTime _nextHeartbeatUtc = DateTime.MinValue;
        private DateTime _nextSyncUtc = DateTime.MinValue;
        private DateTime _lastSyncAttemptUtc = DateTime.MinValue;
        private DateTime _lastServerRequestedSyncUtc = DateTime.MinValue;
        private DateTime _lastStateSaveUtc = DateTime.MinValue;
        private int _heartbeatFailures;
        private int _syncFailures;

        private bool _discoveryRunning;
        private DateTime _discoveryStartedUtc = DateTime.MinValue;
        private int _discoveryGeneration;

        /// <summary>Fonte de aleatoriedade do jitter/backoff (substituível em testes).</summary>
        public Func<double> RandomSource { get; set; } = NextRandom;

        public AgentCoordinator(
            IEdgeApi api,
            IPrinterDiscovery discovery,
            CredentialVault vault,
            AgentStateStore stateStore,
            string installationId,
            HostInfo host,
            IClock clock,
            ILogger logger)
        {
            _api = api;
            _discovery = discovery;
            _vault = vault;
            _stateStore = stateStore;
            _installationId = installationId;
            _host = host;
            _clock = clock;
            _log = logger;
        }

        private static double NextRandom()
        {
            return Random.Shared.NextDouble();
        }

        /// <summary>Última impressão/erro de impressão (preenchido pelo PrintJobWorker); somente leitura para o status.</summary>
        public IPrintActivity? PrintActivity { get; set; }

        /// <summary>
        /// Credencial para a fila de impressão. Null = não consultar agora: sem vínculo, identidade com problema ou credencial
        /// recusada pelo servidor (o heartbeat é quem detecta e limpa essa situação). Não usa o portão: a impressão não espera sincronização.
        /// </summary>
        public JobAccess? GetJobAccess()
        {
            AgentToken? token;
            string installationId;
            lock (_stateLock)
            {
                if (_identityProblem != null || _state.CredentialRejected) return null;
                installationId = _installationId;
            }
            token = _vault.GetActive();
            if (token == null || string.IsNullOrEmpty(installationId)) return null;
            return new JobAccess(token, installationId);
        }

        // ==========================================================================================================
        // Inicialização e laço principal
        // ==========================================================================================================

        /// <summary>Pareamento verificado e ainda não confirmado: só em memória (nunca em disco, nunca em log).</summary>
        private sealed class PendingPairing
        {
            public string Code = string.Empty;
            public string OwnerKey = string.Empty;
            public DateTime ExpiresUtc;
        }

        /// <summary>
        /// Chamado na inicialização quando a identidade da instalação não pôde ser obtida com segurança (arquivo ausente/corrompido
        /// com vínculo existente, ou erro temporário de leitura). O agente NÃO fala com o servidor enquanto isso durar e tenta
        /// resolver sozinho a cada 30 s; nenhuma identidade nova é criada por este caminho.
        /// </summary>
        public void SetIdentityProblem(string message, Func<string> provider)
        {
            lock (_stateLock)
            {
                _identityProblem = message;
                _identityProvider = provider;
            }
        }

        private AgentToken? ActiveToken()
        {
            if (_identityProblem != null) return null;
            return _vault.GetActive();
        }

        private void TryRecoverIdentity()
        {
            Func<string>? provider = _identityProvider;
            if (provider == null) return;
            try
            {
                string id = provider();
                lock (_stateLock)
                {
                    _installationId = id;
                    _identityProblem = null;
                    _state.LastError = null;
                }
                _nextHeartbeatUtc = _clock.UtcNow;
                _syncRequested = true;
                _log.LogInformation("Identificação da instalação resolvida.");
            }
            catch (IdentityProblemException ex)
            {
                lock (_stateLock) { _identityProblem = ex.Message; }
            }
            catch (Exception ex)
            {
                _log.LogWarning("A identificação da instalação ainda não pôde ser obtida ({Tipo}).", ex.GetType().Name);
            }
        }

        public void Initialize()
        {
            lock (_stateLock)
            {
                if (_initialized) return;
                _initialized = true;
                _state = _stateStore.Load();
                _credentialStatus = _vault.Load();
                PurgeExpiredUserLists(_clock.UtcNow);
                if (_credentialStatus == CredentialLoadStatus.Corrupt)
                {
                    _state.LastError = AgentMessages.CredentialUnreadable;
                }
                else if (_credentialStatus == CredentialLoadStatus.Unreadable)
                {
                    _state.LastError = AgentMessages.CredentialTemporarilyUnreadable;
                }
            }

            DateTime now = _clock.UtcNow;
            _nextHeartbeatUtc = now;
            _nextSyncUtc = now;
            _syncRequested = true; // sincroniza ao iniciar
            _log.LogInformation("Agente iniciado (versão {Versao}). Vinculado: {Vinculado}.", AgentConstants.AgentVersion, _vault.HasCredential);
            if (_credentialStatus == CredentialLoadStatus.Corrupt)
            {
                _log.LogWarning("A credencial local existe, mas não pôde ser lida. É preciso vincular novamente.");
            }
            else if (_credentialStatus == CredentialLoadStatus.Unreadable)
            {
                _log.LogWarning("A credencial local não pôde ser lida agora (erro temporário). Nova tentativa em breve; nada foi apagado.");
            }
        }

        public async Task RunAsync(CancellationToken ct)
        {
            Initialize();
            while (!ct.IsCancellationRequested)
            {
                try
                {
                    await RunIterationAsync(ct).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (ct.IsCancellationRequested)
                {
                    break;
                }
                catch (Exception ex)
                {
                    _log.LogError("Erro inesperado no ciclo do agente ({Tipo}).", ex.GetType().Name);
                    try
                    {
                        await Task.Delay(TimeSpan.FromSeconds(30), ct).ConfigureAwait(false);
                    }
                    catch (OperationCanceledException)
                    {
                        break;
                    }
                }
            }
            SaveState(true);
            _log.LogInformation("Agente parado.");
        }

        private async Task RunIterationAsync(CancellationToken ct)
        {
            if (_identityProblem != null)
            {
                TryRecoverIdentity();
                if (_identityProblem != null)
                {
                    await WaitAsync(TimeSpan.FromSeconds(30), ct).ConfigureAwait(false);
                    return;
                }
            }

            if (!_vault.HasCredential)
            {
                bool retryRead;
                lock (_stateLock) { retryRead = _credentialStatus == CredentialLoadStatus.Unreadable; }
                if (retryRead)
                {
                    // erro transitório de leitura: tenta de novo (o vínculo existe no disco e NÃO foi perdido)
                    CredentialLoadStatus reloaded = _vault.Load();
                    lock (_stateLock)
                    {
                        _credentialStatus = reloaded;
                        if (reloaded == CredentialLoadStatus.Ok)
                        {
                            _state.LastError = null;
                            _syncRequested = true;
                        }
                        else if (reloaded == CredentialLoadStatus.Corrupt)
                        {
                            _state.LastError = AgentMessages.CredentialUnreadable;
                        }
                        else if (reloaded == CredentialLoadStatus.Missing)
                        {
                            _state.LastError = null;
                        }
                    }
                    if (reloaded == CredentialLoadStatus.Ok)
                    {
                        _nextHeartbeatUtc = _clock.UtcNow;
                        _log.LogInformation("Credencial local lida com sucesso após erro temporário.");
                        return;
                    }
                    if (reloaded == CredentialLoadStatus.Unreadable)
                    {
                        await WaitAsync(TimeSpan.FromSeconds(30), ct).ConfigureAwait(false);
                        return;
                    }
                }

                // não vinculado: dorme até alguém concluir um pareamento (que acorda o laço)
                await WaitAsync(MaxWait, ct).ConfigureAwait(false);
                return;
            }

            if (_vault.HasPendingPersistence) _vault.TryFlushPending();

            DateTime now = _clock.UtcNow;
            if (now >= _nextHeartbeatUtc)
            {
                await HeartbeatOnceAsync(ct).ConfigureAwait(false);
            }

            if (_renewRequested)
            {
                await RenewOnceAsync(ct).ConfigureAwait(false);
            }

            now = _clock.UtcNow;
            bool due = now >= _nextSyncUtc;
            DateTime earliestSync = _lastSyncAttemptUtc + AgentConstants.MinSpacingBetweenSyncs;
            if ((_syncRequested || due) && now >= earliestSync && _vault.HasCredential)
            {
                await SyncOnceAsync(false, ct).ConfigureAwait(false);
            }

            now = _clock.UtcNow;
            DateTime nextSync = _syncRequested ? earliestSync : _nextSyncUtc;
            DateTime next = _nextHeartbeatUtc < nextSync ? _nextHeartbeatUtc : nextSync;
            await WaitAsync(next - now, ct).ConfigureAwait(false);
        }

        private async Task WaitAsync(TimeSpan delay, CancellationToken ct)
        {
            if (delay < TimeSpan.FromSeconds(1)) delay = TimeSpan.FromSeconds(1);
            if (delay > MaxWait) delay = MaxWait;
            await _wake.WaitAsync(delay, ct).ConfigureAwait(false);
        }

        private void Wake()
        {
            try
            {
                if (_wake.CurrentCount == 0) _wake.Release();
            }
            catch (SemaphoreFullException)
            {
                // já há um despertar pendente
            }
        }

        // ==========================================================================================================
        // Status
        // ==========================================================================================================

        public AgentStatusDto GetStatus()
        {
            lock (_stateLock)
            {
                AgentStatusDto dto = new AgentStatusDto();
                dto.Computador = _host.MachineName;
                dto.Versao = AgentConstants.AgentVersion;
                dto.Empresa = _state.CompanyName;
                dto.Estacao = _state.StationName;
                dto.UltimaComunicacaoUtc = _state.LastHeartbeatOkUtc;
                dto.UltimaSincronizacaoUtc = _state.LastSyncOkUtc;
                dto.ImpressorasAtivas = _state.LastSync != null ? (int?)_state.LastSync.Active : null;
                IPrintActivity? activity = PrintActivity;
                if (activity != null)
                {
                    PrintActivitySnapshot snap = activity.Snapshot();
                    dto.UltimaImpressao = snap.LastSuccess;
                    // erro só aparece enquanto for mais novo que a última impressão bem-sucedida
                    if (snap.LastFailure != null && (snap.LastSuccess == null || snap.LastFailure.EmUtc > snap.LastSuccess.EmUtc))
                    {
                        dto.UltimoErroImpressao = snap.LastFailure;
                    }
                }

                bool linked = _vault.HasCredential;
                dto.Vinculado = linked;

                if (_identityProblem != null)
                {
                    dto.Estado = AgentStatusKind.Erro;
                    dto.Mensagem = _identityProblem;
                    return dto;
                }

                if (!linked)
                {
                    dto.Empresa = null;
                    dto.Estacao = null;
                    dto.UltimaComunicacaoUtc = null;
                    dto.UltimaSincronizacaoUtc = null;
                    dto.ImpressorasAtivas = null;
                    if (_credentialStatus == CredentialLoadStatus.Corrupt || _credentialStatus == CredentialLoadStatus.Unreadable)
                    {
                        dto.Estado = AgentStatusKind.Erro;
                        dto.Mensagem = _state.LastError ?? (_credentialStatus == CredentialLoadStatus.Unreadable
                            ? AgentMessages.CredentialTemporarilyUnreadable
                            : AgentMessages.CredentialUnreadable);
                    }
                    else
                    {
                        dto.Estado = AgentStatusKind.NaoVinculado;
                    }
                }
                else if (_state.CredentialRejected)
                {
                    dto.Estado = AgentStatusKind.Erro;
                    dto.Mensagem = _state.LastError ?? AgentMessages.CredentialRejected;
                }
                else if (_state.LastError != null && !_state.LastContactFailed)
                {
                    dto.Estado = AgentStatusKind.Erro;
                    dto.Mensagem = _state.LastError;
                }
                else if (IsContactRecent())
                {
                    dto.Estado = AgentStatusKind.Conectado;
                    dto.Mensagem = _state.LastSyncError;
                }
                else
                {
                    dto.Estado = AgentStatusKind.SemConexao;
                    dto.Mensagem = _state.LastError ?? AgentMessages.WaitingFirstContact;
                }
                return dto;
            }
        }

        private bool IsContactRecent()
        {
            if (!_state.LastHeartbeatOkUtc.HasValue) return false;
            double window = Math.Max(_state.HeartbeatSeconds * 2.5, 60.0);
            return (_clock.UtcNow - _state.LastHeartbeatOkUtc.Value).TotalSeconds <= window;
        }

        public IReadOnlyList<PrinterInfo> GetPrinters()
        {
            lock (_stateLock)
            {
                return _lastPrinters.ToList();
            }
        }

        // ==========================================================================================================
        // Heartbeat
        // ==========================================================================================================

        public async Task HeartbeatOnceAsync(CancellationToken ct)
        {
            if (!await _gate.WaitAsync(GateTimeout, ct).ConfigureAwait(false))
            {
                _nextHeartbeatUtc = _clock.UtcNow + AgentConstants.BackoffStart;
                return;
            }
            try
            {
                AgentToken? token = ActiveToken();
                if (token == null) return;
                ApiResult<HeartbeatResponse> result = await _api.HeartbeatAsync(token, _installationId, AgentConstants.AgentVersion, ct).ConfigureAwait(false);
                HandleHeartbeat(result);
            }
            finally
            {
                _gate.Release();
            }
        }

        private void HandleHeartbeat(ApiResult<HeartbeatResponse> result)
        {
            DateTime now = _clock.UtcNow;
            bool saveNow = false;

            lock (_stateLock)
            {
                switch (result.Outcome)
                {
                    case ApiOutcome.Ok:
                    {
                        HeartbeatResponse hb = result.Data!;
                        _heartbeatFailures = 0;
                        bool hadProblem = _state.LastContactFailed || _state.CredentialRejected || _state.LastError != null;
                        _state.LastHeartbeatOkUtc = now;
                        _state.LastContactFailed = false;
                        _state.CredentialRejected = false;
                        _state.LastError = null;
                        if (!string.IsNullOrEmpty(hb.EstacaoNome) && hb.EstacaoNome != _state.StationName)
                        {
                            _state.StationName = hb.EstacaoNome;
                            saveNow = true;
                        }
                        int seconds = ClampHeartbeat(hb.HeartbeatSegundos ?? _state.HeartbeatSeconds);
                        _state.HeartbeatSeconds = seconds;
                        _nextHeartbeatUtc = now + Jitter(TimeSpan.FromSeconds(seconds));
                        if (hb.RenovarCredencial) _renewRequested = true;
                        if (hb.SincronizarAgora && (now - _lastServerRequestedSyncUtc) >= AgentConstants.MinSpacingBetweenServerRequestedSyncs)
                        {
                            _lastServerRequestedSyncUtc = now;
                            _syncRequested = true;
                        }
                        if (hadProblem) saveNow = true;
                        break;
                    }
                    case ApiOutcome.Unauthorized:
                        MarkCredentialRejected(result.ErrorCode);
                        _nextHeartbeatUtc = now + AgentConstants.CredentialRejectedRetry;
                        break;
                    case ApiOutcome.RateLimited:
                    {
                        TimeSpan wait = result.RetryAfter ?? TimeSpan.FromSeconds(60);
                        if (wait < TimeSpan.FromSeconds(30)) wait = TimeSpan.FromSeconds(30);
                        _state.LastContactFailed = true;
                        _state.LastError = AgentMessages.RateLimited;
                        _nextHeartbeatUtc = now + wait;
                        break;
                    }
                    case ApiOutcome.NetworkError:
                    case ApiOutcome.Timeout:
                    case ApiOutcome.ServerError:
                        _heartbeatFailures++;
                        _state.LastContactFailed = true;
                        _state.LastError = result.Outcome == ApiOutcome.ServerError ? AgentMessages.ServerUnavailable : AgentMessages.NoConnection;
                        _nextHeartbeatUtc = now + BackoffDelay(_heartbeatFailures);
                        break;
                    default:
                    {
                        _heartbeatFailures++;
                        _state.LastContactFailed = false;
                        _state.LastError = AgentMessages.Unexpected(result.HttpStatus);
                        TimeSpan wait = BackoffDelay(_heartbeatFailures);
                        if (wait < TimeSpan.FromSeconds(60)) wait = TimeSpan.FromSeconds(60);
                        _nextHeartbeatUtc = now + wait;
                        break;
                    }
                }
            }

            if (result.Outcome == ApiOutcome.Ok)
            {
                _log.LogInformation("Heartbeat OK.");
            }
            else
            {
                _log.LogWarning("Heartbeat falhou: {Resultado} (HTTP {Status}, {Codigo}).", result.Outcome, result.HttpStatus, result.ErrorCode ?? "-");
            }
            if (saveNow) SaveState(true); else SaveState(false);
        }

        private void MarkCredentialRejected(string? code)
        {
            // chamar dentro de lock (_stateLock)
            _state.CredentialRejected = true;
            _state.LastContactFailed = false;
            _state.LastError = AgentMessages.CredentialRejectedWith(code);
        }

        // ==========================================================================================================
        // Renovação de credencial
        // ==========================================================================================================

        public async Task RenewOnceAsync(CancellationToken ct)
        {
            _renewRequested = false; // se falhar, o próximo heartbeat pede de novo (o servidor continua sinalizando)
            if (!await _gate.WaitAsync(GateTimeout, ct).ConfigureAwait(false)) return;
            try
            {
                AgentToken? token = ActiveToken();
                if (token == null) return;

                ApiResult<RenewResponse> result = await _api.RenewAsync(token, _installationId, ct).ConfigureAwait(false);
                if (result.IsOk && result.Data != null)
                {
                    AgentToken renewed = result.Data.Token;
                    if (!string.Equals(renewed.AgentId, token.AgentId, StringComparison.Ordinal))
                    {
                        _log.LogError("A renovação devolveu outro identificador de agente; ignorada.");
                        return;
                    }
                    bool persisted = _vault.StageRenewed(renewed);
                    if (persisted)
                    {
                        _log.LogInformation("Credencial renovada e gravada com segurança.");
                    }
                    else
                    {
                        _log.LogError("Credencial renovada no servidor, mas a gravação local falhou; nova tentativa de gravação em seguida.");
                    }
                }
                else
                {
                    _log.LogWarning("Renovação de credencial não concluída: {Resultado} (HTTP {Status}, {Codigo}). A credencial atual foi mantida.",
                        result.Outcome, result.HttpStatus, result.ErrorCode ?? "-");
                }
            }
            finally
            {
                _gate.Release();
            }
        }

        // ==========================================================================================================
        // Descoberta e sincronização de impressoras
        // ==========================================================================================================

        public async Task<SyncAttemptResult> SyncOnceAsync(bool manual, CancellationToken ct)
        {
            SyncAttemptResult outcome = new SyncAttemptResult();
            if (!await _gate.WaitAsync(GateTimeout, ct).ConfigureAwait(false))
            {
                outcome.ErrorCode = "ocupado";
                outcome.Message = AgentMessages.Busy;
                return outcome;
            }

            try
            {
                outcome.Ran = true;
                _syncRequested = false;
                DateTime now = _clock.UtcNow;
                _lastSyncAttemptUtc = now;

                // 1) varredura das impressoras visíveis ao Service
                DiscoveryResult discovery = await DiscoverAsync(ct).ConfigureAwait(false);
                if (!discovery.Success)
                {
                    // FALHA TÉCNICA: nunca envia lista vazia (que significaria "varri e não achei nada")
                    string reason = discovery.Error ?? "falha desconhecida";
                    lock (_stateLock)
                    {
                        _state.LastSyncError = AgentMessages.DiscoveryFailed;
                    }
                    _nextSyncUtc = _clock.UtcNow + AgentConstants.SyncRetryAfterDiscoveryFailure;
                    _log.LogError("Falha ao detectar impressoras: {Motivo}", reason);
                    outcome.DiscoverySucceeded = false;
                    outcome.ErrorCode = "falha_descoberta";
                    outcome.Message = AgentMessages.DiscoveryFailed;
                    outcome.Printers = GetPrinters().ToList();
                    return outcome;
                }
                outcome.DiscoverySucceeded = true;

                // 2) união com as impressoras das sessões de usuário (Tray)
                bool truncated;
                List<PrinterInfo> merged = MergeWithUserPrinters(discovery.Printers, out truncated);
                if (truncated)
                {
                    _log.LogWarning("Há mais impressoras do que o limite aceito; apenas as primeiras {Limite} serão enviadas.", merged.Count);
                }
                lock (_stateLock)
                {
                    _lastPrinters = merged.ToList();
                }
                outcome.Printers = merged.ToList();

                AgentToken? token = ActiveToken();
                if (token == null)
                {
                    outcome.Message = _identityProblem ?? AgentMessages.NotLinkedScanOnly;
                    return outcome;
                }

                // 3) monta a requisição respeitando o limite de tamanho do contrato
                SyncRequest request = new SyncRequest();
                request.IdentificadorInstalacao = _installationId;
                request.VersaoAgente = AgentConstants.AgentVersion;
                request.NomeComputador = PrinterClassifier.CleanText(_host.MachineName, 120);
                request.SistemaOperacional = PrinterClassifier.CleanText(_host.OsDescription, 200);
                request.Impressoras = merged.ToList();
                while (request.Impressoras.Count > 0 && EdgeApiClient.MeasureSyncBody(request) > AgentConstants.MaxSyncBodyBytes)
                {
                    request.Impressoras.RemoveAt(request.Impressoras.Count - 1);
                }

                // 4) envio
                outcome.ServerCalled = true;
                ApiResult<SyncResponse> result = await _api.SyncAsync(token, request, ct).ConfigureAwait(false);
                HandleSyncResult(result, request.Impressoras.Count, outcome);
                return outcome;
            }
            finally
            {
                _gate.Release();
            }
        }

        private void HandleSyncResult(ApiResult<SyncResponse> result, int sentCount, SyncAttemptResult outcome)
        {
            DateTime now = _clock.UtcNow;
            bool persist = false;

            lock (_stateLock)
            {
                switch (result.Outcome)
                {
                    case ApiOutcome.Ok:
                    {
                        SyncResponse r = result.Data!;
                        SyncSummary summary = new SyncSummary();
                        summary.Received = r.Recebidas;
                        summary.Valid = r.Validas;
                        summary.Rejected = r.Rejeitadas;
                        summary.New = r.Novas;
                        summary.Changed = r.Alteradas;
                        summary.Deactivated = r.Desativadas;
                        summary.Active = r.Ativas;
                        _state.LastSync = summary;
                        _state.LastSyncOkUtc = now;
                        _state.LastSyncError = null;
                        _syncFailures = 0;
                        _nextSyncUtc = now + Jitter(AgentConstants.SyncInterval);
                        outcome.Synced = true;
                        outcome.Summary = summary;
                        persist = true;
                        break;
                    }
                    case ApiOutcome.Unauthorized:
                        MarkCredentialRejected(result.ErrorCode);
                        _state.LastSyncError = AgentMessages.SyncNotSent;
                        _nextSyncUtc = now + AgentConstants.CredentialRejectedRetry;
                        outcome.ErrorCode = "credencial_recusada";
                        outcome.Message = AgentMessages.CredentialRejected;
                        break;
                    case ApiOutcome.RateLimited:
                    {
                        TimeSpan wait = result.RetryAfter ?? TimeSpan.FromSeconds(60);
                        if (wait < TimeSpan.FromSeconds(60)) wait = TimeSpan.FromSeconds(60);
                        _state.LastSyncError = AgentMessages.SyncNotSent;
                        _nextSyncUtc = now + wait;
                        outcome.ErrorCode = "muitas_tentativas";
                        outcome.Message = AgentMessages.RateLimited;
                        break;
                    }
                    case ApiOutcome.NetworkError:
                    case ApiOutcome.Timeout:
                    case ApiOutcome.ServerError:
                        _syncFailures++;
                        _state.LastSyncError = AgentMessages.SyncNotSent;
                        _nextSyncUtc = now + BackoffDelay(_syncFailures);
                        outcome.ErrorCode = result.Outcome == ApiOutcome.ServerError ? "servidor_indisponivel" : "sem_conexao";
                        outcome.Message = result.Outcome == ApiOutcome.ServerError ? AgentMessages.ServerUnavailable : AgentMessages.NoConnection;
                        break;
                    case ApiOutcome.Rejected:
                        _state.LastSyncError = AgentMessages.SyncRejected(result.ErrorCode);
                        _nextSyncUtc = now + AgentConstants.SyncInterval;
                        outcome.ErrorCode = result.ErrorCode ?? "recusado";
                        outcome.Message = _state.LastSyncError;
                        break;
                    default:
                        _syncFailures++;
                        _state.LastSyncError = AgentMessages.Unexpected(result.HttpStatus);
                        _nextSyncUtc = now + BackoffDelay(_syncFailures);
                        outcome.ErrorCode = "resposta_invalida";
                        outcome.Message = _state.LastSyncError;
                        break;
                }
            }

            if (result.Outcome == ApiOutcome.Ok)
            {
                _log.LogInformation("Sincronização OK: {Enviadas} impressora(s) enviada(s), {Ativas} ativa(s) no servidor.", sentCount, result.Data!.Ativas);
            }
            else
            {
                _log.LogWarning("Sincronização falhou: {Resultado} (HTTP {Status}, {Codigo}).", result.Outcome, result.HttpStatus, result.ErrorCode ?? "-");
            }
            if (persist) SaveState(true);
        }

        private async Task<DiscoveryResult> DiscoverAsync(CancellationToken ct)
        {
            int generation;
            lock (_discoveryLock)
            {
                DateTime now = _clock.UtcNow;
                if (_discoveryRunning && (now - _discoveryStartedUtc) < DiscoveryStuckAfter)
                {
                    return DiscoveryResult.Fail("uma detecção anterior ainda está em andamento");
                }
                _discoveryRunning = true;
                _discoveryStartedUtc = now;
                _discoveryGeneration++;
                generation = _discoveryGeneration;
            }

            Task<DiscoveryResult> work = Task.Run(() =>
            {
                try
                {
                    return _discovery.Discover();
                }
                catch (Exception ex)
                {
                    return DiscoveryResult.Fail("exceção na detecção (" + ex.GetType().Name + ")");
                }
                finally
                {
                    lock (_discoveryLock)
                    {
                        if (_discoveryGeneration == generation) _discoveryRunning = false;
                    }
                }
            });

            Task finished = await Task.WhenAny(work, Task.Delay(AgentConstants.DiscoveryTimeout, ct)).ConfigureAwait(false);
            if (!ReferenceEquals(finished, work))
            {
                ct.ThrowIfCancellationRequested();
                return DiscoveryResult.Fail("tempo esgotado (o spooler de impressão pode estar parado ou lento)");
            }
            return await work.ConfigureAwait(false);
        }

        private List<PrinterInfo> MergeWithUserPrinters(IReadOnlyList<PrinterInfo> servicePrinters, out bool truncated)
        {
            List<IEnumerable<PrinterInfo>> userLists = new List<IEnumerable<PrinterInfo>>();
            int limit;
            lock (_stateLock)
            {
                PurgeExpiredUserLists(_clock.UtcNow);
                foreach (UserPrinterList l in _state.UserPrinters)
                {
                    userLists.Add(l.Printers.ToList());
                }
                limit = Math.Min(_state.PrinterLimit, AgentConstants.MaxPrintersPerSync);
            }
            return PrinterMerger.Merge(servicePrinters, userLists, limit, out truncated);
        }

        private void PurgeExpiredUserLists(DateTime now)
        {
            // chamar dentro de lock (_stateLock)
            _state.UserPrinters.RemoveAll(l => (now - l.UpdatedUtc) > AgentConstants.UserPrintersMaxAge);
        }

        public async Task<ControllerResult> ScanPrintersAsync(CancellationToken ct)
        {
            // Um usuário local pode pedir a busca à vontade: limita a frequência para não forçar descoberta + HTTPS em laço.
            lock (_stateLock)
            {
                DateTime nowScan = _clock.UtcNow;
                if (_lastManualScanUtc != DateTime.MinValue && nowScan >= _lastManualScanUtc && (nowScan - _lastManualScanUtc) < AgentConstants.MinSpacingBetweenManualScans)
                    return ControllerResult.Fail("muitas_tentativas", AgentMessages.ScanTooSoon);
                _lastManualScanUtc = nowScan;
            }

            SyncAttemptResult r = await SyncOnceAsync(true, ct).ConfigureAwait(false);
            if (!r.Ran)
                return ControllerResult.Fail("ocupado", AgentMessages.Busy);
            if (!r.DiscoverySucceeded)
                return ControllerResult.Fail("falha_descoberta", AgentMessages.DiscoveryFailed);

            ScanResultDto dto = new ScanResultDto();
            dto.Impressoras = r.Printers;
            dto.Sincronizado = r.Synced;
            dto.Resumo = r.Summary;

            string? message = null;
            if (!r.Synced) message = r.Message;
            return ControllerResult.Success(dto, message);
        }

        // ==========================================================================================================
        // Impressoras da sessão do usuário (Tray)
        // ==========================================================================================================

        public ControllerResult SubmitUserPrinters(string session, IReadOnlyList<PrinterInfo> printers)
        {
            DateTime now = _clock.UtcNow;
            string hash = HashPrinters(printers);
            bool changed;

            lock (_stateLock)
            {
                UserPrinterList? existing = _state.UserPrinters.FirstOrDefault(l => string.Equals(l.Session, session, StringComparison.OrdinalIgnoreCase));
                if (existing == null)
                {
                    if (_state.UserPrinters.Count >= AgentConstants.MaxUserSessions)
                    {
                        UserPrinterList oldest = _state.UserPrinters.OrderBy(l => l.UpdatedUtc).First();
                        _state.UserPrinters.Remove(oldest);
                    }
                    existing = new UserPrinterList();
                    existing.Session = session;
                    _state.UserPrinters.Add(existing);
                    changed = true;
                }
                else
                {
                    changed = !string.Equals(existing.Hash, hash, StringComparison.Ordinal);
                }
                existing.Hash = hash;
                existing.UpdatedUtc = now;
                existing.Printers = printers.Select(p => p.Clone()).ToList();
            }

            if (changed)
            {
                _log.LogInformation("O Tray enviou uma lista nova de impressoras da sessão do usuário ({Quantidade}).", printers.Count);
                SaveState(true);
                _syncRequested = true;
                Wake();
            }
            else
            {
                SaveState(false);
            }
            return ControllerResult.Success(null);
        }

        internal static string HashPrinters(IReadOnlyList<PrinterInfo> printers)
        {
            StringBuilder sb = new StringBuilder();
            foreach (PrinterInfo p in printers.OrderBy(x => x.Identificador, StringComparer.Ordinal))
            {
                sb.Append(p.Identificador).Append('|').Append(p.Nome).Append('|').Append(p.Conexao).Append('|')
                  .Append(p.Ip ?? string.Empty).Append('|')
                  .Append(p.Porta.HasValue ? p.Porta.Value.ToString(System.Globalization.CultureInfo.InvariantCulture) : string.Empty).Append('|')
                  .Append(p.PortaWindows ?? string.Empty).Append('|').Append(p.Status).Append('\n');
            }
            byte[] hash = SHA256.HashData(Encoding.UTF8.GetBytes(sb.ToString()));
            return Convert.ToHexString(hash).ToLowerInvariant();
        }

        // ==========================================================================================================
        // Pareamento
        // ==========================================================================================================

        public async Task<ControllerResult> VerifyPairingAsync(string normalizedCode, CallerIdentity caller, CancellationToken ct)
        {
            if (_identityProblem != null)
                return ControllerResult.Fail("identidade_invalida", _identityProblem);
            if (_vault.HasCredential)
                return ControllerResult.Fail("ja_vinculado", AgentMessages.AlreadyLinked);

            lock (_stateLock)
            {
                if (_credentialStatus == CredentialLoadStatus.Unreadable)
                    return ControllerResult.Fail("credencial_ilegivel", AgentMessages.CredentialTemporarilyUnreadable);
                DropExpiredPairing();
                if (_pendingPairing != null && !string.Equals(_pendingPairing.OwnerKey, caller.Key, StringComparison.Ordinal))
                    return ControllerResult.Fail("pareamento_em_andamento", AgentMessages.PairingInProgress);
            }

            ApiResult<PairVerifyResponse> result = await _api.PairVerifyAsync(normalizedCode, ct).ConfigureAwait(false);
            if (!result.IsOk || result.Data == null)
            {
                lock (_stateLock)
                {
                    // uma verificação nova que falhou invalida a anterior do MESMO chamador (nunca a de outro)
                    if (_pendingPairing != null && string.Equals(_pendingPairing.OwnerKey, caller.Key, StringComparison.Ordinal))
                        _pendingPairing = null;
                }
                _log.LogInformation("Verificação do código de pareamento não aceita: {Resultado} ({Codigo}).", result.Outcome, result.ErrorCode ?? "-");
                return MapFailure(result.Outcome, result.HttpStatus, result.ErrorCode);
            }

            lock (_stateLock)
            {
                // outro chamador pode ter concluído uma verificação enquanto esta esperava o servidor
                if (_vault.HasCredential)
                    return ControllerResult.Fail("ja_vinculado", AgentMessages.AlreadyLinked);
                DropExpiredPairing();
                if (_pendingPairing != null && !string.Equals(_pendingPairing.OwnerKey, caller.Key, StringComparison.Ordinal))
                    return ControllerResult.Fail("pareamento_em_andamento", AgentMessages.PairingInProgress);

                PendingPairing pending = new PendingPairing();
                pending.Code = normalizedCode;
                pending.OwnerKey = caller.Key;
                pending.ExpiresUtc = _clock.UtcNow + AgentConstants.PairingVerifyTtl;
                _pendingPairing = pending;
            }

            PairingPreviewDto dto = new PairingPreviewDto();
            dto.Empresa = result.Data.EmpresaNome;
            dto.Estacao = result.Data.EstacaoNome;
            dto.Reinstalacao = result.Data.Reinstalacao;
            return ControllerResult.Success(dto);
        }

        // chamar com _stateLock
        private void DropExpiredPairing()
        {
            if (_pendingPairing != null && _clock.UtcNow >= _pendingPairing.ExpiresUtc)
                _pendingPairing = null;
        }

        public async Task<ControllerResult> ConfirmPairingAsync(string normalizedCode, CallerIdentity caller, CancellationToken ct)
        {
            if (!await _gate.WaitAsync(GateTimeout, ct).ConfigureAwait(false))
                return ControllerResult.Fail("ocupado", AgentMessages.Busy);
            try
            {
                if (_identityProblem != null)
                    return ControllerResult.Fail("identidade_invalida", _identityProblem);
                if (_vault.HasCredential)
                    return ControllerResult.Fail("ja_vinculado", AgentMessages.AlreadyLinked);

                lock (_stateLock)
                {
                    if (_credentialStatus == CredentialLoadStatus.Unreadable)
                        return ControllerResult.Fail("credencial_ilegivel", AgentMessages.CredentialTemporarilyUnreadable);

                    // só confirma o que ESTE chamador (usuário + sessão do Windows) verificou há pouco, com o MESMO código
                    DropExpiredPairing();
                    PendingPairing? pending = _pendingPairing;
                    if (pending == null
                        || !string.Equals(pending.OwnerKey, caller.Key, StringComparison.Ordinal)
                        || !string.Equals(pending.Code, normalizedCode, StringComparison.Ordinal))
                    {
                        return ControllerResult.Fail("pareamento_nao_verificado", AgentMessages.PairingNotVerified);
                    }
                }

                PairConfirmRequest request = new PairConfirmRequest();
                request.Codigo = normalizedCode;
                request.IdentificadorInstalacao = _installationId;
                request.NomeComputador = PrinterClassifier.CleanText(_host.MachineName, 120);
                request.SistemaOperacional = PrinterClassifier.CleanText(_host.OsDescription, 200);
                request.VersaoAgente = AgentConstants.AgentVersion;

                ApiResult<PairConfirmResponse> result = await _api.PairConfirmAsync(request, ct).ConfigureAwait(false);
                if (!result.IsOk || result.Data == null)
                {
                    _log.LogWarning("Pareamento não concluído: {Resultado} (HTTP {Status}, {Codigo}).", result.Outcome, result.HttpStatus, result.ErrorCode ?? "-");
                    if (result.Outcome == ApiOutcome.Rejected || result.Outcome == ApiOutcome.Unauthorized)
                    {
                        // recusa definitiva do servidor: é preciso verificar de novo. Falha de rede/servidor mantém a verificação (nova tentativa).
                        lock (_stateLock) { _pendingPairing = null; }
                    }
                    return MapFailure(result.Outcome, result.HttpStatus, result.ErrorCode);
                }

                PairConfirmResponse data = result.Data;
                try
                {
                    _vault.SetInitial(data.Token); // protege (DPAPI) e grava de forma atômica ANTES de usar
                }
                catch (Exception ex)
                {
                    _log.LogError("O servidor aceitou o pareamento, mas a credencial não pôde ser gravada neste computador ({Tipo}).", ex.GetType().Name);
                    return ControllerResult.Fail("falha_credencial", AgentMessages.CredentialSaveFailed);
                }

                DateTime now = _clock.UtcNow;
                lock (_stateLock)
                {
                    _credentialStatus = CredentialLoadStatus.Ok;
                    _state.CompanyName = data.EmpresaNome;
                    _state.StationName = data.EstacaoNome;
                    _state.PairedUtc = now;
                    _state.PairedBySid = caller.Sid;
                    _pendingPairing = null;
                    _state.HeartbeatSeconds = ClampHeartbeat(data.HeartbeatSegundos ?? AgentConstants.DefaultHeartbeatSeconds);
                    int limit = data.LimiteImpressoras ?? AgentConstants.MaxPrintersPerSync;
                    _state.PrinterLimit = Math.Max(1, Math.Min(limit, AgentConstants.MaxPrintersPerSync));
                    _state.CredentialRejected = false;
                    _state.LastContactFailed = false;
                    _state.LastError = null;
                    _state.LastSyncError = null;
                    _state.LastHeartbeatOkUtc = null;
                    _state.LastSyncOkUtc = null;
                    _state.LastSync = null;
                }
                SaveState(true);

                _heartbeatFailures = 0;
                _syncFailures = 0;
                _renewRequested = false;
                _syncRequested = true; // heartbeat -> descoberta -> sincronização, nesta ordem, no laço
                _nextHeartbeatUtc = now;
                _nextSyncUtc = now;
                _lastSyncAttemptUtc = DateTime.MinValue;
                Wake();

                _log.LogInformation("Pareamento concluído. Reinstalação: {Reinstalacao}.", data.Reinstalacao);
                return ControllerResult.Success(GetStatus());
            }
            finally
            {
                _gate.Release();
            }
        }

        // ==========================================================================================================
        // Desvinculação
        // ==========================================================================================================

        /// <summary>
        /// Quem pode desvincular: a conta SYSTEM, um Administrador com token elevado, ou o MESMO usuário que conectou este
        /// computador. Qualquer outro usuário local interativo é recusado ANTES de qualquer chamada ao servidor.
        /// </summary>
        private bool CanUnlink(CallerIdentity caller)
        {
            if (caller.IsSystem || caller.IsAdministrator) return true;
            lock (_stateLock)
            {
                return caller.SameUser(_state.PairedBySid);
            }
        }

        public async Task<ControllerResult> UnlinkAsync(bool force, CallerIdentity caller, CancellationToken ct)
        {
            if (!await _gate.WaitAsync(GateTimeout, ct).ConfigureAwait(false))
                return ControllerResult.Fail("ocupado", AgentMessages.Busy);
            try
            {
                // Identidade da instalação ausente/corrompida COM vínculo existente: o servidor não pode ser consultado
                // (nenhuma identidade nova foi criada). O único caminho é a remoção local explícita, por quem pode.
                if (_identityProblem != null)
                {
                    if (!CanUnlink(caller))
                    {
                        _log.LogWarning("Remoção do vínculo negada: usuário local sem permissão.");
                        return ControllerResult.Fail("acesso_negado", AgentMessages.UnlinkNotAllowed);
                    }
                    if (!force)
                        return ControllerResult.Fail("identidade_invalida", _identityProblem);
                    return ClearLocalLink("Vínculo removido apenas deste computador (a identificação da instalação estava inválida).");
                }

                AgentToken? token = _vault.GetActive();
                if (token == null)
                {
                    lock (_stateLock)
                    {
                        if (_credentialStatus == CredentialLoadStatus.Unreadable)
                            return ControllerResult.Fail("credencial_ilegivel", AgentMessages.CredentialTemporarilyUnreadable);
                    }
                    return ControllerResult.Fail("nao_vinculado", AgentMessages.NotLinked);
                }

                if (!CanUnlink(caller))
                {
                    _log.LogWarning("Desvinculação negada: usuário local sem permissão.");
                    return ControllerResult.Fail("acesso_negado", AgentMessages.UnlinkNotAllowed);
                }

                if (force)
                {
                    bool allowed;
                    lock (_stateLock)
                    {
                        allowed = _state.CredentialRejected;
                    }
                    if (!allowed)
                        return ControllerResult.Fail("forca_nao_permitida", AgentMessages.ForceNotAllowed);
                    return ClearLocalLink("Vínculo removido apenas deste computador (o servidor já não o reconhecia).");
                }

                ApiResult<EmptyResponse> result = await _api.UnlinkAsync(token, _installationId, ct).ConfigureAwait(false);
                if (result.IsOk)
                {
                    return ClearLocalLink("Computador desvinculado.");
                }

                if (result.Outcome == ApiOutcome.Unauthorized)
                {
                    lock (_stateLock)
                    {
                        MarkCredentialRejected(result.ErrorCode);
                    }
                    _log.LogWarning("O servidor não reconhece mais este vínculo ({Codigo}).", result.ErrorCode ?? "-");
                    return ControllerResult.Fail("credencial_recusada", AgentMessages.UnlinkRejected);
                }

                // servidor indisponível ou outra falha: NÃO finge que desvinculou
                _log.LogWarning("Desvinculação não concluída: {Resultado} (HTTP {Status}, {Codigo}). O vínculo foi mantido.", result.Outcome, result.HttpStatus, result.ErrorCode ?? "-");
                return MapFailure(result.Outcome, result.HttpStatus, result.ErrorCode);
            }
            finally
            {
                _gate.Release();
            }
        }

        private ControllerResult ClearLocalLink(string logMessage)
        {
            try
            {
                _vault.Clear(); // apaga a credencial protegida; a identidade da instalação é mantida
            }
            catch (Exception ex)
            {
                _log.LogError("Não foi possível apagar a credencial local ({Tipo}).", ex.GetType().Name);
                return ControllerResult.Fail("falha_apagar_credencial", AgentMessages.CredentialDeleteFailed);
            }

            lock (_stateLock)
            {
                _credentialStatus = CredentialLoadStatus.Missing;
                _state.PairedBySid = null;
                _pendingPairing = null;
                _state.CompanyName = null;
                _state.StationName = null;
                _state.PairedUtc = null;
                _state.LastHeartbeatOkUtc = null;
                _state.LastSyncOkUtc = null;
                _state.LastSync = null;
                _state.CredentialRejected = false;
                _state.LastContactFailed = false;
                _state.LastError = null;
                _state.LastSyncError = null;
                _lastPrinters = new List<PrinterInfo>();
            }
            _renewRequested = false;
            _syncRequested = false;
            _heartbeatFailures = 0;
            _syncFailures = 0;
            if (_identityProblem != null) TryRecoverIdentity(); // sem vínculo, a identificação pode ser recriada com segurança
            SaveState(true);
            Wake();
            _log.LogInformation("{Mensagem}", logMessage);
            return ControllerResult.Success(GetStatus(), logMessage);
        }

        // ==========================================================================================================
        // Utilidades
        // ==========================================================================================================

        private ControllerResult MapFailure(ApiOutcome outcome, int httpStatus, string? code)
        {
            switch (outcome)
            {
                case ApiOutcome.Rejected:
                    return ControllerResult.Fail(code ?? "recusado", AgentMessages.Rejected(code));
                case ApiOutcome.Unauthorized:
                    return ControllerResult.Fail("credencial_recusada", AgentMessages.CredentialRejected);
                case ApiOutcome.RateLimited:
                    return ControllerResult.Fail("muitas_tentativas", AgentMessages.RateLimited);
                case ApiOutcome.ServerError:
                    return ControllerResult.Fail("servidor_indisponivel", AgentMessages.ServerUnavailable);
                case ApiOutcome.NetworkError:
                    return ControllerResult.Fail("sem_conexao", AgentMessages.NoConnection);
                case ApiOutcome.Timeout:
                    return ControllerResult.Fail("tempo_esgotado", AgentMessages.Timeout);
                default:
                    return ControllerResult.Fail("resposta_invalida", AgentMessages.Unexpected(httpStatus));
            }
        }

        internal static int ClampHeartbeat(int seconds)
        {
            if (seconds < AgentConstants.MinHeartbeatSeconds) return AgentConstants.MinHeartbeatSeconds;
            if (seconds > AgentConstants.MaxHeartbeatSeconds) return AgentConstants.MaxHeartbeatSeconds;
            return seconds;
        }

        /// <summary>Aplica ±10% de jitter ao intervalo (evita todos os clientes chamarem no mesmo instante).</summary>
        internal TimeSpan Jitter(TimeSpan interval)
        {
            double factor = 1.0 + (((RandomSource() * 2.0) - 1.0) * AgentConstants.JitterFraction);
            return TimeSpan.FromSeconds(interval.TotalSeconds * factor);
        }

        /// <summary>Backoff exponencial limitado (15 s, 30 s, 60 s, 120 s, 240 s, depois 5 min), com jitter.</summary>
        internal TimeSpan BackoffDelay(int failures)
        {
            double seconds = AgentConstants.BackoffStart.TotalSeconds * Math.Pow(2.0, Math.Max(0, failures - 1));
            if (seconds > AgentConstants.BackoffCap.TotalSeconds) seconds = AgentConstants.BackoffCap.TotalSeconds;
            return Jitter(TimeSpan.FromSeconds(seconds));
        }

        internal DateTime NextHeartbeatUtc
        {
            get { return _nextHeartbeatUtc; }
        }

        internal DateTime NextSyncUtc
        {
            get { return _nextSyncUtc; }
        }

        internal bool SyncRequested
        {
            get { return _syncRequested; }
        }

        internal bool RenewRequested
        {
            get { return _renewRequested; }
        }

        private void SaveState(bool force)
        {
            DateTime now = _clock.UtcNow;
            lock (_stateLock)
            {
                if (!force && (now - _lastStateSaveUtc) < StateSaveThrottle) return;
                try
                {
                    _stateStore.Save(_state);
                    _lastStateSaveUtc = now;
                }
                catch (Exception ex)
                {
                    _log.LogWarning("Não foi possível gravar o estado local ({Tipo}).", ex.GetType().Name);
                }
            }
        }
    }

    /// <summary>Mensagens para o usuário (português do Brasil). Nunca incluem token, código ou dados sensíveis.</summary>
    internal static class AgentMessages
    {
        public const string CredentialTemporarilyUnreadable = "A credencial salva neste computador não pôde ser lida agora. O vínculo não foi perdido; uma nova tentativa será feita automaticamente.";
        public const string CredentialUnreadable = "A credencial salva neste computador não pôde ser lida. Conecte este computador ao Florest ERP novamente.";
        public const string CredentialRejected = "O servidor recusou a credencial deste computador. Desvincule e conecte novamente ao Florest ERP.";
        public const string WaitingFirstContact = "Aguardando comunicação com o servidor.";
        public const string RateLimited = "O servidor pediu para aguardar antes de novas tentativas.";
        public const string ServerUnavailable = "O servidor está temporariamente indisponível. Nova tentativa automática em instantes.";
        public const string NoConnection = "Sem conexão com o servidor. Verifique a internet; nova tentativa automática em instantes.";
        public const string Timeout = "O servidor demorou para responder. Tente novamente.";
        public const string PairingInProgress = "Outro usuário deste computador está conectando ao Florest ERP neste momento. Aguarde alguns minutos e tente novamente.";
        public const string PairingNotVerified = "Este pareamento não foi verificado por esta sessão (ou a verificação expirou). Digite o código novamente e clique em Verificar.";
        public const string UnlinkNotAllowed = "Somente quem conectou este computador ao Florest ERP, ou um Administrador (abra o Tray como administrador), pode desvincular.";
        public const string ScanTooSoon = "A busca de impressoras acabou de ser feita. Aguarde alguns segundos e tente novamente.";
        public const string Busy = "O agente está ocupado com outra operação. Tente novamente em instantes.";
        public const string AlreadyLinked = "Este computador já está vinculado. Desvincule antes de conectar a outra empresa.";
        public const string NotLinked = "Este computador não está vinculado.";
        public const string NotLinkedScanOnly = "Impressoras detectadas neste computador. Elas só serão enviadas depois de conectar ao Florest ERP.";
        public const string DiscoveryFailed = "Não foi possível detectar as impressoras agora (o serviço de impressão do Windows pode estar parado). Nada foi alterado no servidor.";
        public const string SyncNotSent = "As impressoras não foram enviadas ao servidor; nova tentativa automática em instantes.";
        public const string CredentialSaveFailed = "O servidor aceitou o código, mas não foi possível salvar a credencial neste computador. Gere um novo código no Florest ERP e tente de novo.";
        public const string CredentialDeleteFailed = "O servidor desvinculou este computador, mas não foi possível apagar a credencial local. Execute o programa como administrador e tente novamente.";
        public const string ForceNotAllowed = "A remoção apenas local só é permitida quando o servidor já não reconhece este vínculo.";
        public const string UnlinkRejected = "O servidor não reconhece mais este vínculo. Você pode remover o vínculo apenas deste computador.";

        public static string Unexpected(int httpStatus)
        {
            string hint = (httpStatus == 401 || httpStatus == 404)
                ? " Verifique se a função do servidor está publicada com a verificação de JWT desligada."
                : string.Empty;
            return "Resposta inesperada do servidor (HTTP " + httpStatus.ToString(System.Globalization.CultureInfo.InvariantCulture) + ")." + hint;
        }

        public static string CredentialRejectedWith(string? code)
        {
            if (string.IsNullOrEmpty(code)) return CredentialRejected;
            return "O servidor recusou a credencial deste computador (" + code + "). Desvincule e conecte novamente ao Florest ERP.";
        }

        public static string Rejected(string? code)
        {
            switch (code)
            {
                case "codigo_invalido": return "Código de pareamento inválido ou expirado.";
                case "instalacao_ja_vinculada": return "Esta instalação já está vinculada a outra estação.";
                case "limite_estacoes": return "O limite de estações da empresa foi atingido.";
                case "conflito": return "Conflito temporário no servidor. Tente novamente.";
                case "dados_invalidos": return "O servidor considerou os dados inválidos.";
                case "payload_grande":
                case "limite_excedido": return "A solicitação excede o limite aceito pelo servidor.";
                default: return "O servidor recusou a solicitação.";
            }
        }

        public static string SyncRejected(string? code)
        {
            switch (code)
            {
                case "limite_impressoras_estacao": return "O servidor recusou a lista: limite de impressoras desta estação excedido.";
                case "limite_excedido": return "O servidor recusou a lista: limite de tamanho excedido.";
                case "payload_invalido": return "O servidor recusou a lista de impressoras (formato inválido).";
                default: return "O servidor recusou a lista de impressoras.";
            }
        }
    }
}
