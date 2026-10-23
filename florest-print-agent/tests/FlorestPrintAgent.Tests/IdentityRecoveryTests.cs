using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using FlorestPrintAgent.Core;
using FlorestPrintAgent.Core.Agent;
using FlorestPrintAgent.Core.Storage;
using FlorestPrintAgent.Tests.TestSupport;
using Xunit;

namespace FlorestPrintAgent.Tests
{
    /// <summary>
    /// Identidade da instalação: uma identidade NOVA nunca é criada em silêncio quando já existe um vínculo (credencial)
    /// preso à identidade antiga — isso causaria "instalacao_divergente". Primeira instalação limpa continua usando Guid.NewGuid().
    /// </summary>
    public class IdentityWithLinkEvidenceTests
    {
        private static InstallationIdentityStore Store(string file, bool linkExists)
        {
            return new InstallationIdentityStore(file, () => linkExists);
        }

        [Fact]
        public void CleanFirstInstallCreatesANewIdentityAndABackup()
        {
            using (TempDir dir = new TempDir())
            {
                string file = dir.File("data/instalacao.json");

                string id = Store(file, false).GetOrCreate();

                Assert.True(Guid.TryParse(id, out Guid parsed));
                Assert.NotEqual(Guid.Empty, parsed);
                Assert.True(File.Exists(file));
                Assert.True(File.Exists(file + ".bak"));
                Assert.Equal(id, Store(file, false).GetOrCreate());
            }
        }

        [Fact]
        public void IdentityRecoveredFromTheBackupKeepsTheSameIdEvenWithAnExistingLink()
        {
            using (TempDir dir = new TempDir())
            {
                string file = dir.File("instalacao.json");
                string original = Store(file, false).GetOrCreate();
                File.WriteAllText(file, "{ corrompido");

                string recovered = Store(file, true).GetOrCreate();

                Assert.Equal(original, recovered);
                Assert.Equal(original, Store(file, true).GetOrCreate()); // o principal foi reparado
            }
        }

        [Fact]
        public void MainAbsentButBackupValidRestoresTheSameIdWithAnExistingLink()
        {
            using (TempDir dir = new TempDir())
            {
                string file = dir.File("instalacao.json");
                string original = Store(file, false).GetOrCreate();
                File.Delete(file);

                Assert.Equal(original, Store(file, true).GetOrCreate());
                Assert.True(File.Exists(file));
            }
        }

        [Fact]
        public void CorruptIdentityAndCorruptBackupWithAnExistingLinkIsARecoverableErrorAndCreatesNothing()
        {
            using (TempDir dir = new TempDir())
            {
                string file = dir.File("instalacao.json");
                File.WriteAllText(file, "lixo principal");
                File.WriteAllText(file + ".bak", "lixo backup");
                string[] before = Directory.GetFiles(dir.Path).OrderBy(x => x, StringComparer.Ordinal).ToArray();

                IdentityProblemException ex = Assert.Throws<IdentityProblemException>(() => Store(file, true).GetOrCreate());

                Assert.False(ex.Transient);
                Assert.Equal(InstallationIdentityStore.RecoveryMessage, ex.Message);
                // nenhuma identidade nova, nada movido para quarentena, nada sobrescrito
                string[] after = Directory.GetFiles(dir.Path).OrderBy(x => x, StringComparer.Ordinal).ToArray();
                Assert.Equal(before, after);
                Assert.Equal("lixo principal", File.ReadAllText(file));
                Assert.Equal("lixo backup", File.ReadAllText(file + ".bak"));
            }
        }

        [Fact]
        public void MissingIdentityAndBackupWithAnExistingLinkIsARecoverableErrorAndCreatesNothing()
        {
            using (TempDir dir = new TempDir())
            {
                string file = dir.File("instalacao.json");

                IdentityProblemException ex = Assert.Throws<IdentityProblemException>(() => Store(file, true).GetOrCreate());

                Assert.False(ex.Transient);
                Assert.False(File.Exists(file));
                Assert.False(File.Exists(file + ".bak"));
            }
        }

