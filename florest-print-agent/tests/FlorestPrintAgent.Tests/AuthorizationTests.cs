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
using FlorestPrintAgent.Core.Ipc;
using FlorestPrintAgent.Core.Printers;
using FlorestPrintAgent.Core.Storage;
using FlorestPrintAgent.Tests.TestSupport;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace FlorestPrintAgent.Tests
{
    /// <summary>
    /// Pareamento em duas etapas: o PairConfirm só vale para o MESMO chamador (usuário + sessão do Windows) que verificou o
    /// MESMO código há pouco. Outra sessão local não intercepta, reaproveita nem sequestra o fluxo.
    /// </summary>
    public class PairingIsolationTests
    {
        private const string Code = "ABCD-2345";

        [Fact]
        public async Task ConfirmWithoutAPreviousVerifyIsRefusedAndNeverReachesTheServer()
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                ControllerResult r = await f.Coordinator.ConfirmPairingAsync(Code, TestCallers.Alice, CancellationToken.None);

                Assert.False(r.Ok);
                Assert.Equal("pareamento_nao_verificado", r.Erro);
                Assert.Equal(0, f.Api.ConfirmCalls);
                Assert.False(f.Vault.HasCredential);
            }
        }

        [Fact]
        public async Task AnotherWindowsUserCannotConfirmWhatAliceVerified()
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                Assert.True((await f.Coordinator.VerifyPairingAsync(Code, TestCallers.Alice, CancellationToken.None)).Ok);

                ControllerResult hijack = await f.Coordinator.ConfirmPairingAsync(Code, TestCallers.Bob, CancellationToken.None);

                Assert.False(hijack.Ok);
                Assert.Equal("pareamento_nao_verificado", hijack.Erro);
                Assert.Equal(0, f.Api.ConfirmCalls);
                Assert.False(f.Vault.HasCredential);

                // a verificação da Alice continua valendo para ela
                ControllerResult mine = await f.Coordinator.ConfirmPairingAsync(Code, TestCallers.Alice, CancellationToken.None);
                Assert.True(mine.Ok);
                Assert.Equal(1, f.Api.ConfirmCalls);
            }
        }

        [Fact]
        public async Task AnotherSessionOfTheSameUserCannotConfirmEither()
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                await f.Coordinator.VerifyPairingAsync(Code, TestCallers.Alice, CancellationToken.None);

                ControllerResult r = await f.Coordinator.ConfirmPairingAsync(Code, TestCallers.AliceOtherSession, CancellationToken.None);

                Assert.False(r.Ok);
                Assert.Equal("pareamento_nao_verificado", r.Erro);
                Assert.Equal(0, f.Api.ConfirmCalls);
            }
        }

        [Fact]
        public async Task ConfirmWithADifferentCodeThanTheVerifiedOneIsRefused()
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                await f.Coordinator.VerifyPairingAsync(Code, TestCallers.Alice, CancellationToken.None);

                ControllerResult r = await f.Coordinator.ConfirmPairingAsync("EFGH-6789", TestCallers.Alice, CancellationToken.None);

                Assert.False(r.Ok);
                Assert.Equal("pareamento_nao_verificado", r.Erro);
                Assert.Equal(0, f.Api.ConfirmCalls);
            }
        }

        [Fact]
        public async Task ASecondUserCannotStartPairingWhileAnotherUsersIsInProgress()
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                Assert.True((await f.Coordinator.VerifyPairingAsync(Code, TestCallers.Alice, CancellationToken.None)).Ok);

                ControllerResult bob = await f.Coordinator.VerifyPairingAsync("EFGH-6789", TestCallers.Bob, CancellationToken.None);

                Assert.False(bob.Ok);
                Assert.Equal("pareamento_em_andamento", bob.Erro);
                Assert.Equal(1, f.Api.VerifyCalls); // o pedido do Bob nem chegou ao servidor
            }
        }

        [Fact]
        public async Task TheVerificationExpiresAndThenAnotherUserMayPair()
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                await f.Coordinator.VerifyPairingAsync(Code, TestCallers.Alice, CancellationToken.None);
                f.Clock.Advance(AgentConstants.PairingVerifyTtl + TimeSpan.FromSeconds(1));

                // expirou: nem a Alice confirma sem verificar de novo...
                ControllerResult late = await f.Coordinator.ConfirmPairingAsync(Code, TestCallers.Alice, CancellationToken.None);
                Assert.Equal("pareamento_nao_verificado", late.Erro);

                // ...e o Bob já pode começar o dele
                ControllerResult bob = await f.PairAsync("EFGH-6789", TestCallers.Bob);
                Assert.True(bob.Ok);
                Assert.True(f.Vault.HasCredential);
            }
        }

        [Fact]
        public async Task AFailedVerifyByTheOwnerInvalidatesHerPreviousVerification()
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                await f.Coordinator.VerifyPairingAsync(Code, TestCallers.Alice, CancellationToken.None);
                f.Api.OnVerify = ct => Task.FromResult(ApiResult<PairVerifyResponse>.Failure(ApiOutcome.Rejected, 400, "codigo_invalido", null));
                await f.Coordinator.VerifyPairingAsync("EFGH-6789", TestCallers.Alice, CancellationToken.None);

                ControllerResult r = await f.Coordinator.ConfirmPairingAsync(Code, TestCallers.Alice, CancellationToken.None);

                Assert.Equal("pareamento_nao_verificado", r.Erro);
                Assert.Equal(0, f.Api.ConfirmCalls);
            }
        }

        [Fact]
        public async Task ADefinitiveServerRefusalRequiresANewVerification()
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                await f.Coordinator.VerifyPairingAsync(Code, TestCallers.Alice, CancellationToken.None);
                f.Api.OnConfirm = ct => Task.FromResult(ApiResult<PairConfirmResponse>.Failure(ApiOutcome.Rejected, 400, "codigo_invalido", null));
                ControllerResult first = await f.Coordinator.ConfirmPairingAsync(Code, TestCallers.Alice, CancellationToken.None);
                Assert.Equal("codigo_invalido", first.Erro);

                ControllerResult again = await f.Coordinator.ConfirmPairingAsync(Code, TestCallers.Alice, CancellationToken.None);

                Assert.Equal("pareamento_nao_verificado", again.Erro);
                Assert.Equal(1, f.Api.ConfirmCalls);
            }
        }

        [Fact]
        public async Task ANetworkFailureOnConfirmKeepsTheVerificationSoTheUserCanRetry()
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                await f.Coordinator.VerifyPairingAsync(Code, TestCallers.Alice, CancellationToken.None);
                f.Api.OnConfirm = ct => Task.FromResult(ApiResult<PairConfirmResponse>.Failure(ApiOutcome.NetworkError, 0, null, null));
                ControllerResult offline = await f.Coordinator.ConfirmPairingAsync(Code, TestCallers.Alice, CancellationToken.None);
                Assert.Equal("sem_conexao", offline.Erro);

                f.Api.OnConfirm = new FakeEdgeApi().OnConfirm;
                ControllerResult retry = await f.Coordinator.ConfirmPairingAsync(Code, TestCallers.Alice, CancellationToken.None);

                Assert.True(retry.Ok);
                Assert.Equal(1, f.Api.VerifyCalls);
                Assert.Equal(2, f.Api.ConfirmCalls);
            }
        }

        [Fact]
        public async Task ASuccessfulPairingIsRecordedForTheOwnerAndCannotBeRepeated()
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                Assert.True((await f.PairAsync(Code, TestCallers.Alice)).Ok);

                string state = File.ReadAllText(f.Paths.StateFile);
                Assert.Contains(TestCallers.AliceSid, state, StringComparison.Ordinal);

                ControllerResult again = await f.Coordinator.ConfirmPairingAsync(Code, TestCallers.Alice, CancellationToken.None);
                Assert.Equal("ja_vinculado", again.Erro);
            }
        }

        [Fact]
        public async Task ThePairingCodeIsNeverOnDiskWhileWaitingForConfirmationNorInTheLog()
        {
            CapturingLogger log = new CapturingLogger();
            using (CoordinatorFixture f = new CoordinatorFixture(null, true, null, log))
            {
                f.SetPrinters(Samples.Usb("Balcao"));

                // etapa 1 feita, etapa 2 ainda não: o código só pode existir em memória
                await f.Coordinator.VerifyPairingAsync(Code, TestCallers.Alice, CancellationToken.None);
                AssertNoCodeOnDisk(f);

                // tentativas recusadas também não podem registrar o código
                await f.Coordinator.ConfirmPairingAsync(Code, TestCallers.Bob, CancellationToken.None);
                await f.Coordinator.VerifyPairingAsync("EFGH-6789", TestCallers.Bob, CancellationToken.None);

                await f.Coordinator.ConfirmPairingAsync(Code, TestCallers.Alice, CancellationToken.None);
                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                await f.Coordinator.SyncOnceAsync(false, CancellationToken.None);
                await f.Coordinator.UnlinkAsync(false, TestCallers.Alice, CancellationToken.None);

                AssertNoCodeOnDisk(f);

                string logs = log.All();
                Assert.NotEmpty(log.Lines);
                string secret = TestTokens.Make(1).RevealForAuthorization();
                secret = secret.Substring(secret.IndexOf('.') + 1);
                Assert.DoesNotContain(Code, logs, StringComparison.OrdinalIgnoreCase);
                Assert.DoesNotContain("EFGH-6789", logs, StringComparison.OrdinalIgnoreCase);
                Assert.DoesNotContain("ABCD2345", logs, StringComparison.OrdinalIgnoreCase);
                Assert.DoesNotContain(secret, logs, StringComparison.Ordinal);
                Assert.DoesNotContain("fpa_", logs, StringComparison.OrdinalIgnoreCase);
                Assert.DoesNotContain("Bearer", logs, StringComparison.OrdinalIgnoreCase);
            }
        }

        private static void AssertNoCodeOnDisk(CoordinatorFixture f)
        {
            foreach (string file in Directory.GetFiles(f.Dir.Path, "*", SearchOption.AllDirectories))
            {
                string text = Encoding.UTF8.GetString(File.ReadAllBytes(file));
                Assert.DoesNotContain(Code, text, StringComparison.OrdinalIgnoreCase);
                Assert.DoesNotContain("ABCD2345", text, StringComparison.OrdinalIgnoreCase);
                Assert.DoesNotContain("EFGH-6789", text, StringComparison.OrdinalIgnoreCase);
            }
        }
    }

    /// <summary>Desvincular é destrutivo: só o usuário que conectou o computador, um Administrador elevado ou SYSTEM.</summary>
    public class UnlinkAuthorizationTests
    {
        [Fact]
        public async Task AnotherLocalUserCannotUnlinkAndNothingIsSentToTheServer()
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                await f.PairAsync("ABCD-2345", TestCallers.Alice);

                ControllerResult r = await f.Coordinator.UnlinkAsync(false, TestCallers.Bob, CancellationToken.None);

                Assert.False(r.Ok);
                Assert.Equal("acesso_negado", r.Erro);
                Assert.Equal(0, f.Api.UnlinkCalls);
                Assert.True(f.Vault.HasCredential);
                Assert.True(File.Exists(f.Paths.CredentialFile));
                Assert.True(f.Coordinator.GetStatus().Vinculado);
            }
        }

        [Fact]
        public async Task AnotherLocalUserCannotForceALocalRemovalEither()
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                await f.PairAsync("ABCD-2345", TestCallers.Alice);
                f.Api.OnHeartbeat = ct => Task.FromResult(CoordinatorFixture.HbFail(ApiOutcome.Unauthorized, 401, "agente_revogado"));
                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None); // credencial recusada: a remoção forçada passa a existir

                ControllerResult r = await f.Coordinator.UnlinkAsync(true, TestCallers.Bob, CancellationToken.None);

                Assert.Equal("acesso_negado", r.Erro);
                Assert.True(f.Vault.HasCredential);
                Assert.True(File.Exists(f.Paths.CredentialFile));
            }
        }

        [Fact]
        public async Task TheUserWhoPairedTheComputerCanUnlinkIt()
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                await f.PairAsync("ABCD-2345", TestCallers.Alice);

                ControllerResult r = await f.Coordinator.UnlinkAsync(false, TestCallers.Alice, CancellationToken.None);

                Assert.True(r.Ok);
                Assert.Equal(1, f.Api.UnlinkCalls);
                Assert.False(f.Vault.HasCredential);
                Assert.False(File.Exists(f.Paths.CredentialFile));
            }
        }

        [Fact]
        public async Task AnElevatedAdministratorCanUnlinkAComputerPairedByAnotherUser()
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                await f.PairAsync("ABCD-2345", TestCallers.Alice);

                ControllerResult r = await f.Coordinator.UnlinkAsync(false, TestCallers.Admin, CancellationToken.None);

                Assert.True(r.Ok);
                Assert.False(f.Vault.HasCredential);
            }
        }

        [Fact]
        public async Task LocalSystemCanUnlink()
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                await f.PairAsync("ABCD-2345", TestCallers.Alice);
                ControllerResult r = await f.Coordinator.UnlinkAsync(false, TestCallers.LocalSystem, CancellationToken.None);
                Assert.True(r.Ok);
            }
        }

        [Fact]
        public async Task WithoutARecordedOwnerOnlyAnAdministratorCanUnlink()
        {
            // vínculo anterior a esta regra (sem dono registrado): ninguém "comum" é dono
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                ControllerResult denied = await f.Coordinator.UnlinkAsync(false, TestCallers.Alice, CancellationToken.None);
                Assert.Equal("acesso_negado", denied.Erro);
                Assert.Equal(0, f.Api.UnlinkCalls);

                ControllerResult ok = await f.Coordinator.UnlinkAsync(false, TestCallers.Admin, CancellationToken.None);
                Assert.True(ok.Ok);
            }
        }

        [Fact]
        public async Task TheOwnerOfflineUnlinkDoesNotPretendAndKeepsTheLink()
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                await f.PairAsync("ABCD-2345", TestCallers.Alice);
                f.Api.OnUnlink = ct => Task.FromResult(ApiResult<EmptyResponse>.Failure(ApiOutcome.NetworkError, 0, null, null));

                ControllerResult r = await f.Coordinator.UnlinkAsync(false, TestCallers.Alice, CancellationToken.None);

                Assert.False(r.Ok);
                Assert.Equal("sem_conexao", r.Erro);
                Assert.Equal(1, f.Api.UnlinkCalls);
                Assert.True(f.Vault.HasCredential);
                Assert.True(File.Exists(f.Paths.CredentialFile));
            }
        }

        [Fact]
        public async Task TheOwnerSurvivesAServiceRestartAndOthersStillCannotUnlink()
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                await f.PairAsync("ABCD-2345", TestCallers.Alice);
                f.Restart();

                Assert.Equal("acesso_negado", (await f.Coordinator.UnlinkAsync(false, TestCallers.Bob, CancellationToken.None)).Erro);
                Assert.True((await f.Coordinator.UnlinkAsync(false, TestCallers.Alice, CancellationToken.None)).Ok);
            }
        }

        [Fact]
        public async Task AfterUnlinkingTheNextPairingBelongsToTheNewUser()
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                await f.PairAsync("ABCD-2345", TestCallers.Alice);
                await f.Coordinator.UnlinkAsync(false, TestCallers.Alice, CancellationToken.None);
                await f.PairAsync("EFGH-6789", TestCallers.Bob);

                Assert.Equal("acesso_negado", (await f.Coordinator.UnlinkAsync(false, TestCallers.Alice, CancellationToken.None)).Erro);
                Assert.True((await f.Coordinator.UnlinkAsync(false, TestCallers.Bob, CancellationToken.None)).Ok);
            }
        }
    }

    /// <summary>Os mesmos limites vistos pela camada do pipe (IpcCommandHandler) e garantia de que nada sensível sai pelas respostas.</summary>
    public class IpcAuthorizationAndLeakTests
    {
        private static IpcRequest Req(string cmd, string? code = null)
        {
            IpcRequest r = new IpcRequest();
            r.Cmd = cmd;
            r.Codigo = code;
            return r;
        }

        [Fact]
        public async Task UnauthorizedUnlinkThroughThePipeLayerIsRefused()
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                IpcCommandHandler handler = new IpcCommandHandler(f.Coordinator, NullLogger.Instance);
                await handler.HandleAsync(Req(IpcCommands.PairVerify, "abcd-2345"), TestCallers.Alice, CancellationToken.None);
                IpcResponse paired = await handler.HandleAsync(Req(IpcCommands.PairConfirm, "abcd-2345"), TestCallers.Alice, CancellationToken.None);
                Assert.True(paired.Ok);

                IpcRequest unlink = Req(IpcCommands.Unlink);
                IpcResponse denied = await handler.HandleAsync(unlink, TestCallers.Bob, CancellationToken.None);
                unlink.Forcar = true;
                IpcResponse deniedForced = await handler.HandleAsync(unlink, TestCallers.Bob, CancellationToken.None);

                Assert.False(denied.Ok);
                Assert.Equal("acesso_negado", denied.Erro);
                Assert.Equal("acesso_negado", deniedForced.Erro);
                Assert.Equal(0, f.Api.UnlinkCalls);
                Assert.True(f.Vault.HasCredential);
            }
        }

        [Fact]
        public async Task PairingInterceptionThroughThePipeLayerIsRefused()
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                IpcCommandHandler handler = new IpcCommandHandler(f.Coordinator, NullLogger.Instance);
                IpcResponse verify = await handler.HandleAsync(Req(IpcCommands.PairVerify, "ABCD-2345"), TestCallers.Alice, CancellationToken.None);
                Assert.True(verify.Ok);

                IpcResponse stolen = await handler.HandleAsync(Req(IpcCommands.PairConfirm, "ABCD-2345"), TestCallers.Bob, CancellationToken.None);

                Assert.False(stolen.Ok);
                Assert.Equal("pareamento_nao_verificado", stolen.Erro);
                Assert.False(f.Vault.HasCredential);
            }
        }

        [Fact]
        public async Task NoIpcResponseEverCarriesTheTokenOrASecret()
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                f.SetPrinters(Samples.Usb("Balcao"), Samples.Usb("Cozinha"));
                IpcCommandHandler handler = new IpcCommandHandler(f.Coordinator, NullLogger.Instance);

                List<IpcResponse> responses = new List<IpcResponse>();
                responses.Add(await handler.HandleAsync(Req(IpcCommands.GetStatus), TestCallers.Alice, CancellationToken.None));
                responses.Add(await handler.HandleAsync(Req(IpcCommands.PairVerify, "ABCD-2345"), TestCallers.Alice, CancellationToken.None));
                responses.Add(await handler.HandleAsync(Req(IpcCommands.PairConfirm, "ABCD-2345"), TestCallers.Alice, CancellationToken.None));
                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                responses.Add(await handler.HandleAsync(Req(IpcCommands.GetStatus), TestCallers.Alice, CancellationToken.None));
                responses.Add(await handler.HandleAsync(Req(IpcCommands.GetPrinters), TestCallers.Alice, CancellationToken.None));
                responses.Add(await handler.HandleAsync(Req(IpcCommands.ScanPrinters), TestCallers.Alice, CancellationToken.None));
                IpcRequest submit = Req(IpcCommands.SubmitUserPrinters);
                submit.Impressoras = new List<PrinterInfo> { Samples.Usb("Etiquetas") };
                responses.Add(await handler.HandleAsync(submit, TestCallers.Alice, CancellationToken.None));
                responses.Add(await handler.HandleAsync(Req(IpcCommands.Unlink), TestCallers.Bob, CancellationToken.None)); // negado
                responses.Add(await handler.HandleAsync(Req(IpcCommands.Unlink), TestCallers.Alice, CancellationToken.None));
                responses.Add(await handler.HandleAsync(Req(IpcCommands.PairConfirm, "ZZZZ-9999"), TestCallers.Alice, CancellationToken.None)); // falha

                string full = TestTokens.Make(1).RevealForAuthorization();
                string secret = full.Substring(full.IndexOf('.') + 1);
                Assert.True(responses.Count >= 10);
                foreach (IpcResponse r in responses)
                {
                    string json = Encoding.UTF8.GetString(IpcSerializer.Serialize(r));
                    Assert.DoesNotContain(full, json, StringComparison.Ordinal);
                    Assert.DoesNotContain(secret, json, StringComparison.Ordinal);
                    Assert.DoesNotContain("fpa_", json, StringComparison.OrdinalIgnoreCase);
                    Assert.DoesNotContain("token", json, StringComparison.OrdinalIgnoreCase);
                    Assert.DoesNotContain("authorization", json, StringComparison.OrdinalIgnoreCase);
                    Assert.DoesNotContain("bearer", json, StringComparison.OrdinalIgnoreCase);
                }
            }
        }
    }

    public class CallerIdentityTests
    {
        [Fact]
        public void KeyCombinesUserAndSession()
        {
            Assert.NotEqual(TestCallers.Alice.Key, TestCallers.AliceOtherSession.Key);
            Assert.NotEqual(TestCallers.Alice.Key, TestCallers.Bob.Key);
            Assert.Equal(TestCallers.Alice.Key, new CallerIdentity(TestCallers.AliceSid, 1, false, false).Key);
        }

        [Fact]
        public void SameUserComparesSidsIgnoringCaseAndHandlesNull()
        {
            Assert.True(TestCallers.Alice.SameUser(TestCallers.AliceSid.ToLowerInvariant()));
            Assert.False(TestCallers.Alice.SameUser(TestCallers.BobSid));
            Assert.False(TestCallers.Alice.SameUser(null));
        }

        [Theory]
        [InlineData("")]
        [InlineData("   ")]
        public void AnInvalidSidIsRejected(string sid)
        {
            Assert.Throws<ArgumentException>(() => new CallerIdentity(sid, 1, false, false));
        }

        [Fact]
        public void AnAbsurdlyLongSidIsRejected()
        {
            Assert.Throws<ArgumentException>(() => new CallerIdentity(new string('S', 500), 1, false, false));
        }
    }
}
