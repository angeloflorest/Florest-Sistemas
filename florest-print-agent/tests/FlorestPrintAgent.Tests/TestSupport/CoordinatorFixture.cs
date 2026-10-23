using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using FlorestPrintAgent.Core;
using FlorestPrintAgent.Core.Agent;
using FlorestPrintAgent.Core.Api;
using FlorestPrintAgent.Core.Printers;
using FlorestPrintAgent.Core.Security;
using FlorestPrintAgent.Core.Storage;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace FlorestPrintAgent.Tests.TestSupport
{
    /// <summary>Descoberta que sempre lança exceção (simula falha técnica inesperada).</summary>
    internal sealed class ThrowingDiscovery : IPrinterDiscovery
    {
        public DiscoveryResult Discover()
        {
            throw new InvalidOperationException("falha simulada na enumeração");
        }
    }

    /// <summary>
    /// Monta um AgentCoordinator completo com armazenamento real (em pasta temporária), protetor falso,
    /// relógio falso, servidor falso e descoberta falsa. Aleatoriedade fixa em 0,5 (jitter zero) para resultados exatos.
    /// </summary>
    internal sealed class CoordinatorFixture : IDisposable
    {
        public const string InstallationId = "11111111-2222-3333-4444-555555555555";

        public TempDir Dir { get; }
        public AgentPaths Paths { get; }
        public FakeClock Clock { get; }
        public FakeEdgeApi Api { get; }
        public FakeDiscovery Discovery { get; }
        public IPrinterDiscovery DiscoveryInUse { get; }
        public ControllableCredentialStore Store { get; private set; }
        public CredentialVault Vault { get; private set; }
        public AgentStateStore StateStore { get; private set; }
        public AgentCoordinator Coordinator { get; private set; }
        private readonly ILogger _logger;

        /// <param name="preLinked">Se informado, a credencial já existe em disco antes de iniciar (computador já vinculado).</param>
        /// <param name="autoStart">False permite preparar arquivos antes de chamar Start().</param>
        /// <param name="discovery">Descoberta alternativa (padrão: FakeDiscovery).</param>
        public CoordinatorFixture(AgentToken? preLinked = null, bool autoStart = true, IPrinterDiscovery? discovery = null, ILogger? logger = null)
        {
            _logger = logger ?? NullLogger.Instance;
            Dir = new TempDir();
            Paths = new AgentPaths(Dir.Path);
            Clock = new FakeClock();
            Api = new FakeEdgeApi();
            Discovery = new FakeDiscovery();
            DiscoveryInUse = discovery ?? Discovery;

            if (preLinked != null)
            {
                new CredentialStore(Paths.CredentialFile, new FakeSecretProtector()).Save(preLinked);
            }

            Store = null!;
            Vault = null!;
            StateStore = null!;
            Coordinator = null!;
            Build();
            if (autoStart) Start();
        }

        private void Build()
        {
            Store = new ControllableCredentialStore(new CredentialStore(Paths.CredentialFile, new FakeSecretProtector()));
            Vault = new CredentialVault(Store, Clock);
            StateStore = new AgentStateStore(Paths.StateFile);
            Coordinator = new AgentCoordinator(
                Api,
                DiscoveryInUse,
                Vault,
                StateStore,
                InstallationId,
                new HostInfo("PC-CAIXA", "Windows 11 Teste"),
                Clock,
                _logger);
            Coordinator.RandomSource = () => 0.5;
        }

        public void Start()
        {
            Coordinator.Initialize();
        }

        /// <summary>Simula o reinício do serviço: novos objetos lendo os mesmos arquivos.</summary>
        public void Restart()
        {
            Build();
            Start();
        }

        /// <summary>Fluxo completo de duas etapas (verificar → confirmar) feito pelo MESMO chamador. Devolve o resultado da última etapa executada.</summary>
        public async Task<ControllerResult> PairAsync(string code = "ABCD-2345", CallerIdentity? caller = null)
        {
            CallerIdentity who = caller ?? TestCallers.Alice;
            ControllerResult verify = await Coordinator.VerifyPairingAsync(code, who, CancellationToken.None);
            if (!verify.Ok) return verify;
            return await Coordinator.ConfirmPairingAsync(code, who, CancellationToken.None);
        }

        public void SetPrinters(params PrinterInfo[] printers)
        {
            Discovery.Result = DiscoveryResult.Ok(new List<PrinterInfo>(printers));
        }

        public static ApiResult<HeartbeatResponse> Hb(Action<HeartbeatResponse>? fill)
        {
            HeartbeatResponse r = new HeartbeatResponse();
            if (fill != null) fill(r);
            return ApiResult<HeartbeatResponse>.Success(r, 200);
        }

        public static ApiResult<HeartbeatResponse> HbOk()
        {
            return Hb(null);
        }

        public static ApiResult<HeartbeatResponse> HbFail(ApiOutcome outcome, int status, string? code)
        {
            return ApiResult<HeartbeatResponse>.Failure(outcome, status, code, null);
        }

        public void Dispose()
        {
            Dir.Dispose();
        }
    }
}