        [Fact]
        public void CorruptIdentityWithoutAnyLinkStillGeneratesANewOneAndKeepsTheEvidence()
        {
            using (TempDir dir = new TempDir())
            {
                string file = dir.File("instalacao.json");
                File.WriteAllText(file, "lixo");

                string id = Store(file, false).GetOrCreate();

                Assert.True(InstallationIdentityStore.IsValidId(id));
                Assert.Contains(Directory.GetFiles(dir.Path), f => f.Contains(".corrompido-", StringComparison.Ordinal));
            }
        }

        [Fact]
        public void AfterTheLinkIsGoneTheIdentityCanBeCreatedAgain()
        {
            using (TempDir dir = new TempDir())
            {
                string file = dir.File("instalacao.json");
                bool link = true;
                InstallationIdentityStore store = new InstallationIdentityStore(file, () => link);
                Assert.Throws<IdentityProblemException>(() => store.GetOrCreate());

                link = false; // vínculo removido (remoção local explícita)
                string id = store.GetOrCreate();

                Assert.True(InstallationIdentityStore.IsValidId(id));
                Assert.Equal(id, store.GetOrCreate());
            }
        }

        [Fact]
        public void IfTheLinkCheckItselfFailsTheStoreAssumesALinkExists()
        {
            using (TempDir dir = new TempDir())
            {
                string file = dir.File("instalacao.json");
                InstallationIdentityStore store = new InstallationIdentityStore(file, () => throw new IOException("sem acesso"));

                Assert.Throws<IdentityProblemException>(() => store.GetOrCreate());
                Assert.False(File.Exists(file));
            }
        }

        [Fact]
        public void ALinkEvidenceIsIrrelevantWhileTheIdentityIsHealthy()
        {
            using (TempDir dir = new TempDir())
            {
                string file = dir.File("instalacao.json");
                string id = Store(file, false).GetOrCreate();
                Assert.Equal(id, Store(file, true).GetOrCreate());
            }
        }
    }

    /// <summary>O coordenador, ao receber um problema de identidade, não fala com o servidor e só sai dele de forma segura.</summary>
    public class CoordinatorIdentityProblemTests
    {
        private const string RecoveredId = "99999999-0000-4000-8000-000000000001";

        private static CoordinatorFixture LinkedWithBrokenIdentity(out InstallationIdentityStore store)
        {
            CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1), false);
            string idFile = f.Paths.IdentityFile;
            Directory.CreateDirectory(Path.GetDirectoryName(idFile)!);
            File.WriteAllText(idFile, "lixo principal");
            File.WriteAllText(idFile + ".bak", "lixo backup");

