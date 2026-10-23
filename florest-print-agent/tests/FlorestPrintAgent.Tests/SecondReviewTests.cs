using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using FlorestPrintAgent.Core;
using FlorestPrintAgent.Core.Agent;
using FlorestPrintAgent.Core.Api;
using FlorestPrintAgent.Core.Jobs;
using FlorestPrintAgent.Core.Printers;
using FlorestPrintAgent.Tests.TestSupport;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace FlorestPrintAgent.Tests
{
    /// <summary>
    /// Segunda revisão (1.1.0): o diário local é gravado no instante em que o spooler ACEITA o documento (antes da espera do papel),
    /// resolução determinística da impressora, Service que sobrevive offline, independência do Tray e atualização sem novo pareamento.
    /// </summary>
    public class SpoolTimeJournalTests
    {
        private const string J1 = "bbbbbbbb-0000-0000-0000-000000000001";

        [Fact]
        public async Task TheJournalIsWrittenWhenTheSpoolerAcceptsTheDocumentBeforeTheWaitForPaper()
        {
            WorkerFixture f = new WorkerFixture();
            bool journaledAtSpoolTime = false;
            f.Writer.AfterSpooled = () => journaledAtSpoolTime = f.Journal.Contains(J1);
            f.QueueJobs(WorkerFixture.MakeJob(J1));

            await f.Worker.RunOnceAsync(CancellationToken.None);

            Assert.True(journaledAtSpoolTime);
            Assert.Equal(1, f.Writer.Spooled);
            Assert.Equal(new[] { J1 }, f.Api.CompletedJobs.ToArray());
            Assert.Empty(f.Journal.Pending());
        }

        [Fact]
        public async Task ServiceKilledWhileWaitingForPaperNeverReprintsAfterTheRestart()
        {
            using (TempDir dir = new TempDir())
            {
                string journal = dir.File("data/impressoes-pendentes.json");

                // 1) o spooler aceitou, o papel está saindo... e o serviço é encerrado / o computador cai
                WorkerFixture before = new WorkerFixture(journal);
                before.Writer.AfterSpooled = () => throw new OperationCanceledException();
                before.QueueJobs(WorkerFixture.MakeJob(J1));
                await Assert.ThrowsAnyAsync<OperationCanceledException>(() => before.Worker.RunOnceAsync(CancellationToken.None));
                Assert.Single(before.Writer.Printers);
                Assert.Equal(0, before.Api.CompleteCalls);
                Assert.True(File.Exists(journal));

                // 2) o Windows liga de novo; o servidor devolve o job (a reserva venceu); mesmo arquivo de diário em ProgramData.
                //    A internet ainda não voltou na primeira confirmação (a do diário, antes da consulta): o job continua no diário
                //    e, quando o servidor o devolve pela fila, o agente SÓ confirma.
                WorkerFixture after = new WorkerFixture(journal);
                int completes = 0;
                after.Api.OnComplete = (id, ct) => Task.FromResult(completes++ == 0 ? WorkerFixture.AckFail(ApiOutcome.NetworkError, 0, null) : WorkerFixture.Ack());
                after.QueueJobs(WorkerFixture.MakeJob(J1));
                await after.Worker.RunOnceAsync(CancellationToken.None);

                Assert.Empty(after.Writer.Printers);                       // NENHUMA segunda cópia
                Assert.Equal(2, after.Api.CompleteCalls);                   // 1ª (diário) falhou na rede; 2ª (job devolvido) confirmou
                Assert.All(after.Api.CompletedJobs, id => Assert.Equal(J1, id));
                Assert.Empty(after.Journal.Pending());
            }
        }

        [Fact]
        public async Task PrinterFailureAfterTheSpoolerAcceptedRemovesTheJournalSoTheRetryCanPrint()
        {
            WorkerFixture f = new WorkerFixture();
            f.Writer.SpoolEvenOnFailure = true;
            f.Writer.Result = () => RawPrintResult.Fail("impressora_offline", "A impressora está offline.");
            f.QueueJobs(WorkerFixture.MakeJob(J1));

            await f.Worker.RunOnceAsync(CancellationToken.None);

            Assert.Equal(1, f.Writer.Spooled);
            Assert.Equal(0, f.Api.CompleteCalls);
            Assert.Equal("impressora_offline", f.Api.FailedJobs.Single().Code);
            Assert.Empty(f.Journal.Pending());      // o papel NÃO saiu: precisa poder imprimir na próxima tentativa
        }

        [Fact]
        public async Task UnexpectedErrorAfterTheSpoolerAcceptedIsTreatedAsPrintedNeverAsFailure()
        {
            WorkerFixture f = new WorkerFixture();
            f.Writer.AfterSpooled = () => throw new InvalidOperationException("boom");
            f.QueueJobs(WorkerFixture.MakeJob(J1));

            await f.Worker.RunOnceAsync(CancellationToken.None);

            Assert.Equal(0, f.Api.FailCalls);                       // falhar faria o servidor reenviar e o papel sairia em dobro
            Assert.Equal(new[] { J1 }, f.Api.CompletedJobs.ToArray());
            Assert.NotNull(f.Activity.Snapshot().LastSuccess);
        }

        [Fact]
        public async Task NotAcceptedBySpoolerNeverTouchesTheJournal()
        {
            WorkerFixture f = new WorkerFixture();
            f.Resolver.Handler = p => PrinterResolution.NotFound(p.Nome);
            f.QueueJobs(WorkerFixture.MakeJob(J1));
            await f.Worker.RunOnceAsync(CancellationToken.None);
            Assert.Equal(0, f.Writer.Spooled);
            Assert.Empty(f.Journal.Pending());
        }

        [Fact]
        public void CorruptJournalIsKeptAsACopyForAnalysis()
        {
            using (TempDir dir = new TempDir())
            {
                string file = dir.File("j.json");
                File.WriteAllText(file, "{{{ lixo");
                PrintedJournal j = new PrintedJournal(file, new FakeClock(), NullLogger.Instance);
                Assert.Empty(j.Pending());
                Assert.True(File.Exists(file + ".corrompido"));
                Assert.Equal("{{{ lixo", File.ReadAllText(file + ".corrompido"));
            }
        }
    }

    public class DeterministicPrinterResolutionTests
    {
        private static DiscoveryPrinterResolver Resolver(params PrinterInfo[] printers)
        {
            FakeDiscovery d = new FakeDiscovery();
            d.Result = DiscoveryResult.Ok(printers.ToList());
            return new DiscoveryPrinterResolver(d);
        }

        [Fact]
        public void NameComparisonIgnoresCaseSurroundingAndRepeatedSpaces()
        {
            PrinterInfo p = Samples.Usb("Bematech MP-4200 HS");
            PrinterResolution r = Resolver(p).Resolve(new JobPrinter { Nome = "  bematech   mp-4200 hs ", Identificador = "nao-bate" });
            Assert.True(r.Found);
            Assert.Equal("Bematech MP-4200 HS", r.Name);          // sempre o nome REAL da fila no Windows
        }

        [Fact]
        public void ASimilarNameIsNeverAMatch()
        {
            PrinterResolution r = Resolver(Samples.Usb("COZINHA"), Samples.Usb("COZINHA 2"), Samples.Usb("Print iD"))
                .Resolve(new JobPrinter { Nome = "COZINHA 3", Identificador = "x" });
            Assert.False(r.Found);
            Assert.Equal(PrintErrorCodes.PrinterNotFound, r.ErrorCode);
        }

        [Fact]
        public void IdentifierMatchWinsOverANameThatBelongsToAnotherQueue()
        {
            PrinterInfo cozinha = Samples.Usb("COZINHA");
            PrinterInfo bar = Samples.Usb("Bematech MP-4200 HS");
            PrinterResolution r = Resolver(cozinha, bar).Resolve(new JobPrinter { Nome = "COZINHA", Identificador = bar.Identificador });
            Assert.True(r.Found);
            Assert.Equal("Bematech MP-4200 HS", r.Name);
            Assert.Null(r.Note);
        }

        [Fact]
        public void ChangedPortKeepsTheSameQueueByNameAndIsReported()
        {
            PrinterInfo moved = Samples.Printer("COZINHA", PrinterConnection.Rede, PrinterStatus.Disponivel, "192.168.0.50", 9100, "IP_192.168.0.50");
            JobPrinter wanted = new JobPrinter { Nome = "COZINHA", Identificador = "identificador-antigo", PortaWindows = "USB001" };
            PrinterResolution r = Resolver(moved).Resolve(wanted);
            Assert.True(r.Found);
            Assert.Equal("COZINHA", r.Name);
            Assert.NotNull(r.Note);
            Assert.Contains("IP_192.168.0.50", r.Note!, StringComparison.Ordinal);
        }

        [Fact]
        public void UsbPortNumberChangeIsNotReportedBecauseUsbPortsAreEquivalent()
        {
            PrinterInfo p = Samples.Printer("COZINHA", PrinterConnection.Usb, PrinterStatus.Disponivel, null, null, "USB003");
            PrinterResolution r = Resolver(p).Resolve(new JobPrinter { Nome = "COZINHA", Identificador = "x", PortaWindows = "USB001" });
            Assert.True(r.Found);
            Assert.Null(r.Note);
        }

        [Fact]
        public void NoPrinterAtAllMeansControlledFailureNeverTheDefaultPrinter()
        {
            PrinterResolution r = Resolver().Resolve(new JobPrinter { Nome = "COZINHA", Identificador = "x" });
            Assert.False(r.Found);
            Assert.Equal("impressora_nao_encontrada", r.ErrorCode);
            Assert.Equal(string.Empty, r.Name);
        }

        [Fact]
        public void MissingPrinterFailsTheJobWithTheDocumentedCodeAndTheWriterIsNeverCalled()
        {
            // resolvedor REAL (não o falso): a fila do servidor não existe neste computador
            FakeDiscovery d = new FakeDiscovery();
            d.Result = DiscoveryResult.Ok(new List<PrinterInfo> { Samples.Usb("Print iD") });
            WorkerFixture f = new WorkerFixture();
            PrintJobProcessor processor = new PrintJobProcessor(new DiscoveryPrinterResolver(d), f.Writer, name => TicketLayout.Default(), f.Log);
            PrintJob job = WorkerFixture.MakeJob("bbbbbbbb-0000-0000-0000-000000000009", "cozinha", "COZINHA");

            PrintOutcome outcome = processor.Process(job, CancellationToken.None);

            Assert.False(outcome.Success);
            Assert.Equal("impressora_nao_encontrada", outcome.ErrorCode);
            Assert.Empty(f.Writer.Printers);
        }
    }

    public class OfflineAndIndependenceTests
    {
        private const string J1 = "cccccccc-0000-0000-0000-000000000001";

        [Fact]
        public async Task OfflineKeepsTheWorkerAliveAndPrintingResumesByItselfWhenTheInternetReturns()
        {
            WorkerFixture f = new WorkerFixture();
            bool online = false;
            bool delivered = false;
            PrintJob job = WorkerFixture.MakeJob(J1);
            f.Api.OnClaim = ct =>
            {
                if (!online) return Task.FromResult(ApiResult<ClaimJobsResponse>.Failure(ApiOutcome.NetworkError, 0, null, null));
                ClaimJobsResponse r = new ClaimJobsResponse();
                if (!delivered)
                {
                    delivered = true;
                    r.Jobs.Add(job);
                }
                return Task.FromResult(ApiResult<ClaimJobsResponse>.Success(r, 200));
            };

            // o Windows acabou de ligar e o roteador ainda não respondeu: nada lança exceção, o laço só espera e tenta de novo
            for (int i = 0; i < 6; i++)
            {
                TimeSpan wait = await f.Worker.RunOnceAsync(CancellationToken.None);
                Assert.True(wait > TimeSpan.Zero);
            }
            Assert.Empty(f.Writer.Printers);
            Assert.Contains("Sem acesso à fila de impressão", f.Log.All(), StringComparison.Ordinal);   // fica registrado em log

            // a internet volta: o próprio laço retoma e imprime
            online = true;
            await f.Worker.RunOnceAsync(CancellationToken.None);
            Assert.Equal(new[] { "COZINHA" }, f.Writer.Printers.ToArray());
            Assert.Equal(new[] { J1 }, f.Api.CompletedJobs.ToArray());
        }

        [Fact]
        public async Task RunLoopSurvivesAnUnexpectedExceptionFromTheServerLayer()
        {
            WorkerFixture f = new WorkerFixture();
            f.Api.OnClaim = ct => throw new InvalidOperationException("falha simulada");
            using (CancellationTokenSource cts = new CancellationTokenSource())
            {
                Task run = f.Worker.RunAsync(cts.Token);
                await Task.Delay(300);
                Assert.False(run.IsCompleted);                 // continua vivo depois do erro
                Assert.True(f.Api.ClaimCalls >= 1);
                cts.Cancel();
                Task finished = await Task.WhenAny(run, Task.Delay(TimeSpan.FromSeconds(10)));
                Assert.Same(run, finished);
            }
        }

        [Fact]
        public void TheWorkerDependsOnlyOnCoreServicesNeverOnTheTrayOrTheIpcPipe()
        {
            ConstructorInfo ctor = typeof(PrintJobWorker).GetConstructors().Single();
            ParameterInfo[] ps = ctor.GetParameters();
            foreach (ParameterInfo p in ps)
            {
                string ns = p.ParameterType.Namespace ?? string.Empty;
                Assert.DoesNotContain("Ipc", ns, StringComparison.Ordinal);
                Assert.DoesNotContain("Tray", p.ParameterType.Name, StringComparison.Ordinal);
                Assert.DoesNotContain("Controller", p.ParameterType.Name, StringComparison.Ordinal);
            }
            Assert.Contains(ps, p => p.ParameterType == typeof(IJobAccessProvider));
        }

        [Fact]
        public void TheCoordinatorHandsOutTheJobCredentialWithoutAnyTrayInteraction()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                // nenhum PairAsync, nenhum chamador IPC: só o arquivo de credencial em disco (como depois de ligar o computador)
                JobAccess? access = f.Coordinator.GetJobAccess();
                Assert.NotNull(access);
                Assert.Equal(CoordinatorFixture.InstallationId, access!.InstallationId);
                Assert.Equal(TestTokens.Make(1).RevealForAuthorization(), access.Token.RevealForAuthorization());
            }
        }

        [Fact]
        public async Task UpgradeFrom100KeepsTheLinkTheStationAndTheCredentialWithoutANewPairing()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1), false))
            {
                // arquivo de estado EXATAMENTE como a 1.0.0 gravava (nenhum campo da 1.1.0)
                File.WriteAllText(f.Paths.StateFile,
                    "{\n  \"empresa_nome\": \"RESTAURANTE NOVA PONTE\",\n  \"estacao_nome\": \"LANCHONETE\",\n" +
                    "  \"pareado_em_utc\": \"2026-09-30T12:00:00Z\",\n  \"pareado_por_sid\": \"S-1-5-21-1111111111-2222222222-3333333333-1001\",\n" +
                    "  \"heartbeat_segundos\": 120,\n  \"limite_impressoras\": 100,\n  \"ultimo_heartbeat_ok_utc\": \"2026-10-05T11:59:00Z\"\n}");
                f.Start();

                AgentStatusDto s = f.Coordinator.GetStatus();
                Assert.True(s.Vinculado);
                Assert.Equal("RESTAURANTE NOVA PONTE", s.Empresa);
                Assert.Equal("LANCHONETE", s.Estacao);
                Assert.NotNull(f.Coordinator.GetJobAccess());

                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                Assert.Equal(TestTokens.Make(1).RevealForAuthorization(), f.Api.HeartbeatTokens.Single());
                Assert.Equal(0, f.Api.ConfirmCalls);          // nenhum pareamento novo
                Assert.Equal(0, f.Api.VerifyCalls);
            }
        }

        [Fact]
        public async Task RestartAfterAPrintedJobKeepsLinkAndCredentialAndTheDiaryTogether()
        {
            // reinício do Windows = novos objetos lendo os mesmos arquivos de ProgramData (credencial, estado, identidade, diário)
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                await f.PairAsync("ABCD-2345");
                PrintedJournal diary = new PrintedJournal(f.Paths.PrintedJournalFile, f.Clock, NullLogger.Instance);
                diary.Add("dddddddd-0000-0000-0000-000000000001");

                f.Restart();

                Assert.True(f.Coordinator.GetStatus().Vinculado);
                Assert.NotNull(f.Coordinator.GetJobAccess());
                PrintedJournal reloaded = new PrintedJournal(f.Paths.PrintedJournalFile, f.Clock, NullLogger.Instance);
                Assert.True(reloaded.Contains("dddddddd-0000-0000-0000-000000000001"));
            }
        }
    }

    /// <summary>
    /// Verificações estáticas dos arquivos de instalação (o instalador e os scripts não rodam em teste de unidade, mas os defeitos
    /// que já aconteceram — caminho vazio, BOM, tipo de início, DPAPI de usuário, apagar dados em atualização — são vigiados aqui).
    /// </summary>
    public class InstallationContractTests
    {
        private static string? Root()
        {
            string? d = AppContext.BaseDirectory;
            while (d != null && !File.Exists(Path.Combine(d, "FlorestPrintAgent.sln"))) d = Path.GetDirectoryName(d);
            return d;
        }

        private static string? ReadText(string relative)
        {
            string? root = Root();
            if (root == null) return null;   // binários copiados para fora do repositório: nada a conferir
            return File.ReadAllText(Path.Combine(root, relative), Encoding.UTF8);
        }

        [Fact]
        public void CredentialProtectionUsesTheMachineScopeSoTheServiceCanReadItAfterAReboot()
        {
            string? src = ReadText(Path.Combine("src", "FlorestPrintAgent.Core", "Security", "ISecretProtector.cs"));
            if (src == null) return;
            Assert.Contains("DataProtectionScope.LocalMachine", src, StringComparison.Ordinal);
            Assert.DoesNotContain("DataProtectionScope.CurrentUser", src, StringComparison.Ordinal);
        }

        [Fact]
        public void OnlyTheServiceTouchesTheCredentialFile()
        {
            string? root = Root();
            if (root == null) return;
            foreach (string file in Directory.GetFiles(Path.Combine(root, "src", "FlorestPrintAgent.Tray"), "*.cs", SearchOption.AllDirectories))
            {
                string text = File.ReadAllText(file, Encoding.UTF8);
                Assert.DoesNotContain("CredentialStore", text, StringComparison.Ordinal);
                Assert.DoesNotContain("DpapiSecretProtector", text, StringComparison.Ordinal);
                Assert.DoesNotContain("ProtectedData", text, StringComparison.Ordinal);
            }
        }

        [Fact]
        public void EveryPowerShellScriptHasABomAndNoScriptRootInParameterDefaults()
        {
            string? root = Root();
            if (root == null) return;
            string[] scripts = Directory.GetFiles(Path.Combine(root, "scripts"), "*.ps1");
            Assert.NotEmpty(scripts);
            foreach (string script in scripts)
            {
                byte[] raw = File.ReadAllBytes(script);
                Assert.True(raw.Length > 3 && raw[0] == 0xEF && raw[1] == 0xBB && raw[2] == 0xBF, Path.GetFileName(script) + " precisa de UTF-8 com BOM (Windows PowerShell 5.1).");

                string text = Encoding.UTF8.GetString(raw);
                int p = text.IndexOf("param(", StringComparison.OrdinalIgnoreCase);
                if (p < 0) continue;
                int end = text.IndexOf("\n)", p, StringComparison.Ordinal);
                if (end < 0) end = text.Length;
                string block = text.Substring(p, end - p);
                Assert.DoesNotContain("$PSScriptRoot", block, StringComparison.Ordinal);       // chega vazio no PS 5.1 com -File: causa do erro do Split-Path
                Assert.DoesNotContain("$MyInvocation", block, StringComparison.Ordinal);
            }
        }

        [Fact]
        public void InstallServiceScriptComputesItsOwnPathsInsideTheBodyAndConfiguresAutomaticStartAndRecovery()
        {
            string? text = ReadText(Path.Combine("scripts", "install-service.ps1"));
            if (text == null) return;
            Assert.Contains("$scriptDir", text, StringComparison.Ordinal);
            Assert.Contains("$projectRoot", text, StringComparison.Ordinal);
            Assert.Contains("-StartupType Automatic", text, StringComparison.Ordinal);
            Assert.Contains("start= auto", text, StringComparison.Ordinal);
            Assert.Contains("failure", text, StringComparison.Ordinal);
            Assert.Contains("restart/5000/restart/5000/restart/", text, StringComparison.Ordinal);
            Assert.DoesNotContain("delayed-auto", text, StringComparison.Ordinal);
        }

        [Fact]
        public void InstallerIsAnUpgradeableAutomaticServiceWithRecoveryAndNeverDeletesDataSilently()
        {
            string? iss = ReadText(Path.Combine("installer", "FlorestPrintAgent.iss"));
            if (iss == null) return;
            Assert.Contains("#define AppVersion \"" + AgentConstants.AgentVersion + "\"", iss, StringComparison.Ordinal);
            Assert.Contains("PrivilegesRequired=admin", iss, StringComparison.Ordinal);
            Assert.Contains("OutputBaseFilename=FlorestPrintAgent-Setup-{#AppVersion}", iss, StringComparison.Ordinal);
            Assert.Contains("AppId={{", iss, StringComparison.Ordinal);                    // mesmo AppId em toda versão = atualização no lugar
            Assert.Contains("start= auto", iss, StringComparison.Ordinal);
            Assert.Contains("failure ", iss, StringComparison.Ordinal);
            Assert.Contains("restart/5000/restart/5000/restart/", iss, StringComparison.Ordinal);
            Assert.Contains("failureflag", iss, StringComparison.Ordinal);
            Assert.Contains("FlorestPrintAgentTray", iss, StringComparison.Ordinal);       // Tray no login
            Assert.Contains("uninsneveruninstall", iss, StringComparison.Ordinal);         // pasta de dados nunca removida pelo desinstalador
            Assert.Contains("/PURGEDATA", iss, StringComparison.Ordinal);                   // remoção total só explícita
            Assert.Contains("{commonappdata}\\Florest Sistemas\\Print Agent", iss, StringComparison.Ordinal);
            Assert.DoesNotContain("delayed-auto", iss, StringComparison.Ordinal);

            // a pasta de dados do instalador é a mesma que o agente usa
            string? paths = ReadText(Path.Combine("src", "FlorestPrintAgent.Core", "AgentPaths.cs"));
            Assert.NotNull(paths);
            Assert.Contains("\"Florest Sistemas\", \"Print Agent\"", paths!, StringComparison.Ordinal);
        }

        [Fact]
        public void VersionIsTheSameInTheProjectTheConstantsAndTheInstaller()
        {
            string? props = ReadText("Directory.Build.props");
            if (props == null) return;
            Assert.Contains("<Version>" + AgentConstants.AgentVersion + "</Version>", props, StringComparison.Ordinal);
            Assert.Contains("<AssemblyVersion>" + AgentConstants.AgentVersion + ".0</AssemblyVersion>", props, StringComparison.Ordinal);
        }
    }
}
