using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using FlorestPrintAgent.Core;
using FlorestPrintAgent.Core.Agent;
using FlorestPrintAgent.Core.Api;
using FlorestPrintAgent.Core.Printers;
using FlorestPrintAgent.Core.Security;
using FlorestPrintAgent.Core.Storage;
using FlorestPrintAgent.Tests.TestSupport;
using Xunit;

namespace FlorestPrintAgent.Tests
{
    internal static class Assertions
    {
        public static void Seconds(double expected, TimeSpan actual, double tolerance)
        {
            Assert.InRange(actual.TotalSeconds, expected - tolerance, expected + tolerance);
        }
    }

    public class PairingTests
    {
        private static readonly string Code = "ABCD-2345";

        [Fact]
        public async Task VerifyShowsTheCompanyAndStoresNothing()
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                ControllerResult r = await f.Coordinator.VerifyPairingAsync(Code, TestCallers.Alice, CancellationToken.None);

                Assert.True(r.Ok);
                PairingPreviewDto preview = Assert.IsType<PairingPreviewDto>(r.Data);
                Assert.Equal("Distribuidora Florest", preview.Empresa);
                Assert.Equal("Caixa 1", preview.Estacao);
                Assert.Equal(1, f.Api.VerifyCalls);
                Assert.Equal(0, f.Api.ConfirmCalls);
                Assert.False(f.Vault.HasCredential);
                Assert.False(File.Exists(f.Paths.CredentialFile));
            }
        }

        [Fact]
        public async Task ConfirmSavesTheProtectedCredentialAndSendsTheContractData()
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                ControllerResult r = await f.PairAsync(Code);

                Assert.True(r.Ok);
                Assert.True(f.Vault.HasCredential);
                Assert.True(File.Exists(f.Paths.CredentialFile));

                PairConfirmRequest request = f.Api.ConfirmRequests.Single();
                Assert.Equal(Code, request.Codigo);
                Assert.Equal(CoordinatorFixture.InstallationId, request.IdentificadorInstalacao);
                Assert.Equal("PC-CAIXA", request.NomeComputador);
                Assert.Equal("Windows 11 Teste", request.SistemaOperacional);
                Assert.Equal(AgentConstants.AgentVersion, request.VersaoAgente);

                // o que foi gravado em disco é exatamente o token emitido
                CredentialLoadResult onDisk = new CredentialStore(f.Paths.CredentialFile, new FakeSecretProtector()).Load();
                Assert.Equal(CredentialLoadStatus.Ok, onDisk.Status);
                Assert.Equal(TestTokens.Make(1).RevealForAuthorization(), onDisk.Token!.RevealForAuthorization());

                AgentStatusDto status = f.Coordinator.GetStatus();
                Assert.True(status.Vinculado);
                Assert.Equal("Distribuidora Florest", status.Empresa);
                Assert.Equal("Caixa 1", status.Estacao);

                // depois do pareamento: heartbeat, descoberta e sincronização imediatos no laço
                Assert.True(f.Coordinator.SyncRequested);
                Assert.Equal(f.Clock.UtcNow, f.Coordinator.NextHeartbeatUtc);
            }
        }

        [Fact]
        public async Task ConfirmNeverPersistsThePairingCodeOrAPlainToken()
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                await f.PairAsync(Code);
                string full = TestTokens.Make(1).RevealForAuthorization();
                string secret = full.Substring(full.IndexOf('.') + 1);

                string[] files = Directory.GetFiles(f.Dir.Path, "*", SearchOption.AllDirectories);
                Assert.NotEmpty(files);
                foreach (string file in files)
                {
                    string text = Encoding.UTF8.GetString(File.ReadAllBytes(file));
                    Assert.DoesNotContain(Code, text, StringComparison.Ordinal);
                    Assert.DoesNotContain(secret, text, StringComparison.Ordinal);
                    Assert.DoesNotContain("ABCD2345", text, StringComparison.Ordinal);
                }
                Assert.Contains(f.Paths.StateFile, files);
            }
        }

        [Fact]
        public async Task ServerRejectionLeavesTheComputerUnlinked()
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                f.Api.OnConfirm = ct => Task.FromResult(ApiResult<PairConfirmResponse>.Failure(ApiOutcome.Rejected, 400, "codigo_invalido", null));

                ControllerResult r = await f.PairAsync(Code);

                Assert.False(r.Ok);
                Assert.Equal("codigo_invalido", r.Erro);
                Assert.False(f.Vault.HasCredential);
                Assert.False(File.Exists(f.Paths.CredentialFile));
                Assert.Equal(AgentStatusKind.NaoVinculado, f.Coordinator.GetStatus().Estado);
            }
        }

        [Theory]
        [InlineData(ApiOutcome.NetworkError)]
        [InlineData(ApiOutcome.Timeout)]
        [InlineData(ApiOutcome.ServerError)]
        [InlineData(ApiOutcome.RateLimited)]
        [InlineData(ApiOutcome.InvalidResponse)]
        public async Task NetworkAndServerFailuresDuringConfirmDoNotLink(ApiOutcome outcome)
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                f.Api.OnConfirm = ct => Task.FromResult(ApiResult<PairConfirmResponse>.Failure(outcome, 0, null, null));
                ControllerResult r = await f.PairAsync(Code);
                Assert.False(r.Ok);
                Assert.False(f.Vault.HasCredential);
            }
        }

        [Fact]
        public async Task CredentialSaveFailureAfterServerAcceptanceReportsAnErrorAndDoesNotLink()
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                f.Store.FailSaves = true;
                ControllerResult r = await f.PairAsync(Code);
                Assert.False(r.Ok);
                Assert.Equal("falha_credencial", r.Erro);
                Assert.False(f.Vault.HasCredential);
                Assert.Equal(AgentStatusKind.NaoVinculado, f.Coordinator.GetStatus().Estado);
            }
        }

        [Fact]
        public async Task VerifyAndConfirmAreRefusedWhenAlreadyLinked()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                ControllerResult verify = await f.Coordinator.VerifyPairingAsync(Code, TestCallers.Alice, CancellationToken.None);
                ControllerResult confirm = await f.Coordinator.ConfirmPairingAsync(Code, TestCallers.Alice, CancellationToken.None);
                Assert.Equal("ja_vinculado", verify.Erro);
                Assert.Equal("ja_vinculado", confirm.Erro);
                Assert.Equal(0, f.Api.VerifyCalls);
                Assert.Equal(0, f.Api.ConfirmCalls);
            }
        }

        [Fact]
        public async Task VerifyFailureIsMappedToAUserMessage()
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                f.Api.OnVerify = ct => Task.FromResult(ApiResult<PairVerifyResponse>.Failure(ApiOutcome.Rejected, 400, "codigo_invalido", null));
                ControllerResult r = await f.Coordinator.VerifyPairingAsync(Code, TestCallers.Alice, CancellationToken.None);
                Assert.False(r.Ok);
                Assert.Equal("codigo_invalido", r.Erro);
                Assert.Contains("inválido", r.Mensagem, StringComparison.Ordinal);

                f.Api.OnVerify = ct => Task.FromResult(ApiResult<PairVerifyResponse>.Failure(ApiOutcome.NetworkError, 0, null, null));
                ControllerResult offline = await f.Coordinator.VerifyPairingAsync(Code, TestCallers.Alice, CancellationToken.None);
                Assert.Equal("sem_conexao", offline.Erro);
            }
        }

        [Fact]
        public async Task HeartbeatIntervalIs120UntilTheServerSaysOtherwise()
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                await f.PairAsync(Code);
                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                Assertions.Seconds(AgentConstants.DefaultHeartbeatSeconds, f.Coordinator.NextHeartbeatUtc - f.Clock.UtcNow, 1);
            }
        }

        [Fact]
        public async Task ConfirmAppliesTheServerHeartbeatIntervalAndPrinterLimit()
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                f.Api.OnConfirm = ct =>
                {
                    PairConfirmResponse r = new PairConfirmResponse();
                    r.Token = TestTokens.Make(1);
                    r.EmpresaNome = "Distribuidora";
                    r.HeartbeatSegundos = 90;
                    r.LimiteImpressoras = 50;
                    return Task.FromResult(ApiResult<PairConfirmResponse>.Success(r, 200));
                };
                await f.PairAsync(Code);

                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                Assertions.Seconds(90, f.Coordinator.NextHeartbeatUtc - f.Clock.UtcNow, 1);

                List<PrinterInfo> many = new List<PrinterInfo>();
                for (int i = 0; i < 60; i++) many.Add(Samples.Printer("P" + i.ToString("D2"), PrinterConnection.Windows, PrinterStatus.Disponivel, null, null, "X" + i));
                f.Discovery.Result = DiscoveryResult.Ok(many);
                await f.Coordinator.SyncOnceAsync(false, CancellationToken.None);
                Assert.Equal(50, f.Api.SyncRequests.Single().Impressoras.Count);
            }
        }

        [Fact]
        public async Task UnlinkedAgentDoesNotSyncOrHeartbeat()
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                await f.Coordinator.RenewOnceAsync(CancellationToken.None);
                await f.Coordinator.SyncOnceAsync(false, CancellationToken.None);
                Assert.Equal(0, f.Api.HeartbeatCalls);
                Assert.Equal(0, f.Api.RenewCalls);
                Assert.Equal(0, f.Api.SyncCalls);
            }
        }
    }

    public class HeartbeatTests
    {
        [Fact]
        public async Task IntervalComesFromTheServerWithPlusMinusTenPercentJitter()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                f.Api.OnHeartbeat = ct => Task.FromResult(CoordinatorFixture.Hb(r => r.HeartbeatSegundos = 300));

                f.Coordinator.RandomSource = () => 0.5;
                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                Assertions.Seconds(300, f.Coordinator.NextHeartbeatUtc - f.Clock.UtcNow, 0.5);

                f.Coordinator.RandomSource = () => 0.0;
                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                Assertions.Seconds(270, f.Coordinator.NextHeartbeatUtc - f.Clock.UtcNow, 0.5);

                f.Coordinator.RandomSource = () => 1.0;
                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                Assertions.Seconds(330, f.Coordinator.NextHeartbeatUtc - f.Clock.UtcNow, 0.5);
            }
        }

        [Fact]
        public async Task ServerIntervalIsClampedToTheSafeRange()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                f.Api.OnHeartbeat = ct => Task.FromResult(CoordinatorFixture.Hb(r => r.HeartbeatSegundos = 1));
                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                Assertions.Seconds(AgentConstants.MinHeartbeatSeconds, f.Coordinator.NextHeartbeatUtc - f.Clock.UtcNow, 0.5);

                f.Api.OnHeartbeat = ct => Task.FromResult(CoordinatorFixture.Hb(r => r.HeartbeatSegundos = 999999));
                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                Assertions.Seconds(AgentConstants.MaxHeartbeatSeconds, f.Coordinator.NextHeartbeatUtc - f.Clock.UtcNow, 0.5);
            }
        }

        [Fact]
        public void ClampHeartbeatBounds()
        {
            Assert.Equal(AgentConstants.MinHeartbeatSeconds, AgentCoordinator.ClampHeartbeat(-5));
            Assert.Equal(AgentConstants.MinHeartbeatSeconds, AgentCoordinator.ClampHeartbeat(0));
            Assert.Equal(120, AgentCoordinator.ClampHeartbeat(120));
            Assert.Equal(AgentConstants.MaxHeartbeatSeconds, AgentCoordinator.ClampHeartbeat(int.MaxValue));
        }

        [Fact]
        public async Task HeartbeatUsesTheCurrentTokenAndInstallation()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                Assert.Equal(TestTokens.Make(1).RevealForAuthorization(), f.Api.HeartbeatTokens.Single());
            }
        }

        [Fact]
        public async Task NetworkFailuresBackOffExponentiallyWithACapAndKeepTheLink()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                f.Api.OnHeartbeat = ct => Task.FromResult(CoordinatorFixture.HbFail(ApiOutcome.NetworkError, 0, null));
                double[] expected = { 15, 30, 60, 120, 240, 300, 300, 300 };
                foreach (double seconds in expected)
                {
                    await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                    Assertions.Seconds(seconds, f.Coordinator.NextHeartbeatUtc - f.Clock.UtcNow, 0.5);
                    Assert.True(f.Vault.HasCredential);
                    Assert.True(File.Exists(f.Paths.CredentialFile));
                }
            }
        }

        [Fact]
        public async Task BackoffResetsAfterASuccessfulHeartbeat()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                f.Api.OnHeartbeat = ct => Task.FromResult(CoordinatorFixture.HbFail(ApiOutcome.ServerError, 503, null));
                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);

                f.Api.OnHeartbeat = ct => Task.FromResult(CoordinatorFixture.HbOk());
                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);

                f.Api.OnHeartbeat = ct => Task.FromResult(CoordinatorFixture.HbFail(ApiOutcome.ServerError, 503, null));
                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                Assertions.Seconds(15, f.Coordinator.NextHeartbeatUtc - f.Clock.UtcNow, 0.5);
            }
        }

        [Fact]
        public async Task UnauthorizedNeverDeletesTheCredentialAndRecoversWhenTheServerAcceptsAgain()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                f.Api.OnHeartbeat = ct => Task.FromResult(CoordinatorFixture.HbFail(ApiOutcome.Unauthorized, 401, "credencial_invalida"));
                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);

                Assert.True(f.Vault.HasCredential);
                Assert.True(File.Exists(f.Paths.CredentialFile));
                AgentStatusDto status = f.Coordinator.GetStatus();
                Assert.Equal(AgentStatusKind.Erro, status.Estado);
                Assert.True(status.Vinculado);
                Assert.Contains("credencial_invalida", status.Mensagem, StringComparison.Ordinal);
                Assert.Equal(f.Clock.UtcNow + AgentConstants.CredentialRejectedRetry, f.Coordinator.NextHeartbeatUtc);

                f.Api.OnHeartbeat = ct => Task.FromResult(CoordinatorFixture.HbOk());
                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                Assert.Equal(AgentStatusKind.Conectado, f.Coordinator.GetStatus().Estado);
            }
        }

        [Fact]
        public async Task RateLimitUsesTheServerRetryAfter()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                f.Api.OnHeartbeat = ct => Task.FromResult(ApiResult<HeartbeatResponse>.Failure(ApiOutcome.RateLimited, 429, "x", TimeSpan.FromSeconds(120)));
                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                Assert.Equal(f.Clock.UtcNow + TimeSpan.FromSeconds(120), f.Coordinator.NextHeartbeatUtc);
                Assert.True(f.Vault.HasCredential);
            }
        }

        [Fact]
        public async Task UnexpectedResponseIsAnErrorWithAHintAndKeepsTheLink()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                f.Api.OnHeartbeat = ct => Task.FromResult(CoordinatorFixture.HbFail(ApiOutcome.InvalidResponse, 401, null));
                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);

                AgentStatusDto status = f.Coordinator.GetStatus();
                Assert.Equal(AgentStatusKind.Erro, status.Estado);
                Assert.Contains("HTTP 401", status.Mensagem, StringComparison.Ordinal);
                Assert.Contains("JWT", status.Mensagem, StringComparison.Ordinal);
                Assert.True(f.Vault.HasCredential);
                Assert.True((f.Coordinator.NextHeartbeatUtc - f.Clock.UtcNow) >= TimeSpan.FromSeconds(60));
            }
        }

        [Fact]
        public async Task ServerRequestedSyncIsHonoredOnceWithMinimumSpacing()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                f.Api.OnHeartbeat = ct => Task.FromResult(CoordinatorFixture.Hb(r => r.SincronizarAgora = true));

                await f.Coordinator.SyncOnceAsync(false, CancellationToken.None); // limpa o pedido inicial
                Assert.False(f.Coordinator.SyncRequested);

                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                Assert.True(f.Coordinator.SyncRequested);

                await f.Coordinator.SyncOnceAsync(false, CancellationToken.None);
                Assert.False(f.Coordinator.SyncRequested);

                // o servidor continua pedindo, mas não pode virar um laço infinito de sincronizações
                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                Assert.False(f.Coordinator.SyncRequested);

                f.Clock.Advance(AgentConstants.MinSpacingBetweenServerRequestedSyncs + TimeSpan.FromSeconds(1));
                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                Assert.True(f.Coordinator.SyncRequested);
            }
        }

        [Fact]
        public async Task RenewFlagIsRememberedFromTheHeartbeat()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                f.Api.OnHeartbeat = ct => Task.FromResult(CoordinatorFixture.Hb(r => r.RenovarCredencial = true));
                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                Assert.True(f.Coordinator.RenewRequested);
            }
        }

        [Fact]
        public async Task StationNameFromHeartbeatIsShownAndPersisted()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                f.Api.OnHeartbeat = ct => Task.FromResult(CoordinatorFixture.Hb(r => r.EstacaoNome = "Caixa 7"));
                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                Assert.Equal("Caixa 7", f.Coordinator.GetStatus().Estacao);
                Assert.Equal("Caixa 7", f.StateStore.Load().StationName);
            }
        }

        [Fact]
        public async Task HeartbeatsNeverRunConcurrently()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                f.Api.OnHeartbeat = async ct =>
                {
                    await Task.Delay(150, ct);
                    return CoordinatorFixture.HbOk();
                };

                Task a = f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                Task b = f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                Task c = f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                await Task.WhenAll(a, b, c);

                Assert.Equal(3, f.Api.HeartbeatCalls);
                Assert.Equal(1, f.Api.MaxInFlight);
            }
        }

        [Fact]
        public async Task HeartbeatSyncAndRenewShareOneGate()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                f.Api.OnHeartbeat = async ct => { await Task.Delay(120, ct); return CoordinatorFixture.HbOk(); };
                f.Api.OnSync = async ct =>
                {
                    await Task.Delay(120, ct);
                    return ApiResult<SyncResponse>.Success(new SyncResponse(), 200);
                };
                f.Api.OnRenew = async ct =>
                {
                    await Task.Delay(120, ct);
                    RenewResponse r = new RenewResponse();
                    r.Token = TestTokens.Make(1, 2);
                    return ApiResult<RenewResponse>.Success(r, 200);
                };

                Task h = f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                Task s = f.Coordinator.SyncOnceAsync(false, CancellationToken.None);
                Task r2 = f.Coordinator.RenewOnceAsync(CancellationToken.None);
                await Task.WhenAll(h, s, r2);

                Assert.Equal(1, f.Api.HeartbeatCalls);
                Assert.Equal(1, f.Api.SyncCalls);
                Assert.Equal(1, f.Api.RenewCalls);
                Assert.Equal(1, f.Api.MaxInFlight);
            }
        }

        [Fact]
        public async Task LoopStopsPromptlyOnCancellationAndDoesNothingWhenUnlinked()
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            using (CancellationTokenSource cts = new CancellationTokenSource())
            {
                Task loop = f.Coordinator.RunAsync(cts.Token);
                await Task.Delay(300);
                Assert.Equal(0, f.Api.HeartbeatCalls);
                Assert.Equal(0, f.Api.SyncCalls);

                cts.Cancel();
                Task finished = await Task.WhenAny(loop, Task.Delay(TimeSpan.FromSeconds(10)));
                Assert.Same(loop, finished);
                await loop;
            }
        }

        [Fact]
        public async Task LoopRunsHeartbeatAndInitialSyncWhenLinkedThenStopsOnCancellation()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            using (CancellationTokenSource cts = new CancellationTokenSource())
            {
                f.SetPrinters(Samples.Usb("Balcao"));
                Task loop = f.Coordinator.RunAsync(cts.Token);

                DateTime limit = DateTime.UtcNow + TimeSpan.FromSeconds(15);
                while ((f.Api.HeartbeatCalls < 1 || f.Api.SyncCalls < 1) && DateTime.UtcNow < limit)
                {
                    await Task.Delay(50);
                }

                Assert.True(f.Api.HeartbeatCalls >= 1);
                Assert.True(f.Api.SyncCalls >= 1);
                Assert.Equal("Balcao", f.Api.SyncRequests[0].Impressoras.Single().Nome);

                cts.Cancel();
                Task finished = await Task.WhenAny(loop, Task.Delay(TimeSpan.FromSeconds(10)));
                Assert.Same(loop, finished);
                await loop;
            }
        }
    }

    public class ConnectionStateTests
    {
        [Fact]
        public void NotLinkedWhenThereIsNoCredential()
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                AgentStatusDto s = f.Coordinator.GetStatus();
                Assert.Equal(AgentStatusKind.NaoVinculado, s.Estado);
                Assert.False(s.Vinculado);
                Assert.Null(s.Empresa);
                Assert.Null(s.UltimaComunicacaoUtc);
                Assert.Equal("PC-CAIXA", s.Computador);
                Assert.Equal(AgentConstants.AgentVersion, s.Versao);
            }
        }

        [Fact]
        public void LinkedWithoutContactYetIsNoConnection()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                AgentStatusDto s = f.Coordinator.GetStatus();
                Assert.Equal(AgentStatusKind.SemConexao, s.Estado);
                Assert.True(s.Vinculado);
            }
        }

        [Fact]
        public async Task ConnectedAfterASuccessfulHeartbeatThenNoConnectionWhenContactGetsOld()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                AgentStatusDto ok = f.Coordinator.GetStatus();
                Assert.Equal(AgentStatusKind.Conectado, ok.Estado);
                Assert.Equal(f.Clock.UtcNow, ok.UltimaComunicacaoUtc);

                // falha isolada: ainda dentro da janela de tolerância
                f.Api.OnHeartbeat = ct => Task.FromResult(CoordinatorFixture.HbFail(ApiOutcome.NetworkError, 0, null));
                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                Assert.Equal(AgentStatusKind.Conectado, f.Coordinator.GetStatus().Estado);

                // sem contato por muito tempo: Sem conexão, mantendo o vínculo
                f.Clock.Advance(TimeSpan.FromMinutes(10));
                AgentStatusDto offline = f.Coordinator.GetStatus();
                Assert.Equal(AgentStatusKind.SemConexao, offline.Estado);
                Assert.True(offline.Vinculado);
                Assert.Equal(AgentMessages.NoConnection, offline.Mensagem);
                Assert.True(f.Vault.HasCredential);
            }
        }

        [Fact]
        public async Task ConnectionComesBackAfterTheInternetReturns()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                f.Api.OnHeartbeat = ct => Task.FromResult(CoordinatorFixture.HbFail(ApiOutcome.Timeout, 0, null));
                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                f.Clock.Advance(TimeSpan.FromMinutes(10));
                Assert.Equal(AgentStatusKind.SemConexao, f.Coordinator.GetStatus().Estado);

                f.Api.OnHeartbeat = ct => Task.FromResult(CoordinatorFixture.HbOk());
                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                Assert.Equal(AgentStatusKind.Conectado, f.Coordinator.GetStatus().Estado);
            }
        }

        [Fact]
        public async Task ServerErrorEventuallyShowsNoConnection()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                f.Api.OnHeartbeat = ct => Task.FromResult(CoordinatorFixture.HbFail(ApiOutcome.ServerError, 503, null));
                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                f.Clock.Advance(TimeSpan.FromMinutes(10));
                AgentStatusDto s = f.Coordinator.GetStatus();
                Assert.Equal(AgentStatusKind.SemConexao, s.Estado);
                Assert.Equal(AgentMessages.ServerUnavailable, s.Mensagem);
            }
        }

        [Fact]
        public async Task RejectedCredentialIsAnErrorNotAnUnlink()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                f.Api.OnHeartbeat = ct => Task.FromResult(CoordinatorFixture.HbFail(ApiOutcome.Unauthorized, 401, "agente_revogado"));
                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                AgentStatusDto s = f.Coordinator.GetStatus();
                Assert.Equal(AgentStatusKind.Erro, s.Estado);
                Assert.True(s.Vinculado);
            }
        }

        [Fact]
        public void CorruptCredentialFileIsAnErrorAndIsNotDeleted()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(null, false))
            {
                Directory.CreateDirectory(f.Paths.DataDir);
                File.WriteAllBytes(f.Paths.CredentialFile, new byte[] { 9, 9, 9, 9, 9, 9, 9, 9 });
                f.Start();

                AgentStatusDto s = f.Coordinator.GetStatus();
                Assert.Equal(AgentStatusKind.Erro, s.Estado);
                Assert.False(s.Vinculado);
                Assert.True(File.Exists(f.Paths.CredentialFile));
            }
        }

        [Fact]
        public async Task CorruptCredentialMeansNoServerCallsAreMade()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(null, false))
            {
                Directory.CreateDirectory(f.Paths.DataDir);
                File.WriteAllBytes(f.Paths.CredentialFile, new byte[] { 9, 9, 9, 9, 9, 9, 9, 9 });
                f.Start();

                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                await f.Coordinator.SyncOnceAsync(false, CancellationToken.None);
                Assert.Equal(0, f.Api.HeartbeatCalls);
                Assert.Equal(0, f.Api.SyncCalls);
                Assert.True(File.Exists(f.Paths.CredentialFile));
            }
        }

        [Fact]
        public async Task LinkSurvivesAServiceRestart()
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                await f.PairAsync("ABCD-2345");
                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);

                f.Restart();

                Assert.True(f.Vault.HasCredential);
                AgentStatusDto s = f.Coordinator.GetStatus();
                Assert.True(s.Vinculado);
                Assert.Equal("Distribuidora Florest", s.Empresa);
                Assert.Equal("Caixa 1", s.Estacao);
            }
        }

        [Fact]
        public async Task OfflineAtStartupDoesNotUnlink()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                f.Api.OnHeartbeat = ct => Task.FromResult(CoordinatorFixture.HbFail(ApiOutcome.NetworkError, 0, null));
                f.Api.OnSync = ct => Task.FromResult(ApiResult<SyncResponse>.Failure(ApiOutcome.NetworkError, 0, null, null));
                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                await f.Coordinator.SyncOnceAsync(false, CancellationToken.None);
                f.Restart();
                // depois do reinício, com a internet ainda fora do ar, o primeiro ciclo também não pode desvincular
                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                await f.Coordinator.SyncOnceAsync(false, CancellationToken.None);
                Assert.True(f.Vault.HasCredential);
                Assert.True(File.Exists(f.Paths.CredentialFile));
                Assert.True(f.Coordinator.GetStatus().Vinculado);
            }
        }

        [Fact]
        public void TemporarilyUnreadableCredentialIsAnErrorAndIsNeverTreatedAsUnlinkedForever()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1), false))
            {
                f.Store.LoadOverride = () => new CredentialLoadResult(CredentialLoadStatus.Unreadable, null);
                f.Start();

                AgentStatusDto s = f.Coordinator.GetStatus();
                Assert.Equal(AgentStatusKind.Erro, s.Estado);
                Assert.False(s.Vinculado);
                Assert.True(File.Exists(f.Paths.CredentialFile));
            }
        }

        [Fact]
        public async Task PairingIsRefusedWhileTheExistingCredentialIsTemporarilyUnreadable()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1), false))
            {
                f.Store.LoadOverride = () => new CredentialLoadResult(CredentialLoadStatus.Unreadable, null);
                f.Start();

                ControllerResult r = await f.PairAsync("ABCD-2345");

                Assert.False(r.Ok);
                Assert.Equal("credencial_ilegivel", r.Erro);
                Assert.Equal(0, f.Api.ConfirmCalls);
                Assert.Equal(0, f.Store.SaveCount);
            }
        }

        [Fact]
        public async Task UnreadableCredentialRecoversOnTheNextReadWithoutRePairing()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1), false))
            {
                bool failing = true;
                f.Store.LoadOverride = () => failing ? new CredentialLoadResult(CredentialLoadStatus.Unreadable, null) : null;
                f.Start();
                Assert.False(f.Vault.HasCredential);

                failing = false;
                using (CancellationTokenSource cts = new CancellationTokenSource(TimeSpan.FromSeconds(20)))
                {
                    Task run = f.Coordinator.RunAsync(cts.Token);
                    DateTime limit = DateTime.UtcNow.AddSeconds(15);
                    while (f.Api.HeartbeatCalls == 0 && DateTime.UtcNow < limit) await Task.Delay(50);
                    cts.Cancel();
                    await run;
                }

                Assert.True(f.Vault.HasCredential);
                Assert.True(f.Api.HeartbeatCalls >= 1);
                Assert.Equal(0, f.Store.SaveCount);
            }
        }

        [Fact]
        public void BackoffDelayDoublesAndCaps()
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                Assertions.Seconds(15, f.Coordinator.BackoffDelay(1), 0.1);
                Assertions.Seconds(30, f.Coordinator.BackoffDelay(2), 0.1);
                Assertions.Seconds(60, f.Coordinator.BackoffDelay(3), 0.1);
                Assertions.Seconds(300, f.Coordinator.BackoffDelay(6), 0.1);
                Assertions.Seconds(300, f.Coordinator.BackoffDelay(50), 0.1);
                Assertions.Seconds(15, f.Coordinator.BackoffDelay(0), 0.1);
            }
        }
    }

    public class RenewalTests
    {
        [Fact]
        public async Task RenewedTokenIsSavedBeforeItBecomesActiveAndIsUsedByLaterCalls()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1, 1)))
            {
                string? activeDuringSave = null;
                f.Store.BeforeSave = t => { activeDuringSave = f.Vault.GetActive()!.RevealForAuthorization(); };

                await f.Coordinator.RenewOnceAsync(CancellationToken.None);

                string oldToken = TestTokens.Make(1, 1).RevealForAuthorization();
                string newToken = TestTokens.Make(1, 2).RevealForAuthorization();
                Assert.Equal(oldToken, activeDuringSave);
                Assert.Equal(newToken, f.Vault.GetActive()!.RevealForAuthorization());
                Assert.Equal(newToken, new CredentialStore(f.Paths.CredentialFile, new FakeSecretProtector()).Load().Token!.RevealForAuthorization());

                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                Assert.Equal(newToken, f.Api.HeartbeatTokens.Last());
            }
        }

        [Theory]
        [InlineData(ApiOutcome.NetworkError)]
        [InlineData(ApiOutcome.Timeout)]
        [InlineData(ApiOutcome.ServerError)]
        [InlineData(ApiOutcome.RateLimited)]
        [InlineData(ApiOutcome.InvalidResponse)]
        [InlineData(ApiOutcome.Unauthorized)]
        [InlineData(ApiOutcome.Rejected)]
        public async Task FailedRenewalKeepsTheCurrentToken(ApiOutcome outcome)
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1, 1)))
            {
                f.Api.OnRenew = ct => Task.FromResult(ApiResult<RenewResponse>.Failure(outcome, 0, null, null));

                await f.Coordinator.RenewOnceAsync(CancellationToken.None);

                string oldToken = TestTokens.Make(1, 1).RevealForAuthorization();
                Assert.Equal(oldToken, f.Vault.GetActive()!.RevealForAuthorization());
                Assert.Equal(oldToken, new CredentialStore(f.Paths.CredentialFile, new FakeSecretProtector()).Load().Token!.RevealForAuthorization());
                Assert.True(f.Vault.HasCredential);
                Assert.False(f.Vault.HasPendingPersistence);
            }
        }

        [Fact]
        public async Task DiskFailureWhileSavingTheRenewedTokenKeepsTheOldOneActiveUntilItCanBeSaved()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1, 1)))
            {
                string oldToken = TestTokens.Make(1, 1).RevealForAuthorization();
                string newToken = TestTokens.Make(1, 2).RevealForAuthorization();

                f.Store.FailSaves = true;
                await f.Coordinator.RenewOnceAsync(CancellationToken.None);

                Assert.True(f.Vault.HasPendingPersistence);
                Assert.Equal(oldToken, f.Vault.GetActive()!.RevealForAuthorization());
                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                Assert.Equal(oldToken, f.Api.HeartbeatTokens.Last());

                f.Store.FailSaves = false;
                Assert.True(f.Vault.TryFlushPending());
                Assert.Equal(newToken, f.Vault.GetActive()!.RevealForAuthorization());
                Assert.Equal(newToken, new CredentialStore(f.Paths.CredentialFile, new FakeSecretProtector()).Load().Token!.RevealForAuthorization());
            }
        }

        [Fact]
        public async Task RenewalForADifferentAgentIsIgnored()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1, 1)))
            {
                f.Api.OnRenew = ct =>
                {
                    RenewResponse r = new RenewResponse();
                    r.Token = TestTokens.Make(99, 1);
                    return Task.FromResult(ApiResult<RenewResponse>.Success(r, 200));
                };
                int savesBefore = f.Store.SaveCount;

                await f.Coordinator.RenewOnceAsync(CancellationToken.None);

                Assert.Equal(savesBefore, f.Store.SaveCount);
                Assert.Equal(TestTokens.Make(1, 1).RevealForAuthorization(), f.Vault.GetActive()!.RevealForAuthorization());
            }
        }

        [Fact]
        public async Task RenewIsSentWithTheCurrentCredentialOnly()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1, 1)))
            {
                await f.Coordinator.RenewOnceAsync(CancellationToken.None);
                Assert.Equal(1, f.Api.RenewCalls);
                Assert.Equal(TestTokens.Make(1, 1).RevealForAuthorization(), f.Api.RenewTokens.Single());
            }
        }
    }

    public class SyncTests
    {
        [Fact]
        public async Task DiscoveryFailureNeverSendsAnEmptyList()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                f.Discovery.Result = DiscoveryResult.Fail("spooler parado");

                SyncAttemptResult r = await f.Coordinator.SyncOnceAsync(false, CancellationToken.None);

                Assert.Equal(0, f.Api.SyncCalls);
                Assert.True(r.Ran);
                Assert.False(r.DiscoverySucceeded);
                Assert.False(r.ServerCalled);
                Assert.Equal("falha_descoberta", r.ErrorCode);
                Assert.Equal(f.Clock.UtcNow + AgentConstants.SyncRetryAfterDiscoveryFailure, f.Coordinator.NextSyncUtc);
                Assert.True(f.Vault.HasCredential);
            }
        }

        [Fact]
        public async Task DiscoveryExceptionIsAlsoAFailureNotAnEmptyList()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1), true, new ThrowingDiscovery()))
            {
                SyncAttemptResult r = await f.Coordinator.SyncOnceAsync(false, CancellationToken.None);
                Assert.Equal(0, f.Api.SyncCalls);
                Assert.False(r.DiscoverySucceeded);
            }
        }

        [Fact]
        public async Task EmptyListIsSentOnlyAfterASuccessfulCompleteDiscovery()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                f.Discovery.Result = DiscoveryResult.Fail("falhou");
                await f.Coordinator.SyncOnceAsync(false, CancellationToken.None);
                Assert.Equal(0, f.Api.SyncCalls);

                f.Discovery.Result = DiscoveryResult.Ok(new List<PrinterInfo>());
                SyncAttemptResult r = await f.Coordinator.SyncOnceAsync(false, CancellationToken.None);

                Assert.True(r.DiscoverySucceeded);
                Assert.Equal(1, f.Api.SyncCalls);
                Assert.Empty(f.Api.SyncRequests.Single().Impressoras);
            }
        }

        [Fact]
        public async Task SendsTheInstallationHostAndVersionData()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                f.SetPrinters(Samples.Usb("Balcao"));
                await f.Coordinator.SyncOnceAsync(false, CancellationToken.None);

                SyncRequest request = f.Api.SyncRequests.Single();
                Assert.Equal(CoordinatorFixture.InstallationId, request.IdentificadorInstalacao);
                Assert.Equal("PC-CAIXA", request.NomeComputador);
                Assert.Equal("Windows 11 Teste", request.SistemaOperacional);
                Assert.Equal(AgentConstants.AgentVersion, request.VersaoAgente);
                Assert.Equal(TestTokens.Make(1).RevealForAuthorization(), f.Api.SyncTokens.Single());
            }
        }

        // Política de segurança do PrinterMerger: o Service (LocalSystem) é a AUTORIDADE sobre as impressoras que ele enxerga.
        // Como o identificador é determinístico e público, um usuário comum poderia calculá-lo e enviar outro IP/porta para
        // uma impressora real; por isso a versão enviada pelo Tray NUNCA substitui a do Service.
        private static PrinterInfo KitchenSeenByService(string id)
        {
            // o Service enxerga a impressora, mas com poucos detalhes — mesmo assim ele continua sendo a autoridade
            return new PrinterInfo { Identificador = id, Nome = "Cozinha", Conexao = PrinterConnection.Outro, Status = PrinterStatus.Desconhecido };
        }

        private static PrinterInfo KitchenSubmittedByTray(string id)
        {
            return new PrinterInfo { Identificador = id, Nome = "Cozinha", Conexao = PrinterConnection.Rede, Ip = "10.66.66.66", Porta = 1234, PortaWindows = "IP_10.66.66.66", Status = PrinterStatus.Disponivel };
        }

        [Fact]
        public async Task ServiceRemainsTheAuthorityForAPrinterAlsoReportedByTheTray()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                string id = PrinterIdentifier.Compute("Cozinha", "IP_192.168.0.50", null, null);
                f.SetPrinters(KitchenSeenByService(id));
                f.Coordinator.SubmitUserPrinters("PC\\maria", new List<PrinterInfo> { KitchenSubmittedByTray(id) });

                await f.Coordinator.SyncOnceAsync(false, CancellationToken.None);

                PrinterInfo sent = f.Api.SyncRequests.Single().Impressoras.Single();
                Assert.Equal(id, sent.Identificador);
                Assert.Equal(PrinterConnection.Outro, sent.Conexao); // dado do Service
                Assert.Equal(PrinterStatus.Desconhecido, sent.Status); // dado do Service
            }
        }

        [Fact]
        public async Task TrayCannotReplaceIpPortStatusOrConnectionOfAPrinterSeenByTheService()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                string id = PrinterIdentifier.Compute("Cozinha", "IP_192.168.0.50", null, null);
                PrinterInfo real = new PrinterInfo { Identificador = id, Nome = "Cozinha", Conexao = PrinterConnection.Rede, Ip = "192.168.0.50", Porta = 9100, PortaWindows = "IP_192.168.0.50", Status = PrinterStatus.Offline };
                f.SetPrinters(real);
                // mais "completa" e com tudo diferente: mesmo assim não vale
                f.Coordinator.SubmitUserPrinters("PC\\maria", new List<PrinterInfo> { KitchenSubmittedByTray(id) });

                await f.Coordinator.SyncOnceAsync(false, CancellationToken.None);

                PrinterInfo sent = f.Api.SyncRequests.Single().Impressoras.Single();
                Assert.Equal("192.168.0.50", sent.Ip);
                Assert.Equal(9100, sent.Porta);
                Assert.Equal(PrinterStatus.Offline, sent.Status);
                Assert.Equal(PrinterConnection.Rede, sent.Conexao);
                Assert.Equal("IP_192.168.0.50", sent.PortaWindows);
            }
        }

        [Fact]
        public async Task APrinterOnlyTheTrayCanSeeStillEntersNormally()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                PrinterInfo sharedOnlyUser = Samples.Printer("\\\\SRV\\Etiquetas", PrinterConnection.Compartilhada, PrinterStatus.Disponivel, null, null, "\\\\SRV\\Etiquetas");
                f.SetPrinters(Samples.Usb("Balcao"));
                f.Coordinator.SubmitUserPrinters("PC\\maria", new List<PrinterInfo> { sharedOnlyUser });

                await f.Coordinator.SyncOnceAsync(false, CancellationToken.None);

                List<PrinterInfo> sent = f.Api.SyncRequests.Single().Impressoras;
                Assert.Equal(2, sent.Count);
                PrinterInfo fromTray = sent.Single(p => p.Nome == "\\\\SRV\\Etiquetas");
                Assert.Equal(sharedOnlyUser.Identificador, fromTray.Identificador);
                Assert.Equal(PrinterConnection.Compartilhada, fromTray.Conexao);
                Assert.Equal(PrinterStatus.Disponivel, fromTray.Status);
            }
        }

        [Fact]
        public async Task SamePrinterFromTwoUserSessionsNotSeenByTheServiceUsesTheMostCompleteVersion()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                string id = PrinterIdentifier.Compute("Cozinha", "IP_192.168.0.50", null, null);
                PrinterInfo poor = new PrinterInfo { Identificador = id, Nome = "Cozinha", Conexao = PrinterConnection.Outro, Status = PrinterStatus.Desconhecido };
                PrinterInfo rich = new PrinterInfo { Identificador = id, Nome = "Cozinha", Conexao = PrinterConnection.Rede, Ip = "192.168.0.50", Porta = 9100, PortaWindows = "IP_192.168.0.50", Status = PrinterStatus.Disponivel };

                f.SetPrinters(Samples.Usb("Balcao")); // o Service NÃO enxerga a Cozinha
                f.Coordinator.SubmitUserPrinters("PC\\maria", new List<PrinterInfo> { poor });
                f.Coordinator.SubmitUserPrinters("PC\\joao", new List<PrinterInfo> { rich });

                await f.Coordinator.SyncOnceAsync(false, CancellationToken.None);

                List<PrinterInfo> sent = f.Api.SyncRequests.Single().Impressoras;
                Assert.Equal(2, sent.Count);
                PrinterInfo kitchen = sent.Single(p => p.Nome == "Cozinha");
                Assert.Equal("192.168.0.50", kitchen.Ip);
                Assert.Equal(9100, kitchen.Porta);
            }
        }

        [Fact]
        public async Task DeduplicationStillWorksAcrossServiceAndSeveralTraySessions()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                string id = PrinterIdentifier.Compute("Cozinha", "IP_192.168.0.50", null, null);
                PrinterInfo counter = Samples.Usb("Balcao");
                PrinterInfo sharedOnlyUser = Samples.Printer("\\\\SRV\\Etiquetas", PrinterConnection.Compartilhada, PrinterStatus.Disponivel, null, null, "\\\\SRV\\Etiquetas");

                f.SetPrinters(KitchenSeenByService(id), counter);
                f.Coordinator.SubmitUserPrinters("PC\\maria", new List<PrinterInfo> { KitchenSubmittedByTray(id), sharedOnlyUser, counter });
                f.Coordinator.SubmitUserPrinters("PC\\joao", new List<PrinterInfo> { KitchenSubmittedByTray(id), sharedOnlyUser, counter });

                await f.Coordinator.SyncOnceAsync(false, CancellationToken.None);

                List<PrinterInfo> sent = f.Api.SyncRequests.Single().Impressoras;
                Assert.Equal(3, sent.Count);
                Assert.Equal(3, sent.Select(p => p.Identificador).Distinct().Count());
                Assert.Single(sent, p => p.Nome == "Cozinha");
                Assert.Single(sent, p => p.Nome == "Balcao");
                Assert.Single(sent, p => p.Nome == "\\\\SRV\\Etiquetas");
            }
        }

        [Fact]
        public async Task SharedPrintersSeenOnlyByTheServiceAreNeverLost()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                PrinterInfo shared = Samples.Printer("\\\\SRV\\Fiscal", PrinterConnection.Compartilhada, PrinterStatus.Disponivel, null, null, "\\\\SRV\\Fiscal");
                f.SetPrinters(shared);
                f.Coordinator.SubmitUserPrinters("PC\\maria", new List<PrinterInfo>()); // o Tray não viu nenhuma

                await f.Coordinator.SyncOnceAsync(false, CancellationToken.None);

                Assert.Equal(shared.Identificador, f.Api.SyncRequests.Single().Impressoras.Single().Identificador);
            }
        }

        [Fact]
        public async Task ListsFromSeveralUserSessionsAreAllIncluded()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                f.SetPrinters(Samples.Usb("Balcao"));
                f.Coordinator.SubmitUserPrinters("PC\\maria", new List<PrinterInfo> { Samples.Printer("Etiquetas Maria", PrinterConnection.Windows, PrinterStatus.Disponivel, null, null, "PM") });
                f.Coordinator.SubmitUserPrinters("PC\\joao", new List<PrinterInfo> { Samples.Printer("Etiquetas Joao", PrinterConnection.Windows, PrinterStatus.Disponivel, null, null, "PJ") });

                await f.Coordinator.SyncOnceAsync(false, CancellationToken.None);

                Assert.Equal(3, f.Api.SyncRequests.Single().Impressoras.Count);
            }
        }

        [Fact]
        public async Task NeverSendsMoreThanTheMaximumNumberOfPrinters()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                List<PrinterInfo> many = new List<PrinterInfo>();
                for (int i = 0; i < 150; i++) many.Add(Samples.Printer("P" + i.ToString("D3"), PrinterConnection.Windows, PrinterStatus.Disponivel, null, null, "X" + i));
                f.Discovery.Result = DiscoveryResult.Ok(many);

                await f.Coordinator.SyncOnceAsync(false, CancellationToken.None);

                Assert.Equal(AgentConstants.MaxPrintersPerSync, f.Api.SyncRequests.Single().Impressoras.Count);
            }
        }

        [Fact]
        public async Task SuccessfulSyncRecordsSummaryAndSchedulesTheNextOneInAboutThirtyMinutes()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                f.SetPrinters(Samples.Usb("Balcao"));
                f.Api.OnSync = ct =>
                {
                    SyncResponse r = new SyncResponse();
                    r.Recebidas = 1;
                    r.Validas = 1;
                    r.Novas = 1;
                    r.Ativas = 4;
                    return Task.FromResult(ApiResult<SyncResponse>.Success(r, 200));
                };

                SyncAttemptResult result = await f.Coordinator.SyncOnceAsync(false, CancellationToken.None);

                Assert.True(result.Synced);
                Assert.Equal(4, result.Summary!.Active);
                Assert.Equal(4, f.Coordinator.GetStatus().ImpressorasAtivas);
                Assertions.Seconds(AgentConstants.SyncInterval.TotalSeconds, f.Coordinator.NextSyncUtc - f.Clock.UtcNow, 1);
                Assert.False(f.Coordinator.SyncRequested);
            }
        }

        [Theory]
        [InlineData(ApiOutcome.NetworkError)]
        [InlineData(ApiOutcome.Timeout)]
        [InlineData(ApiOutcome.ServerError)]
        public async Task SyncFailuresKeepTheLinkAndRetryWithBackoff(ApiOutcome outcome)
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                f.Api.OnSync = ct => Task.FromResult(ApiResult<SyncResponse>.Failure(outcome, 0, null, null));

                SyncAttemptResult r = await f.Coordinator.SyncOnceAsync(false, CancellationToken.None);

                Assert.False(r.Synced);
                Assert.True(r.ServerCalled);
                Assert.True(f.Vault.HasCredential);
                Assertions.Seconds(15, f.Coordinator.NextSyncUtc - f.Clock.UtcNow, 0.5);
            }
        }

        [Fact]
        public async Task UnauthorizedSyncMarksTheCredentialRejectedButDoesNotDeleteIt()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                f.Api.OnSync = ct => Task.FromResult(ApiResult<SyncResponse>.Failure(ApiOutcome.Unauthorized, 401, "estacao_inativa", null));
                SyncAttemptResult r = await f.Coordinator.SyncOnceAsync(false, CancellationToken.None);
                Assert.Equal("credencial_recusada", r.ErrorCode);
                Assert.True(f.Vault.HasCredential);
                Assert.True(File.Exists(f.Paths.CredentialFile));
                Assert.Equal(AgentStatusKind.Erro, f.Coordinator.GetStatus().Estado);
            }
        }

        [Fact]
        public async Task RejectedListIsNotRetriedInATightLoop()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                f.Api.OnSync = ct => Task.FromResult(ApiResult<SyncResponse>.Failure(ApiOutcome.Rejected, 400, "limite_impressoras_estacao", null));
                await f.Coordinator.SyncOnceAsync(false, CancellationToken.None);
                Assertions.Seconds(AgentConstants.SyncInterval.TotalSeconds, f.Coordinator.NextSyncUtc - f.Clock.UtcNow, 1);
                Assert.False(f.Coordinator.SyncRequested);
            }
        }

        [Fact]
        public async Task NotLinkedScanDetectsPrintersButNeverCallsTheServer()
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                f.SetPrinters(Samples.Usb("Balcao"));

                SyncAttemptResult r = await f.Coordinator.SyncOnceAsync(true, CancellationToken.None);

                Assert.True(r.DiscoverySucceeded);
                Assert.False(r.ServerCalled);
                Assert.False(r.Synced);
                Assert.Equal("Balcao", r.Printers.Single().Nome);
                Assert.Equal(0, f.Api.SyncCalls);
                Assert.Equal("Balcao", f.Coordinator.GetPrinters().Single().Nome);
            }
        }

        [Fact]
        public async Task ScanPrintersReturnsThePrintersAndWhetherTheyWereSent()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                f.SetPrinters(Samples.Usb("Balcao"), Samples.Usb("Cozinha"));
                ControllerResult r = await f.Coordinator.ScanPrintersAsync(CancellationToken.None);
                Assert.True(r.Ok);
                ScanResultDto dto = Assert.IsType<ScanResultDto>(r.Data);
                Assert.Equal(2, dto.Impressoras.Count);
                Assert.True(dto.Sincronizado);
            }
        }

        [Fact]
        public async Task ManualScansAreRateLimited()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                f.SetPrinters(Samples.Usb("Balcao"));
                ControllerResult first = await f.Coordinator.ScanPrintersAsync(CancellationToken.None);
                ControllerResult second = await f.Coordinator.ScanPrintersAsync(CancellationToken.None);
                Assert.True(first.Ok);
                Assert.False(second.Ok);
                Assert.Equal("muitas_tentativas", second.Erro);
                Assert.Equal(1, f.Api.SyncCalls);

                f.Clock.Advance(AgentConstants.MinSpacingBetweenManualScans + TimeSpan.FromSeconds(1));
                ControllerResult third = await f.Coordinator.ScanPrintersAsync(CancellationToken.None);
                Assert.True(third.Ok);
            }
        }

        [Fact]
        public async Task ScanPrintersReportsDiscoveryFailureWithoutTouchingTheServer()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                f.Discovery.Result = DiscoveryResult.Fail("spooler parado");
                ControllerResult r = await f.Coordinator.ScanPrintersAsync(CancellationToken.None);
                Assert.False(r.Ok);
                Assert.Equal("falha_descoberta", r.Erro);
                Assert.Equal(0, f.Api.SyncCalls);
            }
        }

        [Fact]
        public async Task ScanWhileOfflineStillReturnsPrintersAndExplainsWhyTheyWereNotSent()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                f.SetPrinters(Samples.Usb("Balcao"));
                f.Api.OnSync = ct => Task.FromResult(ApiResult<SyncResponse>.Failure(ApiOutcome.NetworkError, 0, null, null));
                ControllerResult r = await f.Coordinator.ScanPrintersAsync(CancellationToken.None);
                Assert.True(r.Ok);
                ScanResultDto dto = Assert.IsType<ScanResultDto>(r.Data);
                Assert.False(dto.Sincronizado);
                Assert.Single(dto.Impressoras);
                Assert.False(string.IsNullOrEmpty(r.Mensagem));
            }
        }

        [Fact]
        public async Task SyncsNeverRunConcurrently()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                f.Api.OnSync = async ct =>
                {
                    await Task.Delay(150, ct);
                    return ApiResult<SyncResponse>.Success(new SyncResponse(), 200);
                };
                Task a = f.Coordinator.SyncOnceAsync(true, CancellationToken.None);
                Task b = f.Coordinator.SyncOnceAsync(true, CancellationToken.None);
                await Task.WhenAll(a, b);
                Assert.Equal(2, f.Api.SyncCalls);
                Assert.Equal(1, f.Api.MaxInFlight);
            }
        }

        [Fact]
        public void SubmittingAUserListRequestsASyncOnlyWhenTheListChanged()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                List<PrinterInfo> list = new List<PrinterInfo> { Samples.Usb("Balcao") };

                f.Coordinator.SubmitUserPrinters("PC\\maria", list);
                Assert.True(f.Coordinator.SyncRequested);

                Task<SyncAttemptResult> clear = f.Coordinator.SyncOnceAsync(false, CancellationToken.None);
                clear.GetAwaiter().GetResult();
                Assert.False(f.Coordinator.SyncRequested);

                f.Coordinator.SubmitUserPrinters("PC\\maria", new List<PrinterInfo> { Samples.Usb("Balcao") });
                Assert.False(f.Coordinator.SyncRequested);

                f.Coordinator.SubmitUserPrinters("PC\\maria", new List<PrinterInfo> { Samples.Usb("Balcao"), Samples.Usb("Cozinha") });
                Assert.True(f.Coordinator.SyncRequested);
            }
        }

        [Fact]
        public async Task OldUserListsExpire()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                f.SetPrinters(Samples.Usb("Balcao"));
                f.Coordinator.SubmitUserPrinters("PC\\maria", new List<PrinterInfo> { Samples.Printer("Etiquetas", PrinterConnection.Windows, PrinterStatus.Disponivel, null, null, "PX") });

                f.Clock.Advance(AgentConstants.UserPrintersMaxAge + TimeSpan.FromHours(1));
                await f.Coordinator.SyncOnceAsync(false, CancellationToken.None);

                Assert.Equal("Balcao", f.Api.SyncRequests.Single().Impressoras.Single().Nome);
            }
        }

        [Fact]
        public void UserListsSurviveARestartOfTheService()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                f.SetPrinters(Samples.Usb("Balcao"));
                f.Coordinator.SubmitUserPrinters("PC\\maria", new List<PrinterInfo> { Samples.Printer("Etiquetas", PrinterConnection.Windows, PrinterStatus.Disponivel, null, null, "PX") });

                f.Restart();
                f.Coordinator.SyncOnceAsync(false, CancellationToken.None).GetAwaiter().GetResult();

                Assert.Equal(2, f.Api.SyncRequests.Single().Impressoras.Count);
            }
        }

        [Fact]
        public void PrinterHashIgnoresOrderAndDetectsChanges()
        {
            PrinterInfo a = Samples.Usb("Balcao");
            PrinterInfo b = Samples.Usb("Cozinha");
            string h1 = AgentCoordinator.HashPrinters(new List<PrinterInfo> { a, b });
            string h2 = AgentCoordinator.HashPrinters(new List<PrinterInfo> { b, a });
            Assert.Equal(h1, h2);

            PrinterInfo changed = b.Clone();
            changed.Status = PrinterStatus.Offline;
            Assert.NotEqual(h1, AgentCoordinator.HashPrinters(new List<PrinterInfo> { a, changed }));
            Assert.Matches("^[0-9a-f]{64}$", h1);
        }
    }

    public class UnlinkTests
    {
        [Fact]
        public async Task SuccessRemovesTheCredentialButKeepsTheInstallationIdentity()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                string identity = new InstallationIdentityStore(f.Paths.IdentityFile).GetOrCreate();

                ControllerResult r = await f.Coordinator.UnlinkAsync(false, TestCallers.Admin, CancellationToken.None);

                Assert.True(r.Ok);
                Assert.Equal(1, f.Api.UnlinkCalls);
                Assert.Equal(TestTokens.Make(1).RevealForAuthorization(), f.Api.UnlinkTokens.Single());
                Assert.False(f.Vault.HasCredential);
                Assert.False(File.Exists(f.Paths.CredentialFile));
                Assert.True(File.Exists(f.Paths.IdentityFile));
                Assert.Equal(identity, new InstallationIdentityStore(f.Paths.IdentityFile).GetOrCreate());

                AgentStatusDto s = f.Coordinator.GetStatus();
                Assert.Equal(AgentStatusKind.NaoVinculado, s.Estado);
                Assert.False(s.Vinculado);
                Assert.Null(s.Empresa);
                Assert.Null(f.StateStore.Load().CompanyName);
            }
        }

        [Theory]
        [InlineData(ApiOutcome.NetworkError)]
        [InlineData(ApiOutcome.Timeout)]
        [InlineData(ApiOutcome.ServerError)]
        [InlineData(ApiOutcome.RateLimited)]
        [InlineData(ApiOutcome.InvalidResponse)]
        [InlineData(ApiOutcome.Rejected)]
        public async Task ServerFailureKeepsTheLinkAndReportsTheError(ApiOutcome outcome)
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                f.Api.OnUnlink = ct => Task.FromResult(ApiResult<EmptyResponse>.Failure(outcome, 0, null, null));

                ControllerResult r = await f.Coordinator.UnlinkAsync(false, TestCallers.Admin, CancellationToken.None);

                Assert.False(r.Ok);
                Assert.False(string.IsNullOrEmpty(r.Mensagem));
                Assert.True(f.Vault.HasCredential);
                Assert.True(File.Exists(f.Paths.CredentialFile));
                Assert.True(f.Coordinator.GetStatus().Vinculado);
            }
        }

        [Fact]
        public async Task UnauthorizedOnUnlinkKeepsTheCredentialAndAllowsAnExplicitLocalRemoval()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                f.Api.OnUnlink = ct => Task.FromResult(ApiResult<EmptyResponse>.Failure(ApiOutcome.Unauthorized, 401, "agente_revogado", null));

                ControllerResult first = await f.Coordinator.UnlinkAsync(false, TestCallers.Admin, CancellationToken.None);
                Assert.False(first.Ok);
                Assert.Equal("credencial_recusada", first.Erro);
                Assert.True(f.Vault.HasCredential);
                Assert.True(File.Exists(f.Paths.CredentialFile));

                ControllerResult forced = await f.Coordinator.UnlinkAsync(true, TestCallers.Admin, CancellationToken.None);
                Assert.True(forced.Ok);
                Assert.False(f.Vault.HasCredential);
                Assert.False(File.Exists(f.Paths.CredentialFile));
                Assert.Equal(1, f.Api.UnlinkCalls); // a remoção local forçada não chama o servidor
            }
        }

        [Fact]
        public async Task LocalOnlyRemovalIsRefusedWhileTheServerStillRecognizesTheLink()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                ControllerResult r = await f.Coordinator.UnlinkAsync(true, TestCallers.Admin, CancellationToken.None);
                Assert.False(r.Ok);
                Assert.Equal("forca_nao_permitida", r.Erro);
                Assert.True(f.Vault.HasCredential);
                Assert.Equal(0, f.Api.UnlinkCalls);
            }
        }

        [Fact]
        public async Task UnlinkWhenNotLinkedIsRefused()
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                ControllerResult r = await f.Coordinator.UnlinkAsync(false, TestCallers.Admin, CancellationToken.None);
                Assert.False(r.Ok);
                Assert.Equal("nao_vinculado", r.Erro);
                Assert.Equal(0, f.Api.UnlinkCalls);
            }
        }

        [Fact]
        public async Task PairingAgainAfterUnlinkReusesTheSameInstallationId()
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                await f.PairAsync("ABCD-2345");
                await f.Coordinator.UnlinkAsync(false, TestCallers.Admin, CancellationToken.None);
                await f.PairAsync("EFGH-6789");

                Assert.Equal(2, f.Api.ConfirmRequests.Count);
                Assert.Equal(f.Api.ConfirmRequests[0].IdentificadorInstalacao, f.Api.ConfirmRequests[1].IdentificadorInstalacao);
                Assert.Equal("EFGH-6789", f.Api.ConfirmRequests[1].Codigo);
                Assert.True(f.Vault.HasCredential);
            }
        }

        [Fact]
        public async Task UnlinkDoesNotRunWhileAnotherServerOperationIsInProgress()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                f.Api.OnHeartbeat = async ct => { await Task.Delay(150, ct); return CoordinatorFixture.HbOk(); };
                Task hb = f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                Task<ControllerResult> unlink = f.Coordinator.UnlinkAsync(false, TestCallers.Admin, CancellationToken.None);
                await Task.WhenAll(hb, unlink);
                Assert.Equal(1, f.Api.MaxInFlight);
                Assert.True(unlink.Result.Ok);
            }
        }
    }
}
