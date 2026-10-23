using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using FlorestPrintAgent.Core;
using FlorestPrintAgent.Core.Agent;
using FlorestPrintAgent.Core.Api;
using FlorestPrintAgent.Core.Printers;
using FlorestPrintAgent.Core.Security;
using FlorestPrintAgent.Core.Storage;
using Microsoft.Extensions.Logging;

namespace FlorestPrintAgent.Tests.TestSupport
{
    /// <summary>Pasta temporária apagada ao final do teste.</summary>
    internal sealed class TempDir : IDisposable
    {
        public string Path { get; }

        public TempDir()
        {
            Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "fpa-tests-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(Path);
        }

        public string File(string name)
        {
            return System.IO.Path.Combine(Path, name);
        }

        public void Dispose()
        {
            try
            {
                Directory.Delete(Path, true);
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }
    }

    internal sealed class FakeClock : IClock
    {
        public DateTime UtcNow { get; set; } = new DateTime(2026, 10, 5, 12, 0, 0, DateTimeKind.Utc);

        public void Advance(TimeSpan span)
        {
            UtcNow = UtcNow + span;
        }
    }

    /// <summary>Protetor de teste (não é criptografia): ofusca os bytes e acrescenta um byte de verificação.</summary>
    internal sealed class FakeSecretProtector : ISecretProtector
    {
        public byte[] Protect(byte[] plain)
        {
            byte[] result = new byte[plain.Length + 1];
            byte sum = 0;
            for (int i = 0; i < plain.Length; i++)
            {
                result[i] = (byte)(plain[i] ^ 0x5A);
                sum = (byte)(sum + plain[i]);
            }
            result[plain.Length] = sum;
            return result;
        }

        public byte[] Unprotect(byte[] protectedData)
        {
            if (protectedData.Length < 2) throw new CryptographicException("blob inválido");
            byte[] plain = new byte[protectedData.Length - 1];
            byte sum = 0;
            for (int i = 0; i < plain.Length; i++)
            {
                plain[i] = (byte)(protectedData[i] ^ 0x5A);
                sum = (byte)(sum + plain[i]);
            }
            if (sum != protectedData[protectedData.Length - 1]) throw new CryptographicException("blob adulterado");
            return plain;
        }
    }

    /// <summary>Armazém de credencial que pode falhar ao gravar e permite observar o momento da gravação.</summary>
    internal sealed class ControllableCredentialStore : ICredentialStore
    {
        private readonly ICredentialStore _inner;
        public bool FailSaves { get; set; }
        public int SaveCount { get; private set; }
        public Action<AgentToken>? BeforeSave { get; set; }
        /// <summary>Se definido, substitui o resultado do Load (simula erro transitório de leitura).</summary>
        public Func<CredentialLoadResult?>? LoadOverride { get; set; }

        public ControllableCredentialStore(ICredentialStore inner)
        {
            _inner = inner;
        }

        public CredentialLoadResult Load()
        {
            if (LoadOverride != null)
            {
                CredentialLoadResult? forced = LoadOverride();
                if (forced != null) return forced;
            }
            return _inner.Load();
        }

        public void Save(AgentToken token)
        {
            SaveCount++;
            if (BeforeSave != null) BeforeSave(token);
            if (FailSaves) throw new IOException("falha simulada de gravação");
            _inner.Save(token);
        }

        public void Delete()
        {
            _inner.Delete();
        }
    }

    internal static class TestTokens
    {
        private const string B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-";

        /// <summary>Token válido no formato real (fpa_uuid.43 caracteres). O mesmo número gera o mesmo agente.</summary>
        public static AgentToken Make(int agent, int version)
        {
            string id = new Guid(agent, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10).ToString("D");
            char[] secret = new char[43];
            for (int i = 0; i < secret.Length; i++) secret[i] = B64[(i * 7 + version * 13 + agent) % B64.Length];
            string raw = "fpa_" + id + "." + new string(secret);
            AgentToken? token;
            if (!TokenParser.TryParse(raw, out token) || token == null) throw new InvalidOperationException("token de teste inválido");
            return token;
        }

        public static AgentToken Make(int agent)
        {
            return Make(agent, 1);
        }
    }

    internal static class Samples
    {
        public static PrinterInfo Printer(string name, string connection, string status, string? ip, int? port, string? windowsPort)
        {
            PrinterInfo p = new PrinterInfo();
            p.Identificador = PrinterIdentifier.Compute(name, windowsPort, null, null);
            p.Nome = name;
            p.Conexao = connection;
            p.Ip = ip;
            p.Porta = port;
            p.PortaWindows = windowsPort;
            p.Status = status;
            return p;
        }

