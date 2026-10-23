using System;
using System.IO;
using System.Linq;
using System.Text;
using FlorestPrintAgent.Core;
using FlorestPrintAgent.Core.Printers;
using FlorestPrintAgent.Core.Security;
using FlorestPrintAgent.Core.Storage;
using FlorestPrintAgent.Tests.TestSupport;
using Xunit;

namespace FlorestPrintAgent.Tests
{
    public class InstallationIdentityStoreTests
    {
        [Fact]
        public void CreatesAValidGuidOnFirstUse()
        {
            using (TempDir dir = new TempDir())
            {
                InstallationIdentityStore store = new InstallationIdentityStore(dir.File("instalacao.json"));
                string id = store.GetOrCreate();
                Guid parsed;
                Assert.True(Guid.TryParse(id, out parsed));
                Assert.NotEqual(Guid.Empty, parsed);
                Assert.True(InstallationIdentityStore.IsValidId(id));
            }
        }

        [Fact]
        public void KeepsTheSameIdAcrossRestarts()
        {
            using (TempDir dir = new TempDir())
            {
                string file = dir.File("data/instalacao.json");
                string first = new InstallationIdentityStore(file).GetOrCreate();
                // "reinício": novas instâncias do armazém lendo o mesmo arquivo
                string second = new InstallationIdentityStore(file).GetOrCreate();
                string third = new InstallationIdentityStore(file).GetOrCreate();
                Assert.Equal(first, second);
                Assert.Equal(first, third);
            }
        }

        [Fact]
        public void DifferentInstallationsGetDifferentIds()
        {
            using (TempDir a = new TempDir())
            using (TempDir b = new TempDir())
            {
                string idA = new InstallationIdentityStore(a.File("i.json")).GetOrCreate();
                string idB = new InstallationIdentityStore(b.File("i.json")).GetOrCreate();
                Assert.NotEqual(idA, idB);
            }
        }

        [Fact]
        public void RecoversFromCorruptMainFileUsingTheBackup()
        {
            using (TempDir dir = new TempDir())
            {
                string file = dir.File("instalacao.json");
                string original = new InstallationIdentityStore(file).GetOrCreate();
                File.WriteAllText(file, "{ isto não é json");

                string recovered = new InstallationIdentityStore(file).GetOrCreate();
                Assert.Equal(original, recovered);

                // o arquivo principal foi reparado
                Assert.Equal(original, new InstallationIdentityStore(file).GetOrCreate());
            }
        }

        [Fact]
        public void CorruptFileWithoutBackupGeneratesNewValidIdAndKeepsEvidence()
        {
            using (TempDir dir = new TempDir())
            {
                string file = dir.File("instalacao.json");
                File.WriteAllText(file, "lixo");
                string id = new InstallationIdentityStore(file).GetOrCreate();
                Assert.True(InstallationIdentityStore.IsValidId(id));
                Assert.Contains(Directory.GetFiles(dir.Path), f => f.Contains(".corrompido-", StringComparison.Ordinal));
                // e agora é estável
                Assert.Equal(id, new InstallationIdentityStore(file).GetOrCreate());
            }
        }

        [Theory]
        [InlineData("abc")]
        [InlineData("")]
        [InlineData("tem espaço no meio do identificador")]
        [InlineData("<script>alert(1)</script>")]
        public void RejectsInvalidIdsInFile(string invalid)
        {
            using (TempDir dir = new TempDir())
            {
                string file = dir.File("instalacao.json");
                File.WriteAllText(file, "{\"identificador_instalacao\":\"" + invalid.Replace("\"", "") + "\"}");
                string id = new InstallationIdentityStore(file).GetOrCreate();
                Assert.NotEqual(invalid, id);
                Assert.True(InstallationIdentityStore.IsValidId(id));
            }
        }
    }

    public class CredentialStoreTests
    {
        [Fact]
        public void SaveAndLoadRoundTrip()
        {
            using (TempDir dir = new TempDir())
            {
                CredentialStore store = new CredentialStore(dir.File("credencial.dpapi"), new FakeSecretProtector());
                AgentToken token = TestTokens.Make(5);
                store.Save(token);

                CredentialLoadResult loaded = store.Load();
                Assert.Equal(CredentialLoadStatus.Ok, loaded.Status);
                Assert.Equal(token.RevealForAuthorization(), loaded.Token!.RevealForAuthorization());
            }
        }

