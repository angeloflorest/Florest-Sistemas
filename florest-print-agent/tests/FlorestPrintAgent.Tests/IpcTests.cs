using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using FlorestPrintAgent.Core;
using FlorestPrintAgent.Core.Agent;
using FlorestPrintAgent.Core.Ipc;
using FlorestPrintAgent.Core.Printers;
using FlorestPrintAgent.Tests.TestSupport;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace FlorestPrintAgent.Tests
{
    public class IpcFramingTests
    {
        [Fact]
        public async Task FrameRoundTrip()
        {
            using (MemoryStream ms = new MemoryStream())
            {
                byte[] payload = Encoding.UTF8.GetBytes("{\"a\":1}");
                await IpcFraming.WriteFrameAsync(ms, payload, 1024, CancellationToken.None);
                ms.Position = 0;
                byte[] read = await IpcFraming.ReadFrameAsync(ms, 1024, CancellationToken.None);
                Assert.Equal(payload, read);
            }
        }

        [Fact]
        public async Task HeaderIsLittleEndianLength()
        {
            using (MemoryStream ms = new MemoryStream())
            {
                await IpcFraming.WriteFrameAsync(ms, new byte[300], 1024, CancellationToken.None);
                byte[] all = ms.ToArray();
                Assert.Equal(4 + 300, all.Length);
                Assert.Equal(300 & 0xFF, all[0]);
                Assert.Equal((300 >> 8) & 0xFF, all[1]);
                Assert.Equal(0, all[2]);
                Assert.Equal(0, all[3]);
            }
        }

        [Fact]
        public async Task OversizedDeclaredLengthIsRejectedBeforeReadingThePayload()
        {
            // cabeçalho declara 2 GB; o leitor não pode tentar alocar nem ler isso
            byte[] header = BitConverter.GetBytes(int.MaxValue);
            using (MemoryStream ms = new MemoryStream(header))
            {
                await Assert.ThrowsAsync<IpcProtocolException>(() => IpcFraming.ReadFrameAsync(ms, 1024, CancellationToken.None));
            }
        }

        [Theory]
        [InlineData(0)]
        [InlineData(-1)]
        [InlineData(1025)]
        public async Task InvalidDeclaredLengthIsRejected(int length)
        {
            using (MemoryStream ms = new MemoryStream(BitConverter.GetBytes(length)))
            {
                await Assert.ThrowsAsync<IpcProtocolException>(() => IpcFraming.ReadFrameAsync(ms, 1024, CancellationToken.None));
            }
        }

        [Fact]
        public async Task TruncatedPayloadIsRejected()
        {
            byte[] header = BitConverter.GetBytes(100);
            byte[] data = header.Concat(new byte[10]).ToArray();
            using (MemoryStream ms = new MemoryStream(data))
            {
                await Assert.ThrowsAsync<IpcProtocolException>(() => IpcFraming.ReadFrameAsync(ms, 1024, CancellationToken.None));
            }
        }

        [Fact]
        public async Task EmptyStreamIsRejected()
        {
            using (MemoryStream ms = new MemoryStream())
            {
                await Assert.ThrowsAsync<IpcProtocolException>(() => IpcFraming.ReadFrameAsync(ms, 1024, CancellationToken.None));
            }
        }

        [Fact]
        public async Task WriterRefusesEmptyAndOversizedPayloads()
        {
            using (MemoryStream ms = new MemoryStream())
            {
                await Assert.ThrowsAsync<IpcProtocolException>(() => IpcFraming.WriteFrameAsync(ms, new byte[0], 1024, CancellationToken.None));
                await Assert.ThrowsAsync<IpcProtocolException>(() => IpcFraming.WriteFrameAsync(ms, new byte[2000], 1024, CancellationToken.None));
                Assert.Equal(0, ms.Length);
            }
        }

        [Fact]
        public void MalformedJsonIsAProtocolError()
        {
            Assert.Throws<IpcProtocolException>(() => IpcSerializer.Deserialize<IpcRequest>(Encoding.UTF8.GetBytes("não é json")));
            Assert.Throws<IpcProtocolException>(() => IpcSerializer.Deserialize<IpcRequest>(Encoding.UTF8.GetBytes("null")));
        }
    }

    public class IpcSerializationTests
    {
        [Fact]
        public void RequestCarriesOnlyCommandCodePrintersAndForce()
        {
            IpcRequest request = new IpcRequest();
            request.Cmd = IpcCommands.PairConfirm;
            request.Codigo = "ABCD-2345";
            request.Impressoras = new List<PrinterInfo> { Samples.Usb("Balcao") };
            request.Forcar = true;

            string json = Encoding.UTF8.GetString(IpcSerializer.Serialize(request));
            using (JsonDocument doc = JsonDocument.Parse(json))
            {
                HashSet<string> keys = new HashSet<string>(doc.RootElement.EnumerateObject().Select(p => p.Name));
                Assert.True(keys.IsSubsetOf(new HashSet<string> { "v", "cmd", "codigo", "impressoras", "forcar" }));
            }
            Assert.DoesNotContain("token", json, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain("secret", json, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain("authorization", json, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain("sessao", json, StringComparison.OrdinalIgnoreCase); // a identidade não vai na mensagem
        }

        [Fact]
        public void StatusResponseHasNoTokenFields()
        {
            AgentStatusDto status = new AgentStatusDto();
            status.Estado = AgentStatusKind.Conectado;
            status.Computador = "PC-CAIXA";
            status.Empresa = "Distribuidora";
            status.Vinculado = true;

            string json = Encoding.UTF8.GetString(IpcSerializer.Serialize(IpcResponse.Success(status)));
            Assert.DoesNotContain("token", json, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain("credencial", json, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain("fpa_", json, StringComparison.Ordinal);
        }

        [Fact]
        public void ResponseRoundTripKeepsOkErroMensagemAndDados()
        {
            PairingPreviewDto preview = new PairingPreviewDto();
            preview.Empresa = "Distribuidora Florest";
            preview.Estacao = "Caixa 1";
            preview.Reinstalacao = true;

            IpcResponse ok = IpcSerializer.Deserialize<IpcResponse>(IpcSerializer.Serialize(IpcResponse.Success(preview, "ok!")));
            Assert.True(ok.Ok);
            Assert.Equal("ok!", ok.Mensagem);
            PairingPreviewDto? back = ok.ReadData<PairingPreviewDto>();
            Assert.NotNull(back);
            Assert.Equal("Distribuidora Florest", back!.Empresa);
            Assert.Equal("Caixa 1", back.Estacao);
            Assert.True(back.Reinstalacao);

            IpcResponse fail = IpcSerializer.Deserialize<IpcResponse>(IpcSerializer.Serialize(IpcResponse.Fail("codigo_invalido", "Código inválido")));
            Assert.False(fail.Ok);
            Assert.Equal("codigo_invalido", fail.Erro);
            Assert.Equal("Código inválido", fail.Mensagem);
            Assert.Null(fail.ReadData<PairingPreviewDto>());
        }

        [Fact]
        public void ReadDataReturnsNullForIncompatibleShape()
        {
            IpcResponse r = IpcResponse.Success(new List<int> { 1, 2, 3 });
            Assert.Null(r.ReadData<PairingPreviewDto>());
        }

        [Fact]
        public void PrinterListSerializationMatchesTheServerContractFieldNames()
        {
            PrinterInfo p = Samples.Printer("Cozinha", PrinterConnection.Rede, PrinterStatus.Disponivel, "192.168.0.50", 9100, "IP_192.168.0.50");
            string json = JsonSerializer.Serialize(p, AgentJson.WireOptions);
            using (JsonDocument doc = JsonDocument.Parse(json))
            {
                string[] names = doc.RootElement.EnumerateObject().Select(x => x.Name).OrderBy(x => x, StringComparer.Ordinal).ToArray();
                Assert.Equal(new[] { "conexao", "identificador", "ip", "nome", "porta", "porta_windows", "status" }, names);
            }
        }

        [Fact]
        public void UnknownIpAndPortAreSentAsExplicitNull()
        {
            PrinterInfo p = Samples.Usb("Balcao");
            string json = JsonSerializer.Serialize(p, AgentJson.WireOptions);
            using (JsonDocument doc = JsonDocument.Parse(json))
            {
                Assert.Equal(JsonValueKind.Null, doc.RootElement.GetProperty("ip").ValueKind);
                Assert.Equal(JsonValueKind.Null, doc.RootElement.GetProperty("porta").ValueKind);
            }
        }
    }

    public class IpcCommandHandlerTests
    {
        private static IpcCommandHandler Create(FakeController controller)
        {
            return new IpcCommandHandler(controller, NullLogger.Instance);
        }

        private static IpcRequest Req(string cmd)
        {
            IpcRequest r = new IpcRequest();
            r.Cmd = cmd;
            return r;
        }

        [Fact]
        public async Task GetStatusReturnsTheControllerStatus()
        {
            IpcResponse r = await Create(new FakeController()).HandleAsync(Req(IpcCommands.GetStatus), TestCallers.Alice, CancellationToken.None);
            Assert.True(r.Ok);
            AgentStatusDto? dto = r.ReadData<AgentStatusDto>();
            Assert.Equal("PC-TESTE", dto!.Computador);
        }

        [Fact]
        public async Task UnknownCommandIsRefused()
        {
            IpcResponse r = await Create(new FakeController()).HandleAsync(Req("FormatarDisco"), TestCallers.Alice, CancellationToken.None);
            Assert.False(r.Ok);
            Assert.Equal("comando_invalido", r.Erro);
        }

        [Fact]
        public async Task UnsupportedProtocolVersionIsRefused()
        {
            IpcRequest request = Req(IpcCommands.GetStatus);
            request.Version = 99;
            IpcResponse r = await Create(new FakeController()).HandleAsync(request, TestCallers.Alice, CancellationToken.None);
            Assert.False(r.Ok);
            Assert.Equal("versao_nao_suportada", r.Erro);
        }

        [Fact]
        public async Task PairVerifyNormalizesTheCodeBeforeCallingTheController()
        {
            FakeController controller = new FakeController();
            IpcRequest request = Req(IpcCommands.PairVerify);
            request.Codigo = " abcd 2345 ";
            IpcResponse r = await Create(controller).HandleAsync(request, TestCallers.Alice, CancellationToken.None);
            Assert.True(r.Ok);
            Assert.Equal(new[] { "ABCD-2345" }, controller.VerifiedCodes.ToArray());
        }

        [Theory]
        [InlineData(null)]
        [InlineData("")]
        [InlineData("1234-5678")]
        [InlineData("ABCD-23")]
        [InlineData("'; DROP TABLE --")]
        public async Task InvalidCodesNeverReachTheController(string? code)
        {
            FakeController controller = new FakeController();
            IpcRequest verify = Req(IpcCommands.PairVerify);
            verify.Codigo = code;
            IpcRequest confirm = Req(IpcCommands.PairConfirm);
            confirm.Codigo = code;

            IpcResponse a = await Create(controller).HandleAsync(verify, TestCallers.Alice, CancellationToken.None);
            IpcResponse b = await Create(controller).HandleAsync(confirm, TestCallers.Alice, CancellationToken.None);

            Assert.False(a.Ok);
            Assert.False(b.Ok);
            Assert.Equal("codigo_invalido", a.Erro);
            Assert.Equal("codigo_invalido", b.Erro);
            Assert.Empty(controller.VerifiedCodes);
            Assert.Empty(controller.ConfirmedCodes);
        }

        [Fact]
        public async Task PairConfirmPassesTheNormalizedCode()
        {
            FakeController controller = new FakeController();
            IpcRequest request = Req(IpcCommands.PairConfirm);
            request.Codigo = "efgh6789";
            IpcResponse r = await Create(controller).HandleAsync(request, TestCallers.Alice, CancellationToken.None);
            Assert.True(r.Ok);
            Assert.Equal(new[] { "EFGH-6789" }, controller.ConfirmedCodes.ToArray());
        }

        [Fact]
        public async Task SubmitUserPrintersSanitizesTheListAndUsesTheWindowsIdentityAsSession()
        {
            FakeController controller = new FakeController();
            IpcRequest request = Req(IpcCommands.SubmitUserPrinters);
            PrinterInfo invalid = Samples.Usb("Quebrada");
            invalid.Identificador = "nao-e-sha256";
            PrinterInfo withBadIp = Samples.Usb("Balcao");
            withBadIp.Ip = "inventado";
            request.Impressoras = new List<PrinterInfo> { Samples.Usb("Cozinha"), invalid, withBadIp };

            IpcResponse r = await Create(controller).HandleAsync(request, TestCallers.Alice, CancellationToken.None);
            Assert.True(r.Ok);
            Assert.Single(controller.Submitted);
            Assert.Equal(2, controller.Submitted[0].Count);
            Assert.All(controller.Submitted[0], p => Assert.Null(p.Ip));
            Assert.Equal(TestCallers.Alice.Key, controller.Sessions[0]);

            // outro usuário do Windows cai em OUTRA sessão: não consegue sobrescrever a lista da Alice
            IpcResponse other = await Create(controller).HandleAsync(request, TestCallers.Bob, CancellationToken.None);
            Assert.True(other.Ok);
            Assert.Equal(TestCallers.Bob.Key, controller.Sessions[1]);
            Assert.NotEqual(controller.Sessions[0], controller.Sessions[1]);
        }

        [Fact]
        public async Task SubmitUserPrintersWithoutAListIsRefusedNotTreatedAsEmpty()
        {
            // lista ausente != lista vazia: nunca pode virar "o usuário não tem impressoras"
            FakeController controller = new FakeController();
            IpcRequest request = Req(IpcCommands.SubmitUserPrinters);
            request.Impressoras = null;
            IpcResponse r = await Create(controller).HandleAsync(request, TestCallers.Alice, CancellationToken.None);
            Assert.False(r.Ok);
            Assert.Empty(controller.Submitted);
        }

        [Fact]
        public async Task EmptyListWithASessionIsAccepted()
        {
            FakeController controller = new FakeController();
            IpcRequest request = Req(IpcCommands.SubmitUserPrinters);
            request.Impressoras = new List<PrinterInfo>();
            IpcResponse r = await Create(controller).HandleAsync(request, TestCallers.Alice, CancellationToken.None);
            Assert.True(r.Ok);
            Assert.Single(controller.Submitted);
            Assert.Empty(controller.Submitted[0]);
        }

        [Fact]
        public async Task SubmitUserPrintersLimitsTheNumberOfPrinters()
        {
            FakeController controller = new FakeController();
            IpcRequest request = Req(IpcCommands.SubmitUserPrinters);
            request.Impressoras = new List<PrinterInfo>();
            for (int i = 0; i < 500; i++) request.Impressoras.Add(Samples.Printer("P" + i, PrinterConnection.Windows, PrinterStatus.Disponivel, null, null, "X" + i));
            await Create(controller).HandleAsync(request, TestCallers.Alice, CancellationToken.None);
            Assert.Equal(AgentConstants.MaxPrintersPerSync, controller.Submitted[0].Count);
        }

        [Fact]
        public async Task UnlinkForwardsTheForceFlag()
        {
            FakeController controller = new FakeController();
            IpcRequest normal = Req(IpcCommands.Unlink);
            IpcRequest forced = Req(IpcCommands.Unlink);
            forced.Forcar = true;
            await Create(controller).HandleAsync(normal, TestCallers.Alice, CancellationToken.None);
            await Create(controller).HandleAsync(forced, TestCallers.Alice, CancellationToken.None);
            Assert.Equal(new[] { false, true }, controller.UnlinkForce.ToArray());
        }

        [Fact]
        public async Task ScanPrintersCallsTheController()
        {
            FakeController controller = new FakeController();
            IpcResponse r = await Create(controller).HandleAsync(Req(IpcCommands.ScanPrinters), TestCallers.Alice, CancellationToken.None);
            Assert.True(r.Ok);
            Assert.Equal(1, controller.ScanCalls);
        }

        [Fact]
        public async Task ControllerExceptionBecomesAGenericErrorWithoutDetails()
        {
            FakeController controller = new FakeController();
            controller.ThrowOnStatus = new InvalidOperationException("detalhe interno secreto");
            IpcResponse r = await Create(controller).HandleAsync(Req(IpcCommands.GetStatus), TestCallers.Alice, CancellationToken.None);
            Assert.False(r.Ok);
            Assert.Equal("erro_interno", r.Erro);
            Assert.DoesNotContain("secreto", r.Mensagem ?? string.Empty, StringComparison.Ordinal);
        }

        [Fact]
        public async Task CancellationIsPropagatedNotSwallowed()
        {
            FakeController controller = new FakeController();
            controller.ThrowOnStatus = new OperationCanceledException();
            await Assert.ThrowsAsync<OperationCanceledException>(() => Create(controller).HandleAsync(Req(IpcCommands.GetStatus), TestCallers.Alice, CancellationToken.None));
        }
    }

    public class IpcPipeRoundTripTests
    {
        private static string NewPipeName()
        {
            return "FlorestPrintAgent.Test." + Guid.NewGuid().ToString("N");
        }

        /// <summary>Servidor mínimo (mesmo enquadramento e mesmo IpcCommandHandler do serviço real, sem ACL do Windows).</summary>
        private static Task RunServerOnce(string pipeName, IpcCommandHandler handler, Task clientDone, CancellationToken ct)
        {
            return Task.Run(async () =>
            {
                using (NamedPipeServerStream server = new NamedPipeServerStream(pipeName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous))
                {
                    await server.WaitForConnectionAsync(ct);
                    byte[] payload = await IpcFraming.ReadFrameAsync(server, AgentConstants.MaxIpcSubmitBytes, ct);
                    IpcRequest request = IpcSerializer.Deserialize<IpcRequest>(payload);
                    IpcResponse response = await handler.HandleAsync(request, TestCallers.Alice, ct);
                    await IpcFraming.WriteFrameAsync(server, IpcSerializer.Serialize(response), AgentConstants.MaxIpcResponseBytes, ct);
                    await clientDone;
                }
            }, ct);
        }

        [Fact]
        public async Task ClientAndServerExchangeStatusOverARealNamedPipe()
        {
            using (CancellationTokenSource cts = new CancellationTokenSource(TimeSpan.FromSeconds(30)))
            {
                string pipe = NewPipeName();
                FakeController controller = new FakeController();
                IpcCommandHandler handler = new IpcCommandHandler(controller, NullLogger.Instance);
                TaskCompletionSource<bool> done = new TaskCompletionSource<bool>();
                Task server = RunServerOnce(pipe, handler, done.Task, cts.Token);

                AgentClient client = new AgentClient(new IpcClient(pipe));
                ClientResult result = await client.GetStatusAsync(cts.Token);
                done.SetResult(true);
                await server;

                Assert.True(result.Ok);
                AgentStatusDto? status = result.Data<AgentStatusDto>();
                Assert.Equal(AgentStatusKind.Conectado, status!.Estado);
            }
        }

        [Fact]
        public async Task PairVerifyTravelsThroughThePipeNormalized()
        {
            using (CancellationTokenSource cts = new CancellationTokenSource(TimeSpan.FromSeconds(30)))
            {
                string pipe = NewPipeName();
                FakeController controller = new FakeController();
                IpcCommandHandler handler = new IpcCommandHandler(controller, NullLogger.Instance);
                TaskCompletionSource<bool> done = new TaskCompletionSource<bool>();
                Task server = RunServerOnce(pipe, handler, done.Task, cts.Token);

                AgentClient client = new AgentClient(new IpcClient(pipe));
                ClientResult result = await client.PairVerifyAsync("abcd2345", cts.Token);
                done.SetResult(true);
                await server;

                Assert.True(result.Ok);
                Assert.Equal("Empresa Teste", result.Data<PairingPreviewDto>()!.Empresa);
                Assert.Equal(new[] { "ABCD-2345" }, controller.VerifiedCodes.ToArray());
            }
        }

        [Fact]
        public async Task SubmittedPrintersArriveSanitizedThroughThePipe()
        {
            using (CancellationTokenSource cts = new CancellationTokenSource(TimeSpan.FromSeconds(30)))
            {
                string pipe = NewPipeName();
                FakeController controller = new FakeController();
                IpcCommandHandler handler = new IpcCommandHandler(controller, NullLogger.Instance);
                TaskCompletionSource<bool> done = new TaskCompletionSource<bool>();
                Task server = RunServerOnce(pipe, handler, done.Task, cts.Token);

                PrinterInfo bad = Samples.Usb("Ruim");
                bad.Identificador = "invalido";
                AgentClient client = new AgentClient(new IpcClient(pipe));
                ClientResult result = await client.SubmitUserPrintersAsync(new List<PrinterInfo> { Samples.Usb("Balcao"), bad }, cts.Token);
                done.SetResult(true);
                await server;

                Assert.True(result.Ok);
                Assert.Single(controller.Submitted);
                Assert.Equal("Balcao", controller.Submitted[0].Single().Nome);
            }
        }

        [Fact]
        public async Task ClientReportsServiceUnavailableWhenNobodyListens()
        {
            using (CancellationTokenSource cts = new CancellationTokenSource(TimeSpan.FromSeconds(30)))
            {
                AgentClient client = new AgentClient(new IpcClient(NewPipeName()));
                ClientResult result = await client.GetStatusAsync(cts.Token);
                Assert.False(result.Ok);
                Assert.NotNull(result.Erro);
                Assert.False(string.IsNullOrEmpty(result.Mensagem));
            }
        }
    }
}