        public static PrinterInfo Usb(string name)
        {
            return Printer(name, PrinterConnection.Usb, PrinterStatus.Disponivel, null, null, "USB001");
        }

        public static RawPrinter Raw(string name, string port, string driver)
        {
            RawPrinter r = new RawPrinter();
            r.Name = name;
            r.PortName = port;
            r.DriverName = driver;
            return r;
        }
    }

    internal sealed class FakeDiscovery : IPrinterDiscovery
    {
        public DiscoveryResult Result { get; set; } = DiscoveryResult.Ok(new List<PrinterInfo>());
        public int Calls;

        public DiscoveryResult Discover()
        {
            Interlocked.Increment(ref Calls);
            return Result;
        }
    }

    /// <summary>Servidor falso: respostas configuráveis, registro das chamadas e medição de concorrência.</summary>
    internal sealed class FakeEdgeApi : IEdgeApi
    {
        private readonly object _lock = new object();
        private int _inFlight;

        public int MaxInFlight { get; private set; }
        public int VerifyCalls;
        public int ConfirmCalls;
        public int HeartbeatCalls;
        public int SyncCalls;
        public int RenewCalls;
        public int UnlinkCalls;

        public List<string> HeartbeatTokens { get; } = new List<string>();
        public List<string> RenewTokens { get; } = new List<string>();
        public List<string> SyncTokens { get; } = new List<string>();
        public List<string> UnlinkTokens { get; } = new List<string>();
        public List<SyncRequest> SyncRequests { get; } = new List<SyncRequest>();
        public List<PairConfirmRequest> ConfirmRequests { get; } = new List<PairConfirmRequest>();
        public List<string> VerifiedCodes { get; } = new List<string>();
        /// <summary>identificador_instalacao recebido em heartbeat/renew/unlink (para provar qual identidade foi usada).</summary>
        public List<string> InstallationIdsSeen { get; } = new List<string>();

        public Func<CancellationToken, Task<ApiResult<PairVerifyResponse>>> OnVerify { get; set; }
        public Func<CancellationToken, Task<ApiResult<PairConfirmResponse>>> OnConfirm { get; set; }
        public Func<CancellationToken, Task<ApiResult<HeartbeatResponse>>> OnHeartbeat { get; set; }
        public Func<CancellationToken, Task<ApiResult<SyncResponse>>> OnSync { get; set; }
        public Func<CancellationToken, Task<ApiResult<RenewResponse>>> OnRenew { get; set; }
        public Func<CancellationToken, Task<ApiResult<EmptyResponse>>> OnUnlink { get; set; }

        // ----- fila de impressão -----
        public int ClaimCalls;
        public int CompleteCalls;
        public int FailCalls;
        public List<string> CompletedJobs { get; } = new List<string>();
        public List<FailedJob> FailedJobs { get; } = new List<FailedJob>();
        public List<int> ClaimLimits { get; } = new List<int>();
        public List<int> ClaimWaits { get; } = new List<int>();
        public Func<CancellationToken, Task<ApiResult<ClaimJobsResponse>>> OnClaim { get; set; }
        public Func<string, CancellationToken, Task<ApiResult<JobAckResponse>>> OnComplete { get; set; }
        public Func<string, CancellationToken, Task<ApiResult<JobAckResponse>>> OnFail { get; set; }

        public sealed class FailedJob
        {
            public string JobId = string.Empty;
            public string Code = string.Empty;
            public string Message = string.Empty;
            public bool Definitive;
        }

        public FakeEdgeApi()
        {
            OnClaim = ct => Task.FromResult(ApiResult<ClaimJobsResponse>.Success(new ClaimJobsResponse(), 200));
            OnComplete = (id, ct) => Task.FromResult(ApiResult<JobAckResponse>.Success(new JobAckResponse(), 200));
            OnFail = (id, ct) => Task.FromResult(ApiResult<JobAckResponse>.Success(new JobAckResponse(), 200));
            OnVerify = ct =>
            {
                PairVerifyResponse r = new PairVerifyResponse();
                r.EmpresaNome = "Distribuidora Florest";
                r.EstacaoNome = "Caixa 1";
                return Task.FromResult(ApiResult<PairVerifyResponse>.Success(r, 200));
            };
            OnConfirm = ct =>
            {
                PairConfirmResponse r = new PairConfirmResponse();
                r.Token = TestTokens.Make(1);
                r.EmpresaNome = "Distribuidora Florest";
                r.EstacaoNome = "Caixa 1";
                return Task.FromResult(ApiResult<PairConfirmResponse>.Success(r, 200));
            };
            OnHeartbeat = ct => Task.FromResult(ApiResult<HeartbeatResponse>.Success(new HeartbeatResponse(), 200));
            OnSync = ct =>
            {
                SyncResponse r = new SyncResponse();
                r.Recebidas = 1;
                r.Validas = 1;
                r.Ativas = 1;
                return Task.FromResult(ApiResult<SyncResponse>.Success(r, 200));
            };
            OnRenew = ct =>
            {
                RenewResponse r = new RenewResponse();
                r.Token = TestTokens.Make(1, 2);
                r.GracaSegundos = 900;
                return Task.FromResult(ApiResult<RenewResponse>.Success(r, 200));
            };
            OnUnlink = ct => Task.FromResult(ApiResult<EmptyResponse>.Success(new EmptyResponse(), 200));
        }