        [Fact]
        public void FileNeverContainsThePlainToken()
        {
            using (TempDir dir = new TempDir())
            {
                string file = dir.File("credencial.dpapi");
                CredentialStore store = new CredentialStore(file, new FakeSecretProtector());
                AgentToken token = TestTokens.Make(5);
                store.Save(token);

                byte[] raw = File.ReadAllBytes(file);
                string asText = Encoding.UTF8.GetString(raw);
                string full = token.RevealForAuthorization();
                string secret = full.Substring(full.IndexOf('.') + 1);
                Assert.DoesNotContain(secret, asText, StringComparison.Ordinal);
                Assert.DoesNotContain("fpa_", asText.Substring(4), StringComparison.Ordinal);
            }
        }

        [Fact]
        public void MissingFileIsReportedAsMissing()
        {
            using (TempDir dir = new TempDir())
            {
                CredentialStore store = new CredentialStore(dir.File("nao-existe.dpapi"), new FakeSecretProtector());
                Assert.Equal(CredentialLoadStatus.Missing, store.Load().Status);
            }
        }

        [Fact]
        public void GarbageAndTamperedFilesAreCorruptAndNotDeleted()
        {
            using (TempDir dir = new TempDir())
            {
                string file = dir.File("credencial.dpapi");
                CredentialStore store = new CredentialStore(file, new FakeSecretProtector());

                File.WriteAllBytes(file, new byte[] { 1, 2, 3 });
                Assert.Equal(CredentialLoadStatus.Corrupt, store.Load().Status);
                Assert.True(File.Exists(file));

                store.Save(TestTokens.Make(5));
                byte[] raw = File.ReadAllBytes(file);
                raw[raw.Length - 2] ^= 0xFF; // adultera o conteúdo protegido
                File.WriteAllBytes(file, raw);
                Assert.Equal(CredentialLoadStatus.Corrupt, store.Load().Status);
                Assert.True(File.Exists(file));
            }
        }

        [Fact]
        public void DeleteRemovesTheFile()
        {
            using (TempDir dir = new TempDir())
            {
                string file = dir.File("credencial.dpapi");
                CredentialStore store = new CredentialStore(file, new FakeSecretProtector());
                store.Save(TestTokens.Make(5));
                store.Delete();
                Assert.False(File.Exists(file));
                store.Delete(); // apagar de novo não falha
            }
        }

        [Fact]
        public void SaveLeavesNoTemporaryFilesBehind()
        {
            using (TempDir dir = new TempDir())
            {
                CredentialStore store = new CredentialStore(dir.File("credencial.dpapi"), new FakeSecretProtector());
                store.Save(TestTokens.Make(5));
                store.Save(TestTokens.Make(5, 2));
                Assert.Empty(Directory.GetFiles(dir.Path, "*.tmp"));
            }
        }
    }

    public class CredentialVaultTests
    {
        private static (CredentialVault vault, ControllableCredentialStore store, FakeClock clock, TempDir dir) Create()
        {
            TempDir dir = new TempDir();
            FakeClock clock = new FakeClock();
            ControllableCredentialStore store = new ControllableCredentialStore(new CredentialStore(dir.File("c.dpapi"), new FakeSecretProtector()));
            CredentialVault vault = new CredentialVault(store, clock);
            return (vault, store, clock, dir);
        }

        [Fact]
        public void RenewedTokenIsPersistedBeforeItReplacesTheActiveOne()
        {
            var ctx = Create();
            using (ctx.dir)
            {
                AgentToken oldToken = TestTokens.Make(1, 1);
                AgentToken newToken = TestTokens.Make(1, 2);
                ctx.vault.SetInitial(oldToken);

                string? activeDuringSave = null;
                ctx.store.BeforeSave = t => { activeDuringSave = ctx.vault.GetActive()!.RevealForAuthorization(); };

                Assert.True(ctx.vault.StageRenewed(newToken));

                // no momento da gravação o token antigo ainda era o ativo; só depois o novo passou a valer
                Assert.Equal(oldToken.RevealForAuthorization(), activeDuringSave);
                Assert.Equal(newToken.RevealForAuthorization(), ctx.vault.GetActive()!.RevealForAuthorization());
                Assert.Equal(newToken.RevealForAuthorization(), ctx.store.Load().Token!.RevealForAuthorization());
            }
        }

