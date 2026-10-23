using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using FlorestPrintAgent.Core;
using FlorestPrintAgent.Core.Api;
using FlorestPrintAgent.Core.Printers;
using FlorestPrintAgent.Core.Security;
using FlorestPrintAgent.Tests.TestSupport;
using Xunit;

namespace FlorestPrintAgent.Tests
{
    /// <summary>Handler HTTP de teste: registra a requisição (inclusive o corpo) e devolve a resposta configurada.</summary>
    internal sealed class RecordingHandler : HttpMessageHandler
    {
        public List<HttpRequestMessage> Requests { get; } = new List<HttpRequestMessage>();
        public List<string> Bodies { get; } = new List<string>();
        public Func<HttpRequestMessage, Task<HttpResponseMessage>> Responder { get; set; }

        public RecordingHandler()
        {
            Responder = r => Task.FromResult(Json(HttpStatusCode.OK, "{\"ok\":true}"));
        }

        public static HttpResponseMessage Json(HttpStatusCode status, string body)
        {
            HttpResponseMessage response = new HttpResponseMessage(status);
            response.Content = new StringContent(body, Encoding.UTF8, "application/json");
            return response;
        }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            string body = request.Content != null ? await request.Content.ReadAsStringAsync(cancellationToken) : string.Empty;
            lock (Requests)
            {
                Requests.Add(request);
                Bodies.Add(body);
            }
            return await Responder(request);
        }
    }

    public class EdgeApiClientTests
    {
        private const string Installation = "11111111-2222-3333-4444-555555555555";

        private static EdgeApiClient Create(RecordingHandler handler)
        {
            HttpClient http = new HttpClient(handler);
            http.BaseAddress = new Uri(AgentConstants.EdgeBaseUrl);
            return new EdgeApiClient(http);
        }

        private static string Token(AgentToken t)
        {
            return t.RevealForAuthorization();
        }

        // ------------------------------------------------------------------ construção

        [Fact]
        public void EndpointConstantIsHttpsAndEndsWithSlash()
        {
            Uri uri = new Uri(AgentConstants.EdgeBaseUrl);
            Assert.Equal("https", uri.Scheme);
            Assert.EndsWith("/", AgentConstants.EdgeBaseUrl, StringComparison.Ordinal);
            Assert.Equal("etulhyboogqhyyevpnlo.supabase.co", uri.Host);
            Assert.Equal("/functions/v1/florest-print-agent/", uri.AbsolutePath);
        }

        [Fact]
        public void RefusesNonHttpsBaseAddress()
        {
            HttpClient http = new HttpClient(new RecordingHandler());
            http.BaseAddress = new Uri("http://exemplo.com/funcao/");
            Assert.Throws<ArgumentException>(() => new EdgeApiClient(http));
        }

        [Fact]
        public void RefusesMissingBaseAddressAndMissingTrailingSlash()
        {
            Assert.Throws<ArgumentException>(() => new EdgeApiClient(new HttpClient(new RecordingHandler())));
            HttpClient noSlash = new HttpClient(new RecordingHandler());
            noSlash.BaseAddress = new Uri("https://exemplo.com/funcao");
            Assert.Throws<ArgumentException>(() => new EdgeApiClient(noSlash));
        }

        // ------------------------------------------------------------------ o que é enviado

        [Fact]
        public async Task HeartbeatSendsBearerTokenUserAgentAndExactBody()
        {
            RecordingHandler handler = new RecordingHandler();
            handler.Responder = r => Task.FromResult(RecordingHandler.Json(HttpStatusCode.OK, "{\"ok\":true,\"heartbeat_segundos\":90}"));
            EdgeApiClient api = Create(handler);
            AgentToken token = TestTokens.Make(2);

            ApiResult<HeartbeatResponse> result = await api.HeartbeatAsync(token, Installation, "1.0.0", CancellationToken.None);

            Assert.True(result.IsOk);
            Assert.Equal(90, result.Data!.HeartbeatSegundos);

            HttpRequestMessage request = handler.Requests.Single();
            Assert.Equal(HttpMethod.Post, request.Method);
            Assert.Equal(AgentConstants.EdgeBaseUrl + "agent/heartbeat", request.RequestUri!.ToString());
            Assert.Equal("Bearer", request.Headers.Authorization!.Scheme);
            Assert.Equal(Token(token), request.Headers.Authorization.Parameter);
            Assert.Contains("FlorestPrintAgent/1.2.0", request.Headers.UserAgent.ToString(), StringComparison.Ordinal);
            Assert.False(request.Headers.Contains("apikey"));

            using (JsonDocument doc = JsonDocument.Parse(handler.Bodies.Single()))
            {
                string[] keys = doc.RootElement.EnumerateObject().Select(p => p.Name).OrderBy(x => x, StringComparer.Ordinal).ToArray();
                Assert.Equal(new[] { "identificador_instalacao", "versao_agente" }, keys);
                Assert.Equal(Installation, doc.RootElement.GetProperty("identificador_instalacao").GetString());
                Assert.Equal("1.0.0", doc.RootElement.GetProperty("versao_agente").GetString());
            }
        }

        [Fact]
        public async Task PairVerifyIsUnauthenticatedAndSendsOnlyTheCode()
        {
            RecordingHandler handler = new RecordingHandler();
            handler.Responder = r => Task.FromResult(RecordingHandler.Json(HttpStatusCode.OK, "{\"ok\":true,\"empresa_nome\":\"Distribuidora Florest\",\"estacao_nome\":\"Caixa 1\",\"reinstalacao\":false}"));
            ApiResult<PairVerifyResponse> result = await Create(handler).PairVerifyAsync("ABCD-2345", CancellationToken.None);

            Assert.True(result.IsOk);
            Assert.Equal("Distribuidora Florest", result.Data!.EmpresaNome);
            Assert.Equal("Caixa 1", result.Data.EstacaoNome);
            Assert.Null(handler.Requests.Single().Headers.Authorization);
            Assert.Equal(AgentConstants.EdgeBaseUrl + "pair/verify", handler.Requests.Single().RequestUri!.ToString());

            using (JsonDocument doc = JsonDocument.Parse(handler.Bodies.Single()))
            {
                Assert.Equal(new[] { "codigo" }, doc.RootElement.EnumerateObject().Select(p => p.Name).ToArray());
                Assert.Equal("ABCD-2345", doc.RootElement.GetProperty("codigo").GetString());
            }
        }

        [Fact]
        public async Task PairConfirmSendsExactlyTheContractFieldsAndNeverAnEmpresaId()
        {
            AgentToken issued = TestTokens.Make(4);
            RecordingHandler handler = new RecordingHandler();
            handler.Responder = r => Task.FromResult(RecordingHandler.Json(HttpStatusCode.OK,
                "{\"ok\":true,\"token\":\"" + Token(issued) + "\",\"empresa_nome\":\"Distribuidora\",\"estacao_nome\":\"Caixa 1\",\"reinstalacao\":true,\"heartbeat_segundos\":120,\"sincronizar_agora\":true,\"limites\":{\"impressoras_sync_max\":100,\"payload_max_bytes\":262144}}"));

            PairConfirmRequest request = new PairConfirmRequest();
            request.Codigo = "ABCD-2345";
            request.IdentificadorInstalacao = Installation;
            request.NomeComputador = "PC-CAIXA";
            request.SistemaOperacional = "Microsoft Windows 10.0.22631";
            request.VersaoAgente = "1.0.0";

            ApiResult<PairConfirmResponse> result = await Create(handler).PairConfirmAsync(request, CancellationToken.None);

            Assert.True(result.IsOk);
            Assert.Equal(Token(issued), Token(result.Data!.Token));
            Assert.True(result.Data.Reinstalacao);
            Assert.True(result.Data.SincronizarAgora);
            Assert.Equal(120, result.Data.HeartbeatSegundos);
            Assert.Equal(100, result.Data.LimiteImpressoras);
            Assert.Equal(262144, result.Data.LimiteBytes);
            Assert.Null(handler.Requests.Single().Headers.Authorization);

            using (JsonDocument doc = JsonDocument.Parse(handler.Bodies.Single()))
            {
                string[] keys = doc.RootElement.EnumerateObject().Select(p => p.Name).OrderBy(x => x, StringComparer.Ordinal).ToArray();
                Assert.Equal(new[] { "codigo", "identificador_instalacao", "nome_computador", "sistema_operacional", "versao_agente" }, keys);
            }
            Assert.DoesNotContain("empresa_id", handler.Bodies.Single(), StringComparison.Ordinal);
            Assert.DoesNotContain("estacao_id", handler.Bodies.Single(), StringComparison.Ordinal);
        }

        [Fact]
        public async Task SyncSendsPrintersWithExplicitNullsAndNoCompanyId()
        {
            RecordingHandler handler = new RecordingHandler();
            handler.Responder = r => Task.FromResult(RecordingHandler.Json(HttpStatusCode.OK,
                "{\"ok\":true,\"recebidas\":2,\"validas\":2,\"rejeitadas\":0,\"novas\":1,\"alteradas\":1,\"desativadas\":0,\"ativas\":2}"));

            SyncRequest request = new SyncRequest();
            request.IdentificadorInstalacao = Installation;
            request.NomeComputador = "PC-CAIXA";
            request.SistemaOperacional = "Windows";
            request.Impressoras.Add(Samples.Usb("Balcao"));
            request.Impressoras.Add(Samples.Printer("Cozinha", PrinterConnection.Rede, PrinterStatus.Disponivel, "192.168.0.50", 9100, "IP_192.168.0.50"));

            ApiResult<SyncResponse> result = await Create(handler).SyncAsync(TestTokens.Make(2), request, CancellationToken.None);

            Assert.True(result.IsOk);
            Assert.Equal(2, result.Data!.Ativas);
            Assert.Equal(1, result.Data.Novas);

            using (JsonDocument doc = JsonDocument.Parse(handler.Bodies.Single()))
            {
                string[] keys = doc.RootElement.EnumerateObject().Select(p => p.Name).OrderBy(x => x, StringComparer.Ordinal).ToArray();
                Assert.Equal(new[] { "identificador_instalacao", "impressoras", "nome_computador", "sistema_operacional", "versao_agente" }, keys);
                JsonElement printers = doc.RootElement.GetProperty("impressoras");
                Assert.Equal(2, printers.GetArrayLength());
                JsonElement usb = printers.EnumerateArray().Single(p => p.GetProperty("nome").GetString() == "Balcao");
                Assert.Equal(JsonValueKind.Null, usb.GetProperty("ip").ValueKind);
                Assert.Equal(JsonValueKind.Null, usb.GetProperty("porta").ValueKind);
            }
            Assert.DoesNotContain("empresa_id", handler.Bodies.Single(), StringComparison.Ordinal);
        }

        [Fact]
        public async Task EmptyPrinterListIsSentAsAnEmptyArray()
        {
            RecordingHandler handler = new RecordingHandler();
            handler.Responder = r => Task.FromResult(RecordingHandler.Json(HttpStatusCode.OK, "{\"ok\":true}"));
            SyncRequest request = new SyncRequest();
            request.IdentificadorInstalacao = Installation;
            await Create(handler).SyncAsync(TestTokens.Make(2), request, CancellationToken.None);
            using (JsonDocument doc = JsonDocument.Parse(handler.Bodies.Single()))
            {
                Assert.Equal(0, doc.RootElement.GetProperty("impressoras").GetArrayLength());
            }
        }

        [Fact]
        public async Task SyncOverThePrinterLimitIsNeverSent()
        {
            RecordingHandler handler = new RecordingHandler();
            SyncRequest request = new SyncRequest();
            request.IdentificadorInstalacao = Installation;
            for (int i = 0; i < AgentConstants.MaxPrintersPerSync + 1; i++)
                request.Impressoras.Add(Samples.Printer("P" + i, PrinterConnection.Windows, PrinterStatus.Disponivel, null, null, "X" + i));

            ApiResult<SyncResponse> result = await Create(handler).SyncAsync(TestTokens.Make(2), request, CancellationToken.None);

            Assert.False(result.IsOk);
            Assert.Equal(ApiOutcome.Rejected, result.Outcome);
            Assert.Equal("limite_excedido", result.ErrorCode);
            Assert.Empty(handler.Requests);
        }

        [Fact]
        public async Task SyncOverTheByteLimitIsNeverSent()
        {
            RecordingHandler handler = new RecordingHandler();
            SyncRequest request = new SyncRequest();
            request.IdentificadorInstalacao = Installation;
            request.NomeComputador = new string('x', AgentConstants.MaxSyncBodyBytes + 10);
            ApiResult<SyncResponse> result = await Create(handler).SyncAsync(TestTokens.Make(2), request, CancellationToken.None);
            Assert.Equal(ApiOutcome.Rejected, result.Outcome);
            Assert.Empty(handler.Requests);
        }

        [Fact]
        public async Task RenewAndUnlinkUseTheirRoutesWithBearerAndOnlyTheInstallationId()
        {
            AgentToken renewed = TestTokens.Make(2, 3);
            RecordingHandler handler = new RecordingHandler();
            handler.Responder = r =>
            {
                if (r.RequestUri!.AbsolutePath.EndsWith("agent/renew", StringComparison.Ordinal))
                    return Task.FromResult(RecordingHandler.Json(HttpStatusCode.OK, "{\"ok\":true,\"token\":\"" + Token(renewed) + "\",\"graca_segundos\":900}"));
                return Task.FromResult(RecordingHandler.Json(HttpStatusCode.OK, "{\"ok\":true}"));
            };
            EdgeApiClient api = Create(handler);
            AgentToken current = TestTokens.Make(2);

            ApiResult<RenewResponse> renew = await api.RenewAsync(current, Installation, CancellationToken.None);
            ApiResult<EmptyResponse> unlink = await api.UnlinkAsync(current, Installation, CancellationToken.None);

            Assert.True(renew.IsOk);
            Assert.Equal(Token(renewed), Token(renew.Data!.Token));
            Assert.Equal(900, renew.Data.GracaSegundos);
            Assert.True(unlink.IsOk);

            Assert.EndsWith("agent/renew", handler.Requests[0].RequestUri!.ToString(), StringComparison.Ordinal);
            Assert.EndsWith("agent/unlink", handler.Requests[1].RequestUri!.ToString(), StringComparison.Ordinal);
            foreach (HttpRequestMessage r in handler.Requests) Assert.Equal(Token(current), r.Headers.Authorization!.Parameter);
            foreach (string body in handler.Bodies)
            {
                using (JsonDocument doc = JsonDocument.Parse(body))
                {
                    Assert.Equal(new[] { "identificador_instalacao" }, doc.RootElement.EnumerateObject().Select(p => p.Name).ToArray());
                }
            }
        }

        [Fact]
        public async Task RequestsNeverFollowRedirectsInTheTestHandlerContract()
        {
            // O cliente real é criado com AllowAutoRedirect=false (Program.cs do serviço). Aqui garantimos que uma
            // resposta 3xx nunca é tratada como sucesso.
            RecordingHandler handler = new RecordingHandler();
            handler.Responder = r => Task.FromResult(RecordingHandler.Json(HttpStatusCode.Found, "{\"ok\":true}"));
            ApiResult<HeartbeatResponse> result = await Create(handler).HeartbeatAsync(TestTokens.Make(2), Installation, "1.0.0", CancellationToken.None);
            Assert.False(result.IsOk);
            Assert.Equal(ApiOutcome.InvalidResponse, result.Outcome);
        }

        // ------------------------------------------------------------------ como as respostas são tratadas

        private static Task<ApiResult<HeartbeatResponse>> HeartbeatWith(HttpStatusCode status, string body, Action<HttpResponseMessage>? tweak)
        {
            RecordingHandler handler = new RecordingHandler();
            handler.Responder = r =>
            {
                HttpResponseMessage response = RecordingHandler.Json(status, body);
                if (tweak != null) tweak(response);
                return Task.FromResult(response);
            };
            return Create(handler).HeartbeatAsync(TestTokens.Make(2), Installation, "1.0.0", CancellationToken.None);
        }

        [Fact]
        public async Task OkBodyWithOkFalseIsInvalid()
        {
            ApiResult<HeartbeatResponse> r = await HeartbeatWith(HttpStatusCode.OK, "{\"ok\":false}", null);
            Assert.Equal(ApiOutcome.InvalidResponse, r.Outcome);
        }

        [Theory]
        [InlineData("não é json")]
        [InlineData("[]")]
        [InlineData("\"texto\"")]
        [InlineData("")]
        public async Task NonObjectOrMalformedSuccessBodiesAreInvalid(string body)
        {
            ApiResult<HeartbeatResponse> r = await HeartbeatWith(HttpStatusCode.OK, body, null);
            Assert.Equal(ApiOutcome.InvalidResponse, r.Outcome);
        }

        [Theory]
        [InlineData("credencial_invalida")]
        [InlineData("agente_revogado")]
        [InlineData("empresa_inativa")]
        [InlineData("estacao_inativa")]
        [InlineData("instalacao_divergente")]
        public async Task Http401WithCredentialErrorIsUnauthorized(string code)
        {
            ApiResult<HeartbeatResponse> r = await HeartbeatWith(HttpStatusCode.Unauthorized, "{\"ok\":false,\"erro\":\"" + code + "\"}", null);
            Assert.Equal(ApiOutcome.Unauthorized, r.Outcome);
            Assert.Equal(code, r.ErrorCode);
            Assert.Equal(401, r.HttpStatus);
        }

        [Fact]
        public async Task GatewayInvalidJwt401IsNotACredentialRejection()
        {
            // Verify JWT ligado por engano na função: o 401 vem do gateway, não da nossa lógica.
            ApiResult<HeartbeatResponse> r = await HeartbeatWith(HttpStatusCode.Unauthorized, "{\"code\":401,\"message\":\"Invalid JWT\"}", null);
            Assert.Equal(ApiOutcome.InvalidResponse, r.Outcome);
            Assert.Equal(401, r.HttpStatus);
        }

        [Fact]
        public async Task Http401WithUnknownErrorIsNotACredentialRejection()
        {
            ApiResult<HeartbeatResponse> r = await HeartbeatWith(HttpStatusCode.Unauthorized, "{\"ok\":false,\"erro\":\"outra_coisa\"}", null);
            Assert.Equal(ApiOutcome.InvalidResponse, r.Outcome);
        }

        [Fact]
        public async Task Http429UsesRetryAfterHeader()
        {
            ApiResult<HeartbeatResponse> r = await HeartbeatWith(HttpStatusCode.TooManyRequests, "{\"ok\":false,\"erro\":\"muitas_requisicoes\"}",
                resp => resp.Headers.RetryAfter = new System.Net.Http.Headers.RetryConditionHeaderValue(TimeSpan.FromSeconds(42)));
            Assert.Equal(ApiOutcome.RateLimited, r.Outcome);
            Assert.Equal(TimeSpan.FromSeconds(42), r.RetryAfter);
        }

        [Fact]
        public async Task Http429FallsBackToBodyRetryAndClampsIt()
        {
            ApiResult<HeartbeatResponse> a = await HeartbeatWith(HttpStatusCode.TooManyRequests, "{\"ok\":false,\"erro\":\"x\",\"retry_apos_segundos\":30}", null);
            Assert.Equal(TimeSpan.FromSeconds(30), a.RetryAfter);

            ApiResult<HeartbeatResponse> huge = await HeartbeatWith(HttpStatusCode.TooManyRequests, "{\"ok\":false,\"erro\":\"x\",\"retry_apos_segundos\":99999999}", null);
            Assert.Equal(TimeSpan.FromHours(1), huge.RetryAfter);

            ApiResult<HeartbeatResponse> none = await HeartbeatWith(HttpStatusCode.TooManyRequests, "{\"ok\":false}", null);
            Assert.Equal(ApiOutcome.RateLimited, none.Outcome);
            Assert.Null(none.RetryAfter);
        }

        [Theory]
        [InlineData(HttpStatusCode.InternalServerError)]
        [InlineData(HttpStatusCode.BadGateway)]
        [InlineData(HttpStatusCode.ServiceUnavailable)]
        [InlineData(HttpStatusCode.GatewayTimeout)]
        public async Task Http5xxIsServerError(HttpStatusCode status)
        {
            ApiResult<HeartbeatResponse> r = await HeartbeatWith(status, "<html>erro</html>", null);
            Assert.Equal(ApiOutcome.ServerError, r.Outcome);
        }

        [Fact]
        public async Task BusinessErrors4xxAreRejectedWithTheServerCode()
        {
            RecordingHandler handler = new RecordingHandler();
            handler.Responder = r => Task.FromResult(RecordingHandler.Json(HttpStatusCode.BadRequest, "{\"ok\":false,\"erro\":\"codigo_invalido\",\"mensagem\":\"x\",\"request_id\":\"abc\"}"));
            ApiResult<PairVerifyResponse> result = await Create(handler).PairVerifyAsync("ABCD-2345", CancellationToken.None);
            Assert.Equal(ApiOutcome.Rejected, result.Outcome);
            Assert.Equal("codigo_invalido", result.ErrorCode);
            Assert.Equal(400, result.HttpStatus);
        }

        [Fact]
        public async Task Http404FromTheGatewayWithoutAFunctionErrorCodeIsInvalidResponse()
        {
            ApiResult<HeartbeatResponse> r = await HeartbeatWith(HttpStatusCode.NotFound, "{\"code\":\"NOT_FOUND\"}", null);
            Assert.False(r.IsOk);
            Assert.Equal(ApiOutcome.InvalidResponse, r.Outcome);
            Assert.Equal(404, r.HttpStatus);
        }

        [Fact]
        public async Task ConfirmWithoutAValidTokenIsInvalid()
        {
            PairConfirmRequest request = new PairConfirmRequest();
            request.Codigo = "ABCD-2345";
            request.IdentificadorInstalacao = Installation;

            foreach (string body in new[]
            {
                "{\"ok\":true}",
                "{\"ok\":true,\"token\":\"nao-e-token\"}",
                "{\"ok\":true,\"token\":123}",
            })
            {
                RecordingHandler handler = new RecordingHandler();
                handler.Responder = r => Task.FromResult(RecordingHandler.Json(HttpStatusCode.OK, body));
                ApiResult<PairConfirmResponse> result = await Create(handler).PairConfirmAsync(request, CancellationToken.None);
                Assert.Equal(ApiOutcome.InvalidResponse, result.Outcome);
            }
        }

        [Fact]
        public async Task RenewWithoutAValidTokenIsInvalid()
        {
            RecordingHandler handler = new RecordingHandler();
            handler.Responder = r => Task.FromResult(RecordingHandler.Json(HttpStatusCode.OK, "{\"ok\":true,\"token\":\"fpa_curto\"}"));
            ApiResult<RenewResponse> result = await Create(handler).RenewAsync(TestTokens.Make(2), Installation, CancellationToken.None);
            Assert.Equal(ApiOutcome.InvalidResponse, result.Outcome);
        }

        [Fact]
        public async Task VerifyWithoutCompanyNameIsInvalid()
        {
            RecordingHandler handler = new RecordingHandler();
            handler.Responder = r => Task.FromResult(RecordingHandler.Json(HttpStatusCode.OK, "{\"ok\":true}"));
            ApiResult<PairVerifyResponse> result = await Create(handler).PairVerifyAsync("ABCD-2345", CancellationToken.None);
            Assert.Equal(ApiOutcome.InvalidResponse, result.Outcome);
        }

        [Fact]
        public async Task NetworkFailureIsNetworkError()
        {
            RecordingHandler handler = new RecordingHandler();
            handler.Responder = r => throw new HttpRequestException("sem rede");
            ApiResult<HeartbeatResponse> r2 = await Create(handler).HeartbeatAsync(TestTokens.Make(2), Installation, "1.0.0", CancellationToken.None);
            Assert.Equal(ApiOutcome.NetworkError, r2.Outcome);
        }

        [Fact]
        public async Task HttpTimeoutIsTimeoutNotCancellation()
        {
            RecordingHandler handler = new RecordingHandler();
            handler.Responder = r => throw new TaskCanceledException("timeout do HttpClient");
            ApiResult<HeartbeatResponse> result = await Create(handler).HeartbeatAsync(TestTokens.Make(2), Installation, "1.0.0", CancellationToken.None);
            Assert.Equal(ApiOutcome.Timeout, result.Outcome);
        }

        [Fact]
        public async Task CallerCancellationPropagatesAsException()
        {
            using (CancellationTokenSource cts = new CancellationTokenSource())
            {
                RecordingHandler handler = new RecordingHandler();
                handler.Responder = async r =>
                {
                    cts.Cancel();
                    await Task.Delay(5000, cts.Token);
                    return RecordingHandler.Json(HttpStatusCode.OK, "{\"ok\":true}");
                };
                await Assert.ThrowsAnyAsync<OperationCanceledException>(
                    () => Create(handler).HeartbeatAsync(TestTokens.Make(2), Installation, "1.0.0", cts.Token));
            }
        }

        [Fact]
        public async Task OversizedDeclaredResponseIsRejectedWithoutBeingRead()
        {
            RecordingHandler handler = new RecordingHandler();
            handler.Responder = r =>
            {
                HttpResponseMessage response = new HttpResponseMessage(HttpStatusCode.OK);
                byte[] payload = Encoding.UTF8.GetBytes("{\"ok\":true,\"x\":\"" + new string('a', AgentConstants.MaxResponseBytes + 100) + "\"}");
                response.Content = new ByteArrayContent(payload);
                response.Content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("application/json");
                return Task.FromResult(response);
            };
            ApiResult<HeartbeatResponse> result = await Create(handler).HeartbeatAsync(TestTokens.Make(2), Installation, "1.0.0", CancellationToken.None);
            Assert.Equal(ApiOutcome.InvalidResponse, result.Outcome);
        }

        [Fact]
        public async Task HeartbeatResponseFlagsAreParsed()
        {
            ApiResult<HeartbeatResponse> r = await HeartbeatWith(HttpStatusCode.OK,
                "{\"ok\":true,\"estacao_nome\":\"Caixa 2\",\"heartbeat_segundos\":300,\"sincronizar_agora\":true,\"renovar_credencial\":true,\"usou_credencial_anterior\":true,\"hora_servidor\":\"2026-10-05T12:00:00Z\"}", null);
            Assert.True(r.IsOk);
            Assert.Equal("Caixa 2", r.Data!.EstacaoNome);
            Assert.Equal(300, r.Data.HeartbeatSegundos);
            Assert.True(r.Data.SincronizarAgora);
            Assert.True(r.Data.RenovarCredencial);
            Assert.True(r.Data.UsouCredencialAnterior);
        }

        [Fact]
        public async Task MissingOptionalHeartbeatFieldsUseSafeDefaults()
        {
            ApiResult<HeartbeatResponse> r = await HeartbeatWith(HttpStatusCode.OK, "{\"ok\":true}", null);
            Assert.True(r.IsOk);
            Assert.Null(r.Data!.HeartbeatSegundos);
            Assert.False(r.Data.SincronizarAgora);
            Assert.False(r.Data.RenovarCredencial);
        }

        [Fact]
        public void MeasureSyncBodyGrowsWithThePrinterList()
        {
            SyncRequest small = new SyncRequest();
            small.IdentificadorInstalacao = Installation;
            SyncRequest large = new SyncRequest();
            large.IdentificadorInstalacao = Installation;
            for (int i = 0; i < 50; i++) large.Impressoras.Add(Samples.Printer("Impressora " + i, PrinterConnection.Windows, PrinterStatus.Disponivel, null, null, "P" + i));
            Assert.True(EdgeApiClient.MeasureSyncBody(large) > EdgeApiClient.MeasureSyncBody(small) + 50 * 100);
            Assert.True(EdgeApiClient.MeasureSyncBody(large) < AgentConstants.MaxSyncBodyBytes);
        }
    }
}