        private async Task<T> Track<T>(Func<Task<T>> action)
        {
            lock (_lock)
            {
                _inFlight++;
                if (_inFlight > MaxInFlight) MaxInFlight = _inFlight;
            }
            try
            {
                return await action();
            }
            finally
            {
                lock (_lock)
                {
                    _inFlight--;
                }
            }
        }

        public Task<ApiResult<PairVerifyResponse>> PairVerifyAsync(string codigo, CancellationToken ct)
        {
            Interlocked.Increment(ref VerifyCalls);
            lock (_lock) { VerifiedCodes.Add(codigo); }
            return Track(() => OnVerify(ct));
        }

        public Task<ApiResult<PairConfirmResponse>> PairConfirmAsync(PairConfirmRequest request, CancellationToken ct)
        {
            Interlocked.Increment(ref ConfirmCalls);
            lock (_lock) { ConfirmRequests.Add(request); }
            return Track(() => OnConfirm(ct));
        }

        public Task<ApiResult<HeartbeatResponse>> HeartbeatAsync(AgentToken token, string installationId, string agentVersion, CancellationToken ct)
        {
            Interlocked.Increment(ref HeartbeatCalls);
            lock (_lock) { HeartbeatTokens.Add(token.RevealForAuthorization()); InstallationIdsSeen.Add(installationId); }
            return Track(() => OnHeartbeat(ct));
        }

        public Task<ApiResult<SyncResponse>> SyncAsync(AgentToken token, SyncRequest request, CancellationToken ct)
        {
            Interlocked.Increment(ref SyncCalls);
            lock (_lock)
            {
                SyncTokens.Add(token.RevealForAuthorization());
                SyncRequests.Add(request);
            }
            return Track(() => OnSync(ct));
        }

        public Task<ApiResult<RenewResponse>> RenewAsync(AgentToken token, string installationId, CancellationToken ct)
        {
            Interlocked.Increment(ref RenewCalls);
            lock (_lock) { RenewTokens.Add(token.RevealForAuthorization()); InstallationIdsSeen.Add(installationId); }
            return Track(() => OnRenew(ct));
        }

        public Task<ApiResult<EmptyResponse>> UnlinkAsync(AgentToken token, string installationId, CancellationToken ct)
        {
            Interlocked.Increment(ref UnlinkCalls);
            lock (_lock) { UnlinkTokens.Add(token.RevealForAuthorization()); InstallationIdsSeen.Add(installationId); }
            return Track(() => OnUnlink(ct));
        }

        public Task<ApiResult<ClaimJobsResponse>> ClaimJobsAsync(AgentToken token, string installationId, int limit, int waitSeconds, CancellationToken ct)
        {
            Interlocked.Increment(ref ClaimCalls);
            lock (_lock) { InstallationIdsSeen.Add(installationId); ClaimLimits.Add(limit); ClaimWaits.Add(waitSeconds); }
            return Track(() => OnClaim(ct));
        }

        public Task<ApiResult<JobAckResponse>> CompleteJobAsync(AgentToken token, string installationId, string jobId, CancellationToken ct)
        {
            Interlocked.Increment(ref CompleteCalls);
            lock (_lock) { CompletedJobs.Add(jobId); }
            return Track(() => OnComplete(jobId, ct));
        }

        public Task<ApiResult<JobAckResponse>> FailJobAsync(AgentToken token, string installationId, string jobId, string errorCode, string errorMessage, bool definitive, CancellationToken ct)
        {
            Interlocked.Increment(ref FailCalls);
            FailedJob f = new FailedJob();
            f.JobId = jobId;
            f.Code = errorCode;
            f.Message = errorMessage;
            f.Definitive = definitive;
            lock (_lock) { FailedJobs.Add(f); }
            return Track(() => OnFail(jobId, ct));
        }
    }