        [Fact]
        public void FailedSaveKeepsOldTokenActiveAndKeepsNewOnePending()
        {
            var ctx = Create();
            using (ctx.dir)
            {
                AgentToken oldToken = TestTokens.Make(1, 1);
                AgentToken newToken = TestTokens.Make(1, 2);
                ctx.vault.SetInitial(oldToken);

                ctx.store.FailSaves = true;
                Assert.False(ctx.vault.StageRenewed(newToken));
                Assert.True(ctx.vault.HasPendingPersistence);
                Assert.Equal(oldToken.RevealForAuthorization(), ctx.vault.GetActive()!.RevealForAuthorization());
                // o disco continua com o token antigo (nada foi destruído)
                Assert.Equal(oldToken.RevealForAuthorization(), ctx.store.Load().Token!.RevealForAuthorization());

                // gravação volta a funcionar: o pendente é gravado e passa a valer
                ctx.store.FailSaves = false;
                Assert.True(ctx.vault.TryFlushPending());
                Assert.False(ctx.vault.HasPendingPersistence);
                Assert.Equal(newToken.RevealForAuthorization(), ctx.vault.GetActive()!.RevealForAuthorization());
                Assert.Equal(newToken.RevealForAuthorization(), ctx.store.Load().Token!.RevealForAuthorization());
            }
        }

        [Fact]
        public void PendingTokenIsUsedAfterTheMaximumAgeSoTheLinkIsNeverLost()
        {
            var ctx = Create();
            using (ctx.dir)
            {
                AgentToken oldToken = TestTokens.Make(1, 1);
                AgentToken newToken = TestTokens.Make(1, 2);
                ctx.vault.SetInitial(oldToken);
                ctx.store.FailSaves = true;
                ctx.vault.StageRenewed(newToken);

                ctx.clock.Advance(AgentConstants.PendingCredentialMaxAge - TimeSpan.FromSeconds(1));
                Assert.Equal(oldToken.RevealForAuthorization(), ctx.vault.GetActive()!.RevealForAuthorization());

                ctx.clock.Advance(TimeSpan.FromSeconds(2));
                Assert.Equal(newToken.RevealForAuthorization(), ctx.vault.GetActive()!.RevealForAuthorization());
            }
        }

        [Fact]
        public void SetInitialThrowsAndDoesNotActivateWhenSaveFails()
        {
            var ctx = Create();
            using (ctx.dir)
            {
                ctx.store.FailSaves = true;
                Assert.Throws<IOException>(() => ctx.vault.SetInitial(TestTokens.Make(1)));
                Assert.False(ctx.vault.HasCredential);
            }
        }

        [Fact]
        public void ClearRemovesCredentialFromMemoryAndDisk()
        {
            var ctx = Create();
            using (ctx.dir)
            {
                ctx.vault.SetInitial(TestTokens.Make(1));
                Assert.True(ctx.vault.HasCredential);
                ctx.vault.Clear();
                Assert.False(ctx.vault.HasCredential);
                Assert.Null(ctx.vault.GetActive());
                Assert.Equal(CredentialLoadStatus.Missing, ctx.store.Load().Status);
            }
        }

        [Fact]
        public void LoadReadsWhatWasSavedByAnotherInstance()
        {
            var ctx = Create();
            using (ctx.dir)
            {
                AgentToken token = TestTokens.Make(9);
                ctx.vault.SetInitial(token);

                CredentialVault restarted = new CredentialVault(ctx.store, ctx.clock);
                Assert.Equal(CredentialLoadStatus.Ok, restarted.Load());
                Assert.True(restarted.HasCredential);
                Assert.Equal(token.RevealForAuthorization(), restarted.GetActive()!.RevealForAuthorization());
            }
        }
    }

