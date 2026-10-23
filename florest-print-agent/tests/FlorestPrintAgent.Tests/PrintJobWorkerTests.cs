using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using FlorestPrintAgent.Core;
using FlorestPrintAgent.Core.Agent;
using FlorestPrintAgent.Core.Api;
using FlorestPrintAgent.Core.Jobs;
using FlorestPrintAgent.Core.Printers;
using FlorestPrintAgent.Core.Security;
using FlorestPrintAgent.Tests.TestSupport;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace FlorestPrintAgent.Tests
{
    internal sealed class FakeAccess : IJobAccessProvider
    {
        public JobAccess? Access { get; set; } = new JobAccess(TestTokens.Make(1), "11111111-2222-3333-4444-555555555555");

        public JobAccess? GetJobAccess()
        {
            return Access;
        }
    }

    internal sealed class FakeWriter : IRawPrinterWriter
    {
        public List<string> Printers { get; } = new List<string>();
        public List<string> Documents { get; } = new List<string>();
        public List<byte[]> Data { get; } = new List<byte[]>();
        public Func<RawPrintResult> Result { get; set; } = () => RawPrintResult.Ok();
        public Action? OnWrite { get; set; }
        /// <summary>Quantas vezes o escritor avisou "o spooler aceitou o documento" (callback onSpooled).</summary>
        public int Spooled { get; private set; }
        /// <summary>Avisa o spooler mesmo quando o resultado final é falha (simula: o Windows aceitou, depois a impressora acusou erro).</summary>
        public bool SpoolEvenOnFailure { get; set; }
        /// <summary>Roda depois do aviso do spooler e antes de devolver o resultado (simula a espera do papel; pode lançar para simular queda).</summary>
        public Action? AfterSpooled { get; set; }

        public RawPrintResult Write(string printerName, string documentName, byte[] data, CancellationToken ct, Action? onSpooled = null)
        {
            Printers.Add(printerName);
            Documents.Add(documentName);
            Data.Add(data);
            if (OnWrite != null) OnWrite();
            RawPrintResult result = Result();
            if (onSpooled != null && (result.Success || SpoolEvenOnFailure))
            {
                Spooled++;
                onSpooled();
                if (AfterSpooled != null) AfterSpooled();
            }
            return result;
        }
    }

    internal sealed class FakeResolver : IPrinterResolver
    {
        public Func<JobPrinter, PrinterResolution> Handler { get; set; } = p => PrinterResolution.Ok(p.Nome, PrinterStatus.Disponivel);

        public PrinterResolution Resolve(JobPrinter wanted)
        {
            return Handler(wanted);
        }
    }

    internal sealed class WorkerFixture
    {
        public FakeEdgeApi Api { get; } = new FakeEdgeApi();
        public FakeAccess Access { get; } = new FakeAccess();
        public FakeWriter Writer { get; } = new FakeWriter();
        public FakeResolver Resolver { get; } = new FakeResolver();
        public FakeClock Clock { get; } = new FakeClock();
        public PrintActivity Activity { get; }
        public PrintedJournal Journal { get; }
        public CapturingLogger Log { get; } = new CapturingLogger();
        public PrintJobWorker Worker { get; }

        public WorkerFixture(string? journalPath = null)
        {
            Activity = new PrintActivity(Clock);
            Journal = new PrintedJournal(journalPath, Clock, NullLogger.Instance);
            PrintJobProcessor processor = new PrintJobProcessor(Resolver, Writer, name => TicketLayout.Default(), Log);
            Worker = new PrintJobWorker(Api, Access, processor, Journal, Activity, Clock, Log);
            Worker.RandomSource = () => 0.5; // jitter zero
            Worker.Delay = (t, ct) => Task.CompletedTask;
        }

        public static PrintJob MakeJob(string id, string destino = "cozinha", string printer = "COZINHA", int reserva = 120, string? payload = null)
        {
            PrintJob job = new PrintJob();
            job.Id = id;
            job.Destino = destino;
            job.Tipo = "pedido_bar";
            job.Titulo = "Pedido 12 - " + destino.ToUpperInvariant();
            job.Tentativa = 1;
            job.MaxTentativas = 5;
            job.ReservaSegundos = reserva;
            job.Payload = TicketTests.Json(payload ?? TicketTests.KitchenOrder);
            job.Impressora = new JobPrinter { Nome = printer, Identificador = "ident-" + printer };
            return job;
        }

        public void QueueJobs(params PrintJob[] jobs)
        {
            bool delivered = false;
            Api.OnClaim = ct =>
            {
                ClaimJobsResponse r = new ClaimJobsResponse();
                if (!delivered)
                {
                    delivered = true;
                    r.Jobs.AddRange(jobs);
                }
                return Task.FromResult(ApiResult<ClaimJobsResponse>.Success(r, 200));
            };
        }

        public static ApiResult<JobAckResponse> Ack()
        {
            return ApiResult<JobAckResponse>.Success(new JobAckResponse(), 200);
        }

        public static ApiResult<JobAckResponse> AckFail(ApiOutcome outcome, int http, string? code)
        {
            return ApiResult<JobAckResponse>.Failure(outcome, http, code, null);
        }
    }

    public class PrintJobWorkerTests
    {
        private const string J1 = "aaaaaaaa-0000-0000-0000-000000000001";
        private const string J2 = "aaaaaaaa-0000-0000-0000-000000000002";

        // ------------------------------------------------------------------ fluxo feliz

        [Fact]
        public async Task PrintsOnTheResolvedPrinterAndConfirmsOnlyAfterTheWriteSucceeded()
        {
            WorkerFixture f = new WorkerFixture();
            f.QueueJobs(WorkerFixture.MakeJob(J1, "cozinha", "COZINHA"));
            List<string> order = new List<string>();
            f.Writer.OnWrite = () => order.Add("write");
            f.Api.OnComplete = (id, ct) => { order.Add("complete"); return Task.FromResult(WorkerFixture.Ack()); };

            TimeSpan wait = await f.Worker.RunOnceAsync(CancellationToken.None);

            Assert.Equal(TimeSpan.Zero, wait);
            Assert.Equal(new[] { "COZINHA" }, f.Writer.Printers.ToArray());
            Assert.NotEmpty(f.Writer.Data.Single());
            Assert.Equal(new[] { "write", "complete" }, order.ToArray());
            Assert.Equal(new[] { J1 }, f.Api.CompletedJobs.ToArray());
            Assert.Equal(0, f.Api.FailCalls);
            Assert.Empty(f.Journal.Pending());
            Assert.NotNull(f.Activity.Snapshot().LastSuccess);
            Assert.Null(f.Activity.Snapshot().LastFailure);
            Assert.Equal("Pedido 12 - COZINHA", f.Activity.Snapshot().LastSuccess!.Titulo);
        }

        [Fact]
        public async Task EachJobGoesToItsOwnPrinter()
        {
            WorkerFixture f = new WorkerFixture();
            f.QueueJobs(WorkerFixture.MakeJob(J1, "cozinha", "COZINHA"), WorkerFixture.MakeJob(J2, "bar", "Bematech MP-4200 HS"));
            await f.Worker.RunOnceAsync(CancellationToken.None);
            Assert.Equal(new[] { "COZINHA", "Bematech MP-4200 HS" }, f.Writer.Printers.ToArray());
            Assert.Equal(new[] { J1, J2 }, f.Api.CompletedJobs.ToArray());
        }

        [Fact]
        public async Task ClaimSendsOnlyInstallationLimitAndWait()
        {
            WorkerFixture f = new WorkerFixture();
            await f.Worker.RunOnceAsync(CancellationToken.None);
            Assert.Equal(1, f.Api.ClaimCalls);
            Assert.Equal(AgentConstants.JobClaimLimit, f.Api.ClaimLimits.Single());
            Assert.Equal(AgentConstants.JobLongPollSeconds, f.Api.ClaimWaits.Single());
        }

        [Fact]
        public async Task EmptyClaimWaitsTheMinimumSpacing()
        {
            WorkerFixture f = new WorkerFixture();
            Assert.Equal(AgentConstants.JobMinPollSpacing, await f.Worker.RunOnceAsync(CancellationToken.None));
        }

        // ------------------------------------------------------------------ falhas de impressão

        [Fact]
        public async Task MissingPrinterReportsFailureAndNeverConfirms()
        {
            WorkerFixture f = new WorkerFixture();
            f.Resolver.Handler = p => PrinterResolution.NotFound(p.Nome);
            f.QueueJobs(WorkerFixture.MakeJob(J1, "cozinha", "COZINHA"));

            await f.Worker.RunOnceAsync(CancellationToken.None);

            Assert.Empty(f.Writer.Printers);
            Assert.Equal(0, f.Api.CompleteCalls);
            FakeEdgeApi.FailedJob fail = f.Api.FailedJobs.Single();
            Assert.Equal(J1, fail.JobId);
            Assert.Equal("impressora_nao_encontrada", fail.Code);
            Assert.False(fail.Definitive);
            Assert.Contains("COZINHA", fail.Message, StringComparison.Ordinal);
            Assert.Contains("não encontrada", f.Activity.Snapshot().LastFailure!.Mensagem, StringComparison.Ordinal);
            Assert.Empty(f.Journal.Pending());
        }

        [Fact]
        public async Task SpoolerFailureIsReportedWithItsCode()
        {
            WorkerFixture f = new WorkerFixture();
            f.Writer.Result = () => RawPrintResult.Fail("impressora_offline", "A impressora está offline.");
            f.QueueJobs(WorkerFixture.MakeJob(J1));
            await f.Worker.RunOnceAsync(CancellationToken.None);

            Assert.Equal(0, f.Api.CompleteCalls);
            Assert.Equal("impressora_offline", f.Api.FailedJobs.Single().Code);
            Assert.False(f.Api.FailedJobs.Single().Definitive);
            Assert.Empty(f.Journal.Pending());
        }

        [Fact]
        public async Task InvalidPayloadFailsDefinitivelyWithoutTouchingThePrinter()
        {
            WorkerFixture f = new WorkerFixture();
            f.QueueJobs(WorkerFixture.MakeJob(J1, payload: "{\"tipo\":\"pedido_bar\",\"itens\":[]}"));
            await f.Worker.RunOnceAsync(CancellationToken.None);

            Assert.Empty(f.Writer.Printers);
            FakeEdgeApi.FailedJob fail = f.Api.FailedJobs.Single();
            Assert.Equal("payload_invalido", fail.Code);
            Assert.True(fail.Definitive);
        }

        [Fact]
        public async Task UnexpectedExceptionInTheWriterBecomesInternalError()
        {
            WorkerFixture f = new WorkerFixture();
            f.Writer.OnWrite = () => throw new InvalidOperationException("boom");
            f.QueueJobs(WorkerFixture.MakeJob(J1));
            await f.Worker.RunOnceAsync(CancellationToken.None);

            Assert.Equal("erro_interno", f.Api.FailedJobs.Single().Code);
            Assert.Equal(0, f.Api.CompleteCalls);
        }

        [Fact]
        public async Task FailureReportRetriesWhenTheNetworkDrops()
        {
            WorkerFixture f = new WorkerFixture();
            f.Resolver.Handler = p => PrinterResolution.NotFound(p.Nome);
            int n = 0;
            f.Api.OnFail = (id, ct) => Task.FromResult(++n < 3 ? WorkerFixture.AckFail(ApiOutcome.NetworkError, 0, null) : WorkerFixture.Ack());
            f.QueueJobs(WorkerFixture.MakeJob(J1));
            await f.Worker.RunOnceAsync(CancellationToken.None);
            Assert.Equal(3, f.Api.FailCalls);
        }

        // ------------------------------------------------------------------ confirmação e diário (nunca imprimir em dobro)

        [Fact]
        public async Task ConfirmationLostKeepsJobInJournalAndLaterConfirmsWithoutReprinting()
        {
            WorkerFixture f = new WorkerFixture();
            f.QueueJobs(WorkerFixture.MakeJob(J1));
            f.Api.OnComplete = (id, ct) => Task.FromResult(WorkerFixture.AckFail(ApiOutcome.NetworkError, 0, null));

            await f.Worker.RunOnceAsync(CancellationToken.None);

            Assert.Single(f.Writer.Printers);
            Assert.Equal(3, f.Api.CompleteCalls);            // 3 tentativas imediatas
            Assert.Equal(new[] { J1 }, f.Journal.Pending().ToArray());
            Assert.Equal(0, f.Api.FailCalls);                // impresso não é falha

            // a internet volta; a próxima volta confirma pelo diário
            f.Api.OnComplete = (id, ct) => Task.FromResult(WorkerFixture.Ack());
            f.Clock.Advance(TimeSpan.FromSeconds(30));
            await f.Worker.RunOnceAsync(CancellationToken.None);

            Assert.Single(f.Writer.Printers);                // continua UMA impressão
            Assert.Empty(f.Journal.Pending());
            Assert.Equal(4, f.Api.CompleteCalls);
        }

        [Fact]
        public async Task JobReclaimedAfterAReservationExpiryIsOnlyConfirmedNotReprinted()
        {
            WorkerFixture f = new WorkerFixture();
            f.Journal.Add(J1); // já saiu na impressora antes
            f.QueueJobs(WorkerFixture.MakeJob(J1));
            // a confirmação do diário (feita antes da consulta) falha na 1ª vez: o job continua no diário e volta pela fila
            int calls = 0;
            f.Api.OnComplete = (id, ct) => Task.FromResult(calls++ == 0 ? WorkerFixture.AckFail(ApiOutcome.NetworkError, 0, null) : WorkerFixture.Ack());

            await f.Worker.RunOnceAsync(CancellationToken.None);

            Assert.Empty(f.Writer.Printers);
            Assert.Contains(J1, f.Api.CompletedJobs);
            Assert.Empty(f.Journal.Pending());
        }

        [Theory]
        [InlineData("job_cancelado")]
        [InlineData("job_inexistente")]
        [InlineData("job_nao_reservado")]
        public async Task FinalRejectionStopsRetryingAndClearsTheJournal(string code)
        {
            WorkerFixture f = new WorkerFixture();
            f.QueueJobs(WorkerFixture.MakeJob(J1));
            f.Api.OnComplete = (id, ct) => Task.FromResult(WorkerFixture.AckFail(ApiOutcome.Rejected, 400, code));
            await f.Worker.RunOnceAsync(CancellationToken.None);

            Assert.Equal(1, f.Api.CompleteCalls);
            Assert.Empty(f.Journal.Pending());
            Assert.Single(f.Writer.Printers);
        }

        [Fact]
        public async Task JournalFlushIsThrottledWhenTheServerIsUnreachable()
        {
            WorkerFixture f = new WorkerFixture();
            f.Journal.Add(J1);
            f.Api.OnComplete = (id, ct) => Task.FromResult(WorkerFixture.AckFail(ApiOutcome.NetworkError, 0, null));

            await f.Worker.RunOnceAsync(CancellationToken.None);
            await f.Worker.RunOnceAsync(CancellationToken.None);   // logo em seguida: ainda dentro do intervalo

            Assert.Equal(1, f.Api.CompleteCalls);
            f.Clock.Advance(TimeSpan.FromSeconds(16));
            await f.Worker.RunOnceAsync(CancellationToken.None);
            Assert.Equal(2, f.Api.CompleteCalls);
        }

        // ------------------------------------------------------------------ reserva (lease)

        [Fact]
        public async Task JobThatNoLongerFitsInTheLeaseIsLeftForTheServerToRecycle()
        {
            WorkerFixture f = new WorkerFixture();
            f.Writer.OnWrite = () => f.Clock.Advance(TimeSpan.FromSeconds(15)); // cada impressão "demora" 15 s
            f.QueueJobs(WorkerFixture.MakeJob(J1, reserva: 30), WorkerFixture.MakeJob(J2, reserva: 30));

            await f.Worker.RunOnceAsync(CancellationToken.None);

            Assert.Single(f.Writer.Printers);                   // o segundo ficou com 15 s < margem de 20 s
            Assert.Equal(new[] { J1 }, f.Api.CompletedJobs.ToArray());
            Assert.Equal(0, f.Api.FailCalls);
        }

        // ------------------------------------------------------------------ vínculo, credencial, rede

        [Fact]
        public async Task WithoutCredentialNothingIsQueried()
        {
            WorkerFixture f = new WorkerFixture();
            f.Access.Access = null;
            TimeSpan wait = await f.Worker.RunOnceAsync(CancellationToken.None);
            Assert.Equal(AgentConstants.JobNotLinkedDelay, wait);
            Assert.Equal(0, f.Api.ClaimCalls);
        }

        [Fact]
        public async Task RejectedCredentialBacksOffForMinutes()
        {
            WorkerFixture f = new WorkerFixture();
            f.Api.OnClaim = ct => Task.FromResult(ApiResult<ClaimJobsResponse>.Failure(ApiOutcome.Unauthorized, 401, "agente_revogado", null));
            Assert.Equal(AgentConstants.JobCredentialRejectedDelay, await f.Worker.RunOnceAsync(CancellationToken.None));
            Assert.Empty(f.Writer.Printers);
        }

        [Fact]
        public async Task RateLimitUsesRetryAfter()
        {
            WorkerFixture f = new WorkerFixture();
            f.Api.OnClaim = ct => Task.FromResult(ApiResult<ClaimJobsResponse>.Failure(ApiOutcome.RateLimited, 429, "muitas_requisicoes", TimeSpan.FromSeconds(40)));
            Assert.Equal(TimeSpan.FromSeconds(40), await f.Worker.RunOnceAsync(CancellationToken.None));
        }

        [Fact]
        public async Task NetworkFailureBacksOffExponentiallyAndRecovers()
        {
            WorkerFixture f = new WorkerFixture();
            f.Api.OnClaim = ct => Task.FromResult(ApiResult<ClaimJobsResponse>.Failure(ApiOutcome.NetworkError, 0, null, null));
            TimeSpan w1 = await f.Worker.RunOnceAsync(CancellationToken.None);
            TimeSpan w2 = await f.Worker.RunOnceAsync(CancellationToken.None);
            TimeSpan w3 = await f.Worker.RunOnceAsync(CancellationToken.None);
            Assert.Equal(TimeSpan.FromSeconds(5), w1);
            Assert.Equal(TimeSpan.FromSeconds(10), w2);
            Assert.Equal(TimeSpan.FromSeconds(20), w3);
            for (int i = 0; i < 10; i++) await f.Worker.RunOnceAsync(CancellationToken.None);
            Assert.Equal(AgentConstants.JobBackoffCap, await f.Worker.RunOnceAsync(CancellationToken.None));

            f.Api.OnClaim = ct => Task.FromResult(ApiResult<ClaimJobsResponse>.Success(new ClaimJobsResponse(), 200));
            await f.Worker.RunOnceAsync(CancellationToken.None);
            f.Api.OnClaim = ct => Task.FromResult(ApiResult<ClaimJobsResponse>.Failure(ApiOutcome.Timeout, 0, null, null));
            Assert.Equal(TimeSpan.FromSeconds(5), await f.Worker.RunOnceAsync(CancellationToken.None)); // contador voltou ao início
        }

        [Fact]
        public async Task ServerWithoutTheQueueRouteWaitsAMinuteAndSaysWhatToDo()
        {
            WorkerFixture f = new WorkerFixture();
            f.Api.OnClaim = ct => Task.FromResult(ApiResult<ClaimJobsResponse>.Failure(ApiOutcome.InvalidResponse, 404, null, null));
            Assert.Equal(AgentConstants.JobUnsupportedServerDelay, await f.Worker.RunOnceAsync(CancellationToken.None));
            Assert.Contains("migration 033", f.Log.All(), StringComparison.Ordinal);
        }

        [Fact]
        public async Task LogNeverContainsTheTokenSecret()
        {
            WorkerFixture f = new WorkerFixture();
            f.QueueJobs(WorkerFixture.MakeJob(J1));
            f.Api.OnComplete = (id, ct) => Task.FromResult(WorkerFixture.AckFail(ApiOutcome.NetworkError, 0, null));
            await f.Worker.RunOnceAsync(CancellationToken.None);

            string secret = f.Access.Access!.Token.RevealForAuthorization();
            string onlySecretPart = secret.Substring(secret.IndexOf('.') + 1);
            string log = f.Log.All();
            Assert.DoesNotContain(secret, log, StringComparison.Ordinal);
            Assert.DoesNotContain(onlySecretPart, log, StringComparison.Ordinal);
            Assert.DoesNotContain("Bearer", log, StringComparison.Ordinal);
        }

        [Fact]
        public async Task RunAsyncStopsPromptlyOnCancellation()
        {
            WorkerFixture f = new WorkerFixture();
            using (CancellationTokenSource cts = new CancellationTokenSource())
            {
                Task run = f.Worker.RunAsync(cts.Token);
                await Task.Delay(100);
                cts.Cancel();
                Task finished = await Task.WhenAny(run, Task.Delay(TimeSpan.FromSeconds(10)));
                Assert.Same(run, finished);
            }
        }
    }

    public class PrinterResolverTests
    {
        private static DiscoveryPrinterResolver Resolver(FakeDiscovery d)
        {
            return new DiscoveryPrinterResolver(d);
        }

        private static FakeDiscovery With(params PrinterInfo[] printers)
        {
            FakeDiscovery d = new FakeDiscovery();
            d.Result = DiscoveryResult.Ok(printers.ToList());
            return d;
        }

        [Fact]
        public void MatchesByStableIdentifierFirst()
        {
            PrinterInfo cozinha = Samples.Usb("COZINHA");
            PrinterInfo bar = Samples.Usb("Bematech MP-4200 HS");
            JobPrinter wanted = new JobPrinter { Nome = "outro nome", Identificador = bar.Identificador };
            PrinterResolution r = Resolver(With(cozinha, bar)).Resolve(wanted);
            Assert.True(r.Found);
            Assert.Equal("Bematech MP-4200 HS", r.Name);
        }

        [Fact]
        public void FallsBackToNameIgnoringCase()
        {
            JobPrinter wanted = new JobPrinter { Nome = "cozinha", Identificador = "nao-bate" };
            PrinterResolution r = Resolver(With(Samples.Usb("COZINHA"))).Resolve(wanted);
            Assert.True(r.Found);
            Assert.Equal("COZINHA", r.Name);
        }

        [Fact]
        public void NeverFallsBackToAnotherPrinterWhenNothingMatches()
        {
            JobPrinter wanted = new JobPrinter { Nome = "COZINHA", Identificador = "x" };
            PrinterResolution r = Resolver(With(Samples.Usb("Print iD"), Samples.Usb("TFHVIKY"))).Resolve(wanted);
            Assert.False(r.Found);
            Assert.Equal("impressora_nao_encontrada", r.ErrorCode);
            Assert.Contains("COZINHA", r.Message, StringComparison.Ordinal);
        }

        [Fact]
        public void EmptyDiscoveryMeansNotFound()
        {
            PrinterResolution r = Resolver(With()).Resolve(new JobPrinter { Nome = "COZINHA" });
            Assert.False(r.Found);
        }

        [Fact]
        public void DiscoveryFailureFallsBackToTheServerNameAndLetsTheSpoolerDecide()
        {
            FakeDiscovery d = new FakeDiscovery();
            d.Result = DiscoveryResult.Fail("spooler parado");
            PrinterResolution r = Resolver(d).Resolve(new JobPrinter { Nome = "COZINHA", Identificador = "x" });
            Assert.True(r.Found);
            Assert.Equal("COZINHA", r.Name);
        }

        [Fact]
        public void DiscoveryFailureWithoutNameIsNotFound()
        {
            FakeDiscovery d = new FakeDiscovery();
            d.Result = DiscoveryResult.Fail("spooler parado");
            Assert.False(Resolver(d).Resolve(new JobPrinter { Nome = "", Identificador = "x" }).Found);
        }

        [Fact]
        public void ReportsTheWindowsStatusForInformationOnly()
        {
            PrinterInfo p = Samples.Printer("COZINHA", PrinterConnection.Usb, PrinterStatus.Offline, null, null, "USB001");
            PrinterResolution r = Resolver(With(p)).Resolve(new JobPrinter { Nome = "COZINHA", Identificador = p.Identificador });
            Assert.True(r.Found);
            Assert.Equal(PrinterStatus.Offline, r.Status);
        }
    }

    public class SpoolerFlagsTests
    {
        [Fact]
        public void PrintedOrCompleteJobIsFinished()
        {
            Assert.True(SpoolerFlags.JobFinished(SpoolerFlags.JOB_STATUS_PRINTED));
            Assert.True(SpoolerFlags.JobFinished(SpoolerFlags.JOB_STATUS_COMPLETE));
            Assert.False(SpoolerFlags.JobFinished(SpoolerFlags.JOB_STATUS_PRINTING));
        }

        [Fact]
        public void DeletedWithoutPrintingIsDetected()
        {
            Assert.True(SpoolerFlags.JobRemovedWithoutPrinting(SpoolerFlags.JOB_STATUS_DELETED));
            Assert.False(SpoolerFlags.JobRemovedWithoutPrinting(SpoolerFlags.JOB_STATUS_DELETING | SpoolerFlags.JOB_STATUS_PRINTED));
        }

        [Theory]
        [InlineData(0x40u, "impressora_com_erro")]   // sem papel
        [InlineData(0x20u, "impressora_offline")]
        [InlineData(0x02u, "impressora_com_erro")]
        [InlineData(0x400u, "impressora_com_erro")]
        [InlineData(0x01u, "impressora_com_erro")]   // pausado
        [InlineData(0x30u, "impressora_offline")]    // imprimindo + offline
        public void JobProblemsAreMappedToCodes(uint status, string expected)
        {
            string code;
            string message;
            Assert.True(SpoolerFlags.JobProblem(status, out code, out message));
            Assert.Equal(expected, code);
            Assert.NotEmpty(message);
        }

        [Theory]
        [InlineData(0x08u)]    // spooling
        [InlineData(0x10u)]    // printing
        [InlineData(0x18u)]
        [InlineData(0x80u)]    // printed
        [InlineData(0x1010u)]  // complete (+ printing)
        public void NormalProgressIsNotAProblem(uint status)
        {
            string code;
            string message;
            Assert.False(SpoolerFlags.JobProblem(status, out code, out message));
        }

        [Fact]
        public void PrintedWinsOverErrorBits()
        {
            string code;
            string message;
            Assert.False(SpoolerFlags.JobProblem(SpoolerFlags.JOB_STATUS_PRINTED | SpoolerFlags.JOB_STATUS_ERROR, out code, out message));
        }

        [Theory]
        [InlineData(0x80u, "impressora_offline")]
        [InlineData(0x1000u, "impressora_offline")]
        [InlineData(0x10u, "impressora_com_erro")]
        [InlineData(0x02u, "impressora_com_erro")]
        [InlineData(0x400000u, "impressora_com_erro")]
        public void PrinterProblemsAreMapped(uint status, string expected)
        {
            string code;
            string message;
            Assert.True(SpoolerFlags.PrinterProblem(status, out code, out message));
            Assert.Equal(expected, code);
        }

        [Fact]
        public void IdlePrinterIsNotAProblem()
        {
            string code;
            string message;
            Assert.False(SpoolerFlags.PrinterProblem(0, out code, out message));
            Assert.False(SpoolerFlags.PrinterProblem(0x4, out code, out message)); // "Printing"/outros bits sem relação
        }

        [Theory]
        [InlineData(1801, "impressora_nao_encontrada")]
        [InlineData(2, "impressora_nao_encontrada")]
        [InlineData(1722, "impressora_nao_encontrada")]
        [InlineData(5, "acesso_negado")]
        [InlineData(1234, "erro_spooler")]
        public void OpenErrorsAreMapped(int win32, string expected)
        {
            Assert.Equal(expected, SpoolerFlags.CodeForOpenError(win32));
        }

        [Fact]
        public void ErrorCodesMatchTheDatabaseFormat()
        {
            System.Text.RegularExpressions.Regex rx = new System.Text.RegularExpressions.Regex("^[a-z][a-z0-9_]{0,39}$");
            foreach (string c in new[] { PrintErrorCodes.PrinterNotFound, PrintErrorCodes.PrinterOffline, PrintErrorCodes.PrinterError,
                PrintErrorCodes.AccessDenied, PrintErrorCodes.SpoolerError, PrintErrorCodes.InvalidPayload, PrintErrorCodes.Internal, PrintErrorCodes.Timeout })
            {
                Assert.Matches(rx, c);
            }
        }
    }

    public class PrintedJournalTests
    {
        [Fact]
        public void PersistsAcrossRestarts()
        {
            using (TempDir dir = new TempDir())
            {
                FakeClock clock = new FakeClock();
                PrintedJournal a = new PrintedJournal(dir.File("j.json"), clock, NullLogger.Instance);
                a.Add("job-1");
                a.Add("job-2");
                a.Add("job-1");   // duplicado ignorado

                PrintedJournal b = new PrintedJournal(dir.File("j.json"), clock, NullLogger.Instance);
                Assert.Equal(new[] { "job-1", "job-2" }, b.Pending().ToArray());
                Assert.True(b.Contains("JOB-1"));
                b.Remove("job-1");

                PrintedJournal c = new PrintedJournal(dir.File("j.json"), clock, NullLogger.Instance);
                Assert.Equal(new[] { "job-2" }, c.Pending().ToArray());
            }
        }

        [Fact]
        public void CorruptFileStartsEmptyWithoutThrowing()
        {
            using (TempDir dir = new TempDir())
            {
                File.WriteAllText(dir.File("j.json"), "{{{ lixo");
                PrintedJournal j = new PrintedJournal(dir.File("j.json"), new FakeClock(), NullLogger.Instance);
                Assert.Empty(j.Pending());
                j.Add("job-9");
                Assert.Single(j.Pending());
            }
        }

        [Fact]
        public void OldEntriesAreDiscarded()
        {
            using (TempDir dir = new TempDir())
            {
                FakeClock clock = new FakeClock();
                PrintedJournal a = new PrintedJournal(dir.File("j.json"), clock, NullLogger.Instance);
                a.Add("velho");
                clock.Advance(AgentConstants.PrintedJournalMaxAge + TimeSpan.FromMinutes(1));
                PrintedJournal b = new PrintedJournal(dir.File("j.json"), clock, NullLogger.Instance);
                Assert.Empty(b.Pending());
            }
        }

        [Fact]
        public void SizeIsBounded()
        {
            PrintedJournal j = new PrintedJournal(null, new FakeClock(), NullLogger.Instance);
            for (int i = 0; i < AgentConstants.PrintedJournalMaxEntries + 50; i++) j.Add("job-" + i);
            Assert.Equal(AgentConstants.PrintedJournalMaxEntries, j.Pending().Count);
            Assert.False(j.Contains("job-0"));
            Assert.True(j.Contains("job-" + (AgentConstants.PrintedJournalMaxEntries + 49)));
        }

        [Fact]
        public void JournalFileDoesNotStoreOrderContent()
        {
            using (TempDir dir = new TempDir())
            {
                PrintedJournal j = new PrintedJournal(dir.File("j.json"), new FakeClock(), NullLogger.Instance);
                j.Add("job-1");
                string text = File.ReadAllText(dir.File("j.json"));
                Assert.DoesNotContain("X-Burger", text, StringComparison.Ordinal);
                Assert.Contains("job-1", text, StringComparison.Ordinal);
            }
        }
    }

    public class PrintStatusTests
    {
        [Fact]
        public void ShowsLastSuccessAndNewerError()
        {
            FakeClock clock = new FakeClock();
            PrintActivity a = new PrintActivity(clock);
            AgentStatusDto s = new AgentStatusDto();
            bool isError;
            Assert.Equal("—", PrintStatusText.Describe(s, out isError));
            Assert.False(isError);

            a.RecordSuccess("Pedido 123 - COZINHA", "cozinha", "COZINHA");
            s.UltimaImpressao = a.Snapshot().LastSuccess;
            string ok = PrintStatusText.Describe(s, out isError);
            Assert.StartsWith("Pedido 123 - COZINHA - Sucesso (", ok, StringComparison.Ordinal);
            Assert.False(isError);

            clock.Advance(TimeSpan.FromMinutes(1));
            a.RecordFailure("Pedido 124 - BAR", "bar", "Impressora COZINHA não encontrada.");
            s.UltimoErroImpressao = a.Snapshot().LastFailure;
            Assert.Equal("Erro de impressão: Impressora COZINHA não encontrada.", PrintStatusText.Describe(s, out isError));
            Assert.True(isError);
        }

        [Fact]
        public void CoordinatorStatusHidesAnErrorOlderThanTheLastSuccess()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                PrintActivity a = new PrintActivity(f.Clock);
                f.Coordinator.PrintActivity = a;

                a.RecordFailure("Pedido 1 - BAR", "bar", "Impressora BAR offline.");
                Assert.NotNull(f.Coordinator.GetStatus().UltimoErroImpressao);

                f.Clock.Advance(TimeSpan.FromSeconds(5));
                a.RecordSuccess("Pedido 2 - BAR", "bar", "BAR");
                AgentStatusDto s = f.Coordinator.GetStatus();
                Assert.Null(s.UltimoErroImpressao);
                Assert.Equal("Pedido 2 - BAR", s.UltimaImpressao!.Titulo);
            }
        }

        [Fact]
        public void StatusJsonCarriesTheNewFieldsAndOldReadersIgnoreThem()
        {
            AgentStatusDto s = new AgentStatusDto();
            s.UltimaImpressao = new PrintEventDto { Titulo = "Pedido 1 - BAR", Destino = "bar", Sucesso = true, EmUtc = new DateTime(2026, 10, 5, 12, 0, 0, DateTimeKind.Utc) };
            string json = JsonSerializer.Serialize(s, AgentJson.Options);
            Assert.Contains("\"ultima_impressao\"", json, StringComparison.Ordinal);
            Assert.DoesNotContain("ultimo_erro_impressao", json, StringComparison.Ordinal); // nulo é omitido
            AgentStatusDto back = JsonSerializer.Deserialize<AgentStatusDto>(json, AgentJson.Options)!;
            Assert.Equal("Pedido 1 - BAR", back.UltimaImpressao!.Titulo);
        }
    }

    public class JobAccessTests
    {
        [Fact]
        public void LinkedCoordinatorGivesCredentialAndInstallation()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                JobAccess? a = f.Coordinator.GetJobAccess();
                Assert.NotNull(a);
                Assert.Equal(CoordinatorFixture.InstallationId, a!.InstallationId);
                Assert.Equal(TestTokens.Make(1).AgentId, a.Token.AgentId);
            }
        }

        [Fact]
        public void UnlinkedCoordinatorGivesNothing()
        {
            using (CoordinatorFixture f = new CoordinatorFixture())
            {
                Assert.Null(f.Coordinator.GetJobAccess());
            }
        }

        [Fact]
        public async Task RejectedCredentialStopsQueueQueries()
        {
            using (CoordinatorFixture f = new CoordinatorFixture(TestTokens.Make(1)))
            {
                f.Api.OnHeartbeat = ct => Task.FromResult(ApiResult<HeartbeatResponse>.Failure(ApiOutcome.Unauthorized, 401, "agente_revogado", null));
                await f.Coordinator.HeartbeatOnceAsync(CancellationToken.None);
                Assert.Null(f.Coordinator.GetJobAccess());
            }
        }
    }

    public class JobApiClientTests
    {
        private const string Installation = "11111111-2222-3333-4444-555555555555";
        private const string JobId = "aaaaaaaa-0000-0000-0000-000000000001";

        private static EdgeApiClient Create(RecordingHandler handler)
        {
            System.Net.Http.HttpClient http = new System.Net.Http.HttpClient(handler);
            http.BaseAddress = new Uri(AgentConstants.EdgeBaseUrl);
            return new EdgeApiClient(http);
        }

        private const string ClaimBody =
            "{\"ok\":true,\"jobs\":[" +
            "{\"id\":\"" + JobId + "\",\"destino\":\"cozinha\",\"tipo\":\"pedido_bar\",\"titulo\":\"Pedido 1 - COZINHA\",\"tentativa\":1,\"max_tentativas\":5,\"reserva_segundos\":120," +
            " \"payload\":{\"tipo\":\"pedido_bar\",\"itens\":[{\"quantidade\":1,\"nome\":\"X\"}]}," +
            " \"impressora\":{\"id\":\"p1\",\"nome\":\"COZINHA\",\"identificador\":\"abc\",\"conexao\":\"usb\",\"porta_windows\":\"USB001\"}}," +
            "{\"id\":\"nao-e-guid\",\"payload\":{},\"impressora\":{\"nome\":\"X\"}}," +
            "{\"id\":\"aaaaaaaa-0000-0000-0000-000000000003\",\"payload\":[],\"impressora\":{\"nome\":\"X\"}}," +
            "{\"id\":\"aaaaaaaa-0000-0000-0000-000000000004\",\"payload\":{},\"impressora\":{}}" +
            "]}";

        [Fact]
        public async Task ClaimSendsOnlyTheInstallationAndNeverCompanyOrStation()
        {
            RecordingHandler h = new RecordingHandler();
            h.Responder = r => Task.FromResult(RecordingHandler.Json(System.Net.HttpStatusCode.OK, ClaimBody));
            AgentToken token = TestTokens.Make(2);

            ApiResult<ClaimJobsResponse> result = await Create(h).ClaimJobsAsync(token, Installation, 3, 15, CancellationToken.None);

            Assert.True(result.IsOk);
            Assert.Equal(AgentConstants.EdgeBaseUrl + "agent/jobs/claim", h.Requests.Single().RequestUri!.ToString());
            Assert.Equal(token.RevealForAuthorization(), h.Requests.Single().Headers.Authorization!.Parameter);
            using (JsonDocument doc = JsonDocument.Parse(h.Bodies.Single()))
            {
                string[] keys = doc.RootElement.EnumerateObject().Select(p => p.Name).OrderBy(x => x, StringComparer.Ordinal).ToArray();
                Assert.Equal(new[] { "espera_segundos", "identificador_instalacao", "limite" }, keys);
                Assert.Equal(3, doc.RootElement.GetProperty("limite").GetInt32());
                Assert.Equal(15, doc.RootElement.GetProperty("espera_segundos").GetInt32());
            }
        }

        [Fact]
        public async Task ClaimParsesValidJobsAndDropsInvalidOnes()
        {
            RecordingHandler h = new RecordingHandler();
            h.Responder = r => Task.FromResult(RecordingHandler.Json(System.Net.HttpStatusCode.OK, ClaimBody));
            ApiResult<ClaimJobsResponse> result = await Create(h).ClaimJobsAsync(TestTokens.Make(2), Installation, 3, 15, CancellationToken.None);

            PrintJob job = result.Data!.Jobs.Single();
            Assert.Equal(JobId, job.Id);
            Assert.Equal("cozinha", job.Destino);
            Assert.Equal("pedido_bar", job.Tipo);
            Assert.Equal("Pedido 1 - COZINHA", job.Titulo);
            Assert.Equal(120, job.ReservaSegundos);
            Assert.Equal("COZINHA", job.Impressora.Nome);
            Assert.Equal("abc", job.Impressora.Identificador);
            Assert.Equal(JsonValueKind.Object, job.Payload.ValueKind);
            Assert.Equal("X", job.Payload.GetProperty("itens")[0].GetProperty("nome").GetString());
        }

        [Fact]
        public async Task ClaimWithoutJobsArrayIsInvalidResponse()
        {
            RecordingHandler h = new RecordingHandler();
            h.Responder = r => Task.FromResult(RecordingHandler.Json(System.Net.HttpStatusCode.OK, "{\"ok\":true}"));
            ApiResult<ClaimJobsResponse> result = await Create(h).ClaimJobsAsync(TestTokens.Make(2), Installation, 3, 15, CancellationToken.None);
            Assert.Equal(ApiOutcome.InvalidResponse, result.Outcome);
        }

        [Fact]
        public async Task ClaimLimitsAreClamped()
        {
            RecordingHandler h = new RecordingHandler();
            h.Responder = r => Task.FromResult(RecordingHandler.Json(System.Net.HttpStatusCode.OK, "{\"ok\":true,\"jobs\":[]}"));
            await Create(h).ClaimJobsAsync(TestTokens.Make(2), Installation, 99, 999, CancellationToken.None);
            using (JsonDocument doc = JsonDocument.Parse(h.Bodies.Single()))
            {
                Assert.Equal(5, doc.RootElement.GetProperty("limite").GetInt32());
                Assert.Equal(20, doc.RootElement.GetProperty("espera_segundos").GetInt32());
            }
        }

        [Fact]
        public async Task CompleteSendsJobIdAndInstallationOnly()
        {
            RecordingHandler h = new RecordingHandler();
            h.Responder = r => Task.FromResult(RecordingHandler.Json(System.Net.HttpStatusCode.OK, "{\"ok\":true,\"status\":\"impresso\",\"ja_confirmado\":false}"));
            ApiResult<JobAckResponse> result = await Create(h).CompleteJobAsync(TestTokens.Make(2), Installation, JobId, CancellationToken.None);

            Assert.True(result.IsOk);
            Assert.Equal("impresso", result.Data!.Status);
            Assert.Equal(AgentConstants.EdgeBaseUrl + "agent/jobs/complete", h.Requests.Single().RequestUri!.ToString());
            using (JsonDocument doc = JsonDocument.Parse(h.Bodies.Single()))
            {
                string[] keys = doc.RootElement.EnumerateObject().Select(p => p.Name).OrderBy(x => x, StringComparer.Ordinal).ToArray();
                Assert.Equal(new[] { "identificador_instalacao", "job_id" }, keys);
            }
        }

        [Fact]
        public async Task FailSendsCodeMessageAndDefinitiveFlag()
        {
            RecordingHandler h = new RecordingHandler();
            h.Responder = r => Task.FromResult(RecordingHandler.Json(System.Net.HttpStatusCode.OK, "{\"ok\":true,\"status\":\"pendente\",\"tentativas\":1,\"max_tentativas\":5}"));
            ApiResult<JobAckResponse> result = await Create(h).FailJobAsync(
                TestTokens.Make(2), Installation, JobId, "impressora_nao_encontrada", "Impressora COZINHA não encontrada neste computador.", false, CancellationToken.None);

            Assert.True(result.IsOk);
            Assert.Equal("pendente", result.Data!.Status);
            Assert.Equal(1, result.Data.Tentativas);
            Assert.Equal(AgentConstants.EdgeBaseUrl + "agent/jobs/fail", h.Requests.Single().RequestUri!.ToString());
            using (JsonDocument doc = JsonDocument.Parse(h.Bodies.Single()))
            {
                string[] keys = doc.RootElement.EnumerateObject().Select(p => p.Name).OrderBy(x => x, StringComparer.Ordinal).ToArray();
                Assert.Equal(new[] { "definitivo", "erro_codigo", "erro_mensagem", "identificador_instalacao", "job_id" }, keys);
                Assert.False(doc.RootElement.GetProperty("definitivo").GetBoolean());
                Assert.Equal("impressora_nao_encontrada", doc.RootElement.GetProperty("erro_codigo").GetString());
            }
        }

        [Fact]
        public async Task CredentialErrorsOnTheQueueRoutesAreUnauthorized()
        {
            RecordingHandler h = new RecordingHandler();
            h.Responder = r => Task.FromResult(RecordingHandler.Json(System.Net.HttpStatusCode.Unauthorized, "{\"ok\":false,\"erro\":\"agente_revogado\"}"));
            ApiResult<ClaimJobsResponse> result = await Create(h).ClaimJobsAsync(TestTokens.Make(2), Installation, 3, 0, CancellationToken.None);
            Assert.Equal(ApiOutcome.Unauthorized, result.Outcome);
        }

        [Fact]
        public async Task BusinessErrorsOnCompleteAreRejectedWithTheServerCode()
        {
            RecordingHandler h = new RecordingHandler();
            h.Responder = r => Task.FromResult(RecordingHandler.Json(System.Net.HttpStatusCode.BadRequest, "{\"ok\":false,\"erro\":\"job_cancelado\"}"));
            ApiResult<JobAckResponse> result = await Create(h).CompleteJobAsync(TestTokens.Make(2), Installation, JobId, CancellationToken.None);
            Assert.Equal(ApiOutcome.Rejected, result.Outcome);
            Assert.Equal("job_cancelado", result.ErrorCode);
        }
    }

    public class DocumentNameTests
    {
        [Fact]
        public void DocumentNameIsShortAsciiAndPrefixed()
        {
            PrintJob job = WorkerFixture.MakeJob("aaaaaaaa-0000-0000-0000-000000000001");
            job.Titulo = "Pedido 12 - COZINHA ção " + new string('x', 200);
            string name = PrintJobProcessor.DocumentName(job);
            Assert.StartsWith("Florest - Pedido 12", name, StringComparison.Ordinal);
            Assert.True(name.Length <= 60);
            Assert.All(name, c => Assert.True(c >= ' ' && c < 0x7F));
        }
    }
}