    /// <summary>Controlador falso para testar o despacho dos comandos do pipe.</summary>
    internal sealed class FakeController : IAgentController
    {
        public List<string> VerifiedCodes { get; } = new List<string>();
        public List<string> ConfirmedCodes { get; } = new List<string>();
        public List<IReadOnlyList<PrinterInfo>> Submitted { get; } = new List<IReadOnlyList<PrinterInfo>>();
        public List<string> Sessions { get; } = new List<string>();
        public List<bool> UnlinkForce { get; } = new List<bool>();
        public List<CallerIdentity> Callers { get; } = new List<CallerIdentity>();
        public int ScanCalls;
        public Exception? ThrowOnStatus { get; set; }

        public AgentStatusDto GetStatus()
        {
            if (ThrowOnStatus != null) throw ThrowOnStatus;
            AgentStatusDto dto = new AgentStatusDto();
            dto.Estado = AgentStatusKind.Conectado;
            dto.Computador = "PC-TESTE";
            dto.Vinculado = true;
            return dto;
        }

        public IReadOnlyList<PrinterInfo> GetPrinters()
        {
            return new List<PrinterInfo>();
        }

        public Task<ControllerResult> VerifyPairingAsync(string normalizedCode, CallerIdentity caller, CancellationToken ct)
        {
            Callers.Add(caller);
            VerifiedCodes.Add(normalizedCode);
            PairingPreviewDto dto = new PairingPreviewDto();
            dto.Empresa = "Empresa Teste";
            return Task.FromResult(ControllerResult.Success(dto));
        }

        public Task<ControllerResult> ConfirmPairingAsync(string normalizedCode, CallerIdentity caller, CancellationToken ct)
        {
            Callers.Add(caller);
            ConfirmedCodes.Add(normalizedCode);
            return Task.FromResult(ControllerResult.Success(null, "conectado"));
        }

        public Task<ControllerResult> ScanPrintersAsync(CancellationToken ct)
        {
            ScanCalls++;
            ScanResultDto dto = new ScanResultDto();
            dto.Sincronizado = true;
            return Task.FromResult(ControllerResult.Success(dto));
        }

        public ControllerResult SubmitUserPrinters(string session, IReadOnlyList<PrinterInfo> printers)
        {
            Sessions.Add(session);
            Submitted.Add(printers);
            return ControllerResult.Success(null);
        }

        public Task<ControllerResult> UnlinkAsync(bool force, CallerIdentity caller, CancellationToken ct)
        {
            Callers.Add(caller);
            UnlinkForce.Add(force);
            return Task.FromResult(ControllerResult.Success(null, "desvinculado"));
        }
    }

    /// <summary>Identidades de chamadores usadas nos testes (o Windows é quem as fornece de verdade, via PipeCallerIdentity).</summary>
    internal static class TestCallers
    {
        public const string AliceSid = "S-1-5-21-1111111111-2222222222-3333333333-1001";
        public const string BobSid = "S-1-5-21-1111111111-2222222222-3333333333-1002";

        public static readonly CallerIdentity Alice = new CallerIdentity(AliceSid, 1, false, false);
        public static readonly CallerIdentity AliceOtherSession = new CallerIdentity(AliceSid, 2, false, false);
        public static readonly CallerIdentity Bob = new CallerIdentity(BobSid, 1, false, false);
        public static readonly CallerIdentity Admin = new CallerIdentity("S-1-5-21-1111111111-2222222222-3333333333-500", 1, true, false);
        public static readonly CallerIdentity LocalSystem = new CallerIdentity("S-1-5-18", 0, false, true);
    }

    /// <summary>Logger que guarda TUDO que seria escrito no log (mensagem formatada, argumentos e mensagem da exceção).</summary>
    internal sealed class CapturingLogger : ILogger
    {
        private readonly object _lock = new object();
        public List<string> Lines { get; } = new List<string>();

        public IDisposable? BeginScope<TState>(TState state) where TState : notnull
        {
            return null;
        }

        public bool IsEnabled(LogLevel logLevel)
        {
            return true;
        }

        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
        {
            string text = formatter(state, exception);
            if (state is IEnumerable<KeyValuePair<string, object?>> pairs)
            {
                foreach (KeyValuePair<string, object?> p in pairs)
                {
                    text += " | " + p.Key + "=" + (p.Value != null ? p.Value.ToString() : string.Empty);
                }
            }
            if (exception != null) text += " | EX:" + exception.GetType().Name + ":" + exception.Message;
            lock (_lock) { Lines.Add(text); }
        }

        public string All()
        {
            lock (_lock) { return string.Join("\n", Lines); }
        }
    }
}