            string credentialFile = f.Paths.CredentialFile;
            InstallationIdentityStore s = new InstallationIdentityStore(idFile, () => File.Exists(credentialFile));
            store = s;
            IdentityProblemException ex = Assert.Throws<IdentityProblemException>(() => s.GetOrCreate());
            f.Coordinator.SetIdentityProblem(ex.Message, s.GetOrCreate);
            f.Start();
            return f;
        }

        [Fact]
        public async Task NoServerCallIsMadeWhileTheIdentityIsUnresolved()
        {
            InstallationIdentityStore store;
            using (CoordinatorFixture f = LinkedWithBrokenIdentity(out store))
            {
                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                await f.Coordinator.RenewOnceAsync(CancellationToken.None);
                await f.Coordinator.SyncOnceAsync(false, CancellationToken.None);
                ControllerResult verify = await f.Coordinator.VerifyPairingAsync("ABCD-2345", TestCallers.Alice, CancellationToken.None);
                ControllerResult confirm = await f.Coordinator.ConfirmPairingAsync("ABCD-2345", TestCallers.Alice, CancellationToken.None);

                Assert.Equal(0, f.Api.HeartbeatCalls);
                Assert.Equal(0, f.Api.RenewCalls);
                Assert.Equal(0, f.Api.SyncCalls);
                Assert.Equal(0, f.Api.VerifyCalls);
                Assert.Equal(0, f.Api.ConfirmCalls);
                Assert.Equal("identidade_invalida", verify.Erro);
                Assert.Equal("identidade_invalida", confirm.Erro);

                AgentStatusDto status = f.Coordinator.GetStatus();
                Assert.Equal(AgentStatusKind.Erro, status.Estado);
                Assert.True(status.Vinculado);
                Assert.Equal(InstallationIdentityStore.RecoveryMessage, status.Mensagem);

                // nada foi criado nem apagado
                Assert.True(File.Exists(f.Paths.CredentialFile));
                Assert.Equal("lixo principal", File.ReadAllText(f.Paths.IdentityFile));
            }
        }

        [Fact]
        public async Task OnlyAnAuthorizedCallerCanRemoveTheLocalLinkAndAFreshIdentityIsThenCreated()
        {
            InstallationIdentityStore store;
            using (CoordinatorFixture f = LinkedWithBrokenIdentity(out store))
            {
                // sem permissão: nada muda
                ControllerResult denied = await f.Coordinator.UnlinkAsync(true, TestCallers.Bob, CancellationToken.None);
                Assert.Equal("acesso_negado", denied.Erro);
                Assert.True(File.Exists(f.Paths.CredentialFile));

                // sem pedir remoção explícita, o erro de identidade é informado (e o servidor não é consultado)
                ControllerResult soft = await f.Coordinator.UnlinkAsync(false, TestCallers.Admin, CancellationToken.None);
                Assert.Equal("identidade_invalida", soft.Erro);
                Assert.Equal(0, f.Api.UnlinkCalls);
                Assert.True(File.Exists(f.Paths.CredentialFile));

                // Administrador elevado pede a remoção local: só agora a credencial some e a identidade é recriada
                ControllerResult removed = await f.Coordinator.UnlinkAsync(true, TestCallers.Admin, CancellationToken.None);
                Assert.True(removed.Ok);
                Assert.Equal(0, f.Api.UnlinkCalls); // nunca foi ao servidor com identidade inválida
                Assert.False(File.Exists(f.Paths.CredentialFile));
                Assert.False(f.Vault.HasCredential);

                string newId = store.GetOrCreate();
                Assert.True(InstallationIdentityStore.IsValidId(newId));
                Assert.Equal(AgentStatusKind.NaoVinculado, f.Coordinator.GetStatus().Estado);

                // e o próximo pareamento já usa a identidade nova
                ControllerResult paired = await f.PairAsync("ABCD-2345", TestCallers.Alice);
                Assert.True(paired.Ok);
                Assert.Equal(newId, f.Api.ConfirmRequests.Single().IdentificadorInstalacao);
            }
        }

        [Fact]
        public async Task ATemporaryIdentityProblemResolvesByItselfAndThenTheRealIdIsUsed()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1), false))
            {
                f.Coordinator.SetIdentityProblem(InstallationIdentityStore.TransientMessage, () => RecoveredId);
                f.Start();
                Assert.Equal(AgentStatusKind.Erro, f.Coordinator.GetStatus().Estado);

                using (CancellationTokenSource cts = new CancellationTokenSource(TimeSpan.FromSeconds(20)))
                {
                    Task run = f.Coordinator.RunAsync(cts.Token);
                    DateTime limit = DateTime.UtcNow.AddSeconds(15);
                    while (f.Api.HeartbeatCalls == 0 && DateTime.UtcNow < limit) await Task.Delay(50);
                    cts.Cancel();
                    await run;
                }

                Assert.True(f.Api.HeartbeatCalls >= 1);
                Assert.All(f.Api.InstallationIdsSeen, id => Assert.Equal(RecoveredId, id));
                Assert.NotEqual(AgentStatusKind.Erro, f.Coordinator.GetStatus().Estado);
            }
        }
    }
}