    public class AgentStateStoreTests
    {
        [Fact]
        public void RoundTripKeepsPersistentFieldsAndDropsTransientOnes()
        {
            using (TempDir dir = new TempDir())
            {
                string file = dir.File("estado.json");
                AgentStateStore store = new AgentStateStore(file);

                AgentState state = new AgentState();
                state.CompanyName = "Distribuidora Florest";
                state.StationName = "Caixa 1";
                state.HeartbeatSeconds = 90;
                state.LastError = "ERRO-TRANSITORIO-NAO-PERSISTE";
                state.CredentialRejected = true;
                state.LastContactFailed = true;
                store.Save(state);

                string json = File.ReadAllText(file);
                Assert.DoesNotContain("ERRO-TRANSITORIO-NAO-PERSISTE", json, StringComparison.Ordinal);

                AgentState loaded = store.Load();
                Assert.Equal("Distribuidora Florest", loaded.CompanyName);
                Assert.Equal("Caixa 1", loaded.StationName);
                Assert.Equal(90, loaded.HeartbeatSeconds);
                Assert.Null(loaded.LastError);
                Assert.False(loaded.CredentialRejected);
                Assert.False(loaded.LastContactFailed);
            }
        }

        [Fact]
        public void CorruptFileGivesCleanState()
        {
            using (TempDir dir = new TempDir())
            {
                string file = dir.File("estado.json");
                File.WriteAllText(file, "{{{{ não é json");
                AgentState loaded = new AgentStateStore(file).Load();
                Assert.Null(loaded.CompanyName);
                Assert.Equal(AgentConstants.DefaultHeartbeatSeconds, loaded.HeartbeatSeconds);
            }
        }

        [Fact]
        public void OutOfRangeValuesAreNormalized()
        {
            using (TempDir dir = new TempDir())
            {
                string file = dir.File("estado.json");
                File.WriteAllText(file, "{\"heartbeat_segundos\":1,\"limite_impressoras\":100000}");
                AgentState loaded = new AgentStateStore(file).Load();
                Assert.Equal(AgentConstants.DefaultHeartbeatSeconds, loaded.HeartbeatSeconds);
                Assert.Equal(AgentConstants.MaxPrintersPerSync, loaded.PrinterLimit);
            }
        }

        [Fact]
        public void UserPrinterListsSurviveARestart()
        {
            using (TempDir dir = new TempDir())
            {
                string file = dir.File("estado.json");
                AgentStateStore store = new AgentStateStore(file);
                AgentState state = new AgentState();
                UserPrinterList list = new UserPrinterList();
                list.Session = "PC\\maria";
                list.UpdatedUtc = new DateTime(2026, 10, 5, 12, 0, 0, DateTimeKind.Utc);
                list.Printers.Add(Samples.Usb("Balcao"));
                state.UserPrinters.Add(list);
                store.Save(state);

                AgentState loaded = store.Load();
                Assert.Single(loaded.UserPrinters);
                Assert.Equal("PC\\maria", loaded.UserPrinters[0].Session);
                Assert.Equal("Balcao", loaded.UserPrinters[0].Printers.Single().Nome);
            }
        }
    }

    public class AtomicFileTests
    {
        [Fact]
        public void ReplacesExistingFileCompletely()
        {
            using (TempDir dir = new TempDir())
            {
                string file = dir.File("a.txt");
                AtomicFile.WriteAllText(file, "primeiro conteúdo bem comprido");
                AtomicFile.WriteAllText(file, "curto");
                Assert.Equal("curto", File.ReadAllText(file));
                Assert.Empty(Directory.GetFiles(dir.Path, "*.tmp"));
            }
        }

        [Fact]
        public void CreatesMissingDirectories()
        {
            using (TempDir dir = new TempDir())
            {
                string file = Path.Combine(dir.Path, "x", "y", "a.txt");
                AtomicFile.WriteAllText(file, "ok");
                Assert.Equal("ok", File.ReadAllText(file));
            }
        }

        [Fact]
        public void CleanupRemovesOrphanTemporaries()
        {
            using (TempDir dir = new TempDir())
            {
                File.WriteAllText(dir.File("lixo.tmp"), "x");
                File.WriteAllText(dir.File("fica.json"), "x");
                AtomicFile.CleanupTemporaries(dir.Path);
                Assert.False(File.Exists(dir.File("lixo.tmp")));
                Assert.True(File.Exists(dir.File("fica.json")));
            }
        }
    }
}
