using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using FlorestPrintAgent.Core.Printers;
using FlorestPrintAgent.Core.Security;

namespace FlorestPrintAgent.Core.Api
{
    /// <summary>
    /// Cliente HTTPS da Edge Function. Usa UM HttpClient de vida longa (injetado). Regras:
    ///  - somente HTTPS (BaseAddress validada) e sem desabilitar validação TLS;
    ///  - Authorization: Bearer só nas rotas autenticadas; nunca envia apikey, service_role nem JWT de usuário;
    ///  - corpo e resposta com limite de tamanho; resposta validada antes de ser usada;
    ///  - nunca registra token, corpo ou cabeçalhos (este tipo nem tem logger).
    /// </summary>
    public sealed class EdgeApiClient : IEdgeApi
    {
        private static readonly HashSet<string> CredentialErrors = new HashSet<string>(StringComparer.Ordinal)
        {
            "credencial_invalida", "agente_revogado", "empresa_inativa", "estacao_inativa", "instalacao_divergente",
        };

        private readonly HttpClient _http;

        public EdgeApiClient(HttpClient http)
        {
            if (http == null) throw new ArgumentNullException(nameof(http));
            if (http.BaseAddress == null || !string.Equals(http.BaseAddress.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
                throw new ArgumentException("O endereço do servidor precisa ser HTTPS.", nameof(http));
            if (!http.BaseAddress.AbsolutePath.EndsWith("/", StringComparison.Ordinal))
                throw new ArgumentException("O endereço base precisa terminar com '/'.", nameof(http));
            _http = http;
        }

        public Task<ApiResult<PairVerifyResponse>> PairVerifyAsync(string codigo, CancellationToken ct)
        {
            PairVerifyBody body = new PairVerifyBody();
            body.Codigo = codigo;
            return SendAsync<PairVerifyResponse>("pair/verify", Serialize(body), null, ParseVerify, ct);
        }

        public Task<ApiResult<PairConfirmResponse>> PairConfirmAsync(PairConfirmRequest request, CancellationToken ct)
        {
            PairConfirmBody body = new PairConfirmBody();
            body.Codigo = request.Codigo;
            body.IdentificadorInstalacao = request.IdentificadorInstalacao;
            body.NomeComputador = request.NomeComputador;
            body.SistemaOperacional = request.SistemaOperacional;
            body.VersaoAgente = request.VersaoAgente;
            return SendAsync<PairConfirmResponse>("pair/confirm", Serialize(body), null, ParseConfirm, ct);
        }

        public Task<ApiResult<HeartbeatResponse>> HeartbeatAsync(AgentToken token, string installationId, string agentVersion, CancellationToken ct)
        {
            HeartbeatBody body = new HeartbeatBody();
            body.IdentificadorInstalacao = installationId;
            body.VersaoAgente = agentVersion;
            return SendAsync<HeartbeatResponse>("agent/heartbeat", Serialize(body), token, ParseHeartbeat, ct);
        }

        public Task<ApiResult<SyncResponse>> SyncAsync(AgentToken token, SyncRequest request, CancellationToken ct)
        {
            SyncBody body = new SyncBody();
            body.IdentificadorInstalacao = request.IdentificadorInstalacao;
            body.Impressoras = request.Impressoras;
            body.VersaoAgente = request.VersaoAgente;
            body.NomeComputador = request.NomeComputador;
            body.SistemaOperacional = request.SistemaOperacional;
            byte[] bytes = Serialize(body);
            if (bytes.Length > AgentConstants.MaxSyncBodyBytes || request.Impressoras.Count > AgentConstants.MaxPrintersPerSync)
            {
                // nunca enviamos além do limite do contrato
                return Task.FromResult(ApiResult<SyncResponse>.Failure(ApiOutcome.Rejected, 0, "limite_excedido", null));
            }
            return SendAsync<SyncResponse>("agent/sync", bytes, token, ParseSync, ct);
        }

        public Task<ApiResult<RenewResponse>> RenewAsync(AgentToken token, string installationId, CancellationToken ct)
        {
            InstallationBody body = new InstallationBody();
            body.IdentificadorInstalacao = installationId;
            return SendAsync<RenewResponse>("agent/renew", Serialize(body), token, ParseRenew, ct);
        }

        public Task<ApiResult<EmptyResponse>> UnlinkAsync(AgentToken token, string installationId, CancellationToken ct)
        {
            InstallationBody body = new InstallationBody();
            body.IdentificadorInstalacao = installationId;
            return SendAsync<EmptyResponse>("agent/unlink", Serialize(body), token, ParseEmpty, ct);
        }

        public Task<ApiResult<ClaimJobsResponse>> ClaimJobsAsync(AgentToken token, string installationId, int limit, int waitSeconds, CancellationToken ct)
        {
            ClaimJobsBody body = new ClaimJobsBody();
            body.IdentificadorInstalacao = installationId;
            body.Limite = limit < 1 ? 1 : (limit > 5 ? 5 : limit);
            body.EsperaSegundos = waitSeconds < 0 ? 0 : (waitSeconds > 20 ? 20 : waitSeconds);
            return SendAsync<ClaimJobsResponse>("agent/jobs/claim", Serialize(body), token, ParseClaim, ct);
        }

        public Task<ApiResult<JobAckResponse>> CompleteJobAsync(AgentToken token, string installationId, string jobId, CancellationToken ct)
        {
            JobCompleteBody body = new JobCompleteBody();
            body.IdentificadorInstalacao = installationId;
            body.JobId = jobId;
            return SendAsync<JobAckResponse>("agent/jobs/complete", Serialize(body), token, ParseJobAck, ct);
        }

        public Task<ApiResult<JobAckResponse>> FailJobAsync(AgentToken token, string installationId, string jobId, string errorCode, string errorMessage, bool definitive, CancellationToken ct)
        {
            JobFailBody body = new JobFailBody();
            body.IdentificadorInstalacao = installationId;
            body.JobId = jobId;
            body.ErroCodigo = PrinterClassifier.CleanText(errorCode, 40);
            body.ErroMensagem = PrinterClassifier.CleanText(errorMessage, 300);
            body.Definitivo = definitive;
            return SendAsync<JobAckResponse>("agent/jobs/fail", Serialize(body), token, ParseJobAck, ct);
        }

        // ------------------------------------------------------------------------------------------------------
        // Envio e interpretação da resposta
        // ------------------------------------------------------------------------------------------------------

        private async Task<ApiResult<T>> SendAsync<T>(
            string route,
            byte[] body,
            AgentToken? token,
            Func<JsonElement, T?> parse,
            CancellationToken ct) where T : class
        {
            using (HttpRequestMessage request = new HttpRequestMessage(HttpMethod.Post, route))
            {
                request.Headers.UserAgent.ParseAdd(AgentConstants.UserAgent);
                request.Headers.Accept.ParseAdd("application/json");
                if (token != null)
                {
                    request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.RevealForAuthorization());
                }
                ByteArrayContent content = new ByteArrayContent(body);
                content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
                request.Content = content;

                HttpResponseMessage response;
                try
                {
                    response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (ct.IsCancellationRequested)
                {
                    throw;
                }
                catch (OperationCanceledException)
                {
                    return ApiResult<T>.Failure(ApiOutcome.Timeout, 0, null, null);
                }
                catch (HttpRequestException)
                {
                    return ApiResult<T>.Failure(ApiOutcome.NetworkError, 0, null, null);
                }

                using (response)
                {
                    int status = (int)response.StatusCode;

                    long? declared = response.Content.Headers.ContentLength;
                    if (declared.HasValue && declared.Value > AgentConstants.MaxResponseBytes)
                        return ApiResult<T>.Failure(ApiOutcome.InvalidResponse, status, null, null);

                    byte[] bytes;
                    try
                    {
                        // O HttpClient.Timeout deixa de valer depois que os cabeçalhos chegam: o corpo tem prazo próprio,
                        // senão uma conexão que "pinga" bytes seguraria o portão do coordenador para sempre.
                        using (CancellationTokenSource bodyCts = CancellationTokenSource.CreateLinkedTokenSource(ct))
                        {
                            bodyCts.CancelAfter(AgentConstants.HttpTimeout);
                            bytes = await ReadLimitedAsync(response.Content, bodyCts.Token).ConfigureAwait(false);
                        }
                    }
                    catch (OperationCanceledException) when (ct.IsCancellationRequested)
                    {
                        throw;
                    }
                    catch (OperationCanceledException)
                    {
                        return ApiResult<T>.Failure(ApiOutcome.Timeout, status, null, null);
                    }
                    catch (HttpRequestException)
                    {
                        return ApiResult<T>.Failure(ApiOutcome.NetworkError, status, null, null);
                    }
                    catch (IOException)
                    {
                        return ApiResult<T>.Failure(ApiOutcome.NetworkError, status, null, null);
                    }
                    catch (InvalidDataException)
                    {
                        return ApiResult<T>.Failure(ApiOutcome.InvalidResponse, status, null, null);
                    }

                    TimeSpan? retryHeader = ReadRetryAfter(response);
                    return Interpret(status, bytes, retryHeader, parse);
                }
            }
        }

        internal static ApiResult<T> Interpret<T>(int status, byte[] bytes, TimeSpan? retryHeader, Func<JsonElement, T?> parse) where T : class
        {
            JsonDocument? doc = null;
            try
            {
                try
                {
                    doc = JsonDocument.Parse(bytes);
                }
                catch (JsonException)
                {
                    doc = null;
                }

                JsonElement root = default(JsonElement);
                bool hasObject = doc != null && doc.RootElement.ValueKind == JsonValueKind.Object;
                if (hasObject && doc != null) root = doc.RootElement;
                string? erro = hasObject ? GetString(root, "erro", 64) : null;

                if (status == 200)
                {
                    if (!hasObject || !GetBool(root, "ok")) return ApiResult<T>.Failure(ApiOutcome.InvalidResponse, status, null, null);
                    T? data;
                    try
                    {
                        data = parse(root);
                    }
                    catch (Exception ex) when (ex is JsonException || ex is InvalidOperationException || ex is FormatException)
                    {
                        data = null;
                    }
                    if (data == null) return ApiResult<T>.Failure(ApiOutcome.InvalidResponse, status, null, null);
                    return ApiResult<T>.Success(data, status);
                }

                if (status == 401)
                {
                    // 401 da NOSSA função traz erro de credencial conhecido. Um 401 do gateway (ex.: "Invalid JWT" quando
                    // o Verify JWT está ligado por engano) NÃO é uma credencial recusada: não deve marcar o vínculo como inválido.
                    if (erro != null && CredentialErrors.Contains(erro))
                        return ApiResult<T>.Failure(ApiOutcome.Unauthorized, status, erro, null);
                    return ApiResult<T>.Failure(ApiOutcome.InvalidResponse, status, null, null);
                }

                if (status == 429)
                {
                    TimeSpan? retry = retryHeader;
                    if (!retry.HasValue && hasObject)
                    {
                        int? secs = GetInt(root, "retry_apos_segundos");
                        if (secs.HasValue && secs.Value > 0) retry = TimeSpan.FromSeconds(secs.Value);
                    }
                    if (retry.HasValue)
                    {
                        if (retry.Value < TimeSpan.FromSeconds(1)) retry = TimeSpan.FromSeconds(1);
                        if (retry.Value > TimeSpan.FromHours(1)) retry = TimeSpan.FromHours(1);
                    }
                    return ApiResult<T>.Failure(ApiOutcome.RateLimited, status, erro, retry);
                }

                if (status >= 500) return ApiResult<T>.Failure(ApiOutcome.ServerError, status, erro, null);
                if (status >= 400)
                {
                    // 4xx da NOSSA função traz um código "erro". Sem ele (ex.: 404 do gateway com a função não publicada,
                    // 403 de proxy) não é uma recusa de negócio: é resposta inválida.
                    if (erro != null) return ApiResult<T>.Failure(ApiOutcome.Rejected, status, erro, null);
                    return ApiResult<T>.Failure(ApiOutcome.InvalidResponse, status, null, null);
                }
                return ApiResult<T>.Failure(ApiOutcome.InvalidResponse, status, null, null);
            }
            finally
            {
                if (doc != null) doc.Dispose();
            }
        }

        private static TimeSpan? ReadRetryAfter(HttpResponseMessage response)
        {
            RetryConditionHeaderValue? ra = response.Headers.RetryAfter;
            if (ra == null) return null;
            if (ra.Delta.HasValue) return ra.Delta.Value;
            if (ra.Date.HasValue)
            {
                TimeSpan d = ra.Date.Value - DateTimeOffset.UtcNow;
                return d > TimeSpan.Zero ? d : TimeSpan.FromSeconds(1);
            }
            return null;
        }

        private static async Task<byte[]> ReadLimitedAsync(HttpContent content, CancellationToken ct)
        {
            using (Stream stream = await content.ReadAsStreamAsync(ct).ConfigureAwait(false))
            using (MemoryStream ms = new MemoryStream())
            {
                byte[] buffer = new byte[8192];
                int total = 0;
                while (true)
                {
                    int read = await stream.ReadAsync(buffer, 0, buffer.Length, ct).ConfigureAwait(false);
                    if (read == 0) break;
                    total += read;
                    if (total > AgentConstants.MaxResponseBytes) throw new InvalidDataException("Resposta maior que o limite.");
                    ms.Write(buffer, 0, read);
                }
                return ms.ToArray();
            }
        }

        private static byte[] Serialize<TBody>(TBody body)
        {
            return JsonSerializer.SerializeToUtf8Bytes(body, AgentJson.WireOptions);
        }

        /// <summary>Tamanho, em bytes, do corpo JSON que seria enviado para a sincronização (usado para respeitar o limite).</summary>
        internal static int MeasureSyncBody(SyncRequest request)
        {
            SyncBody body = new SyncBody();
            body.IdentificadorInstalacao = request.IdentificadorInstalacao;
            body.Impressoras = request.Impressoras;
            body.VersaoAgente = request.VersaoAgente;
            body.NomeComputador = request.NomeComputador;
            body.SistemaOperacional = request.SistemaOperacional;
            return Serialize(body).Length;
        }

        // ------------------------------------------------------------------------------------------------------
        // Interpretadores de cada rota (validam tipos; campos opcionais ausentes viram padrão)
        // ------------------------------------------------------------------------------------------------------

        private static PairVerifyResponse? ParseVerify(JsonElement root)
        {
            string? empresa = GetString(root, "empresa_nome", 200);
            if (string.IsNullOrEmpty(empresa)) return null;
            PairVerifyResponse r = new PairVerifyResponse();
            r.EmpresaNome = empresa;
            r.EstacaoNome = GetString(root, "estacao_nome", 200);
            r.Reinstalacao = GetBool(root, "reinstalacao");
            r.ExpiraEm = GetString(root, "expira_em", 64);
            return r;
        }

        private static PairConfirmResponse? ParseConfirm(JsonElement root)
        {
            AgentToken? token;
            if (!TokenParser.TryParse(GetString(root, "token", 128), out token) || token == null) return null;

            PairConfirmResponse r = new PairConfirmResponse();
            r.Token = token;
            r.EmpresaNome = GetString(root, "empresa_nome", 200);
            r.EstacaoNome = GetString(root, "estacao_nome", 200);
            r.Reinstalacao = GetBool(root, "reinstalacao");
            r.HeartbeatSegundos = GetInt(root, "heartbeat_segundos");
            r.SincronizarAgora = GetBool(root, "sincronizar_agora");
            JsonElement limites;
            if (root.TryGetProperty("limites", out limites) && limites.ValueKind == JsonValueKind.Object)
            {
                r.LimiteImpressoras = GetInt(limites, "impressoras_sync_max");
                r.LimiteBytes = GetInt(limites, "payload_max_bytes");
            }
            return r;
        }

        private static HeartbeatResponse? ParseHeartbeat(JsonElement root)
        {
            HeartbeatResponse r = new HeartbeatResponse();
            r.EstacaoNome = GetString(root, "estacao_nome", 200);
            r.HeartbeatSegundos = GetInt(root, "heartbeat_segundos");
            r.SincronizarAgora = GetBool(root, "sincronizar_agora");
            r.RenovarCredencial = GetBool(root, "renovar_credencial");
            r.UsouCredencialAnterior = GetBool(root, "usou_credencial_anterior");
            r.HoraServidor = GetString(root, "hora_servidor", 64);
            return r;
        }

        private static SyncResponse? ParseSync(JsonElement root)
        {
            SyncResponse r = new SyncResponse();
            r.Recebidas = GetInt(root, "recebidas") ?? 0;
            r.Validas = GetInt(root, "validas") ?? 0;
            r.Rejeitadas = GetInt(root, "rejeitadas") ?? 0;
            r.Novas = GetInt(root, "novas") ?? 0;
            r.Alteradas = GetInt(root, "alteradas") ?? 0;
            r.Desativadas = GetInt(root, "desativadas") ?? 0;
            r.Ativas = GetInt(root, "ativas") ?? 0;
            return r;
        }

        private static RenewResponse? ParseRenew(JsonElement root)
        {
            AgentToken? token;
            if (!TokenParser.TryParse(GetString(root, "token", 128), out token) || token == null) return null;
            RenewResponse r = new RenewResponse();
            r.Token = token;
            r.GracaSegundos = GetInt(root, "graca_segundos");
            return r;
        }

        private static EmptyResponse? ParseEmpty(JsonElement root)
        {
            return new EmptyResponse();
        }

        private static JobAckResponse? ParseJobAck(JsonElement root)
        {
            JobAckResponse r = new JobAckResponse();
            r.Status = GetString(root, "status", 32);
            r.JaConfirmado = GetBool(root, "ja_confirmado");
            r.Tentativas = GetInt(root, "tentativas");
            r.MaxTentativas = GetInt(root, "max_tentativas");
            return r;
        }

        /// <summary>
        /// Interpreta a lista de jobs. Um job fora do contrato (id que não é GUID, payload que não é objeto, impressora sem nome
        /// nem identificador) é DESCARTADO: a reserva dele vence no servidor e ele volta para a fila. Nada de empresa/estação
        /// é lido aqui (a resposta nem deveria trazer).
        /// </summary>
        internal static ClaimJobsResponse? ParseClaim(JsonElement root)
        {
            JsonElement jobs;
            if (!root.TryGetProperty("jobs", out jobs) || jobs.ValueKind != JsonValueKind.Array) return null;

            ClaimJobsResponse r = new ClaimJobsResponse();
            int count = 0;
            foreach (JsonElement item in jobs.EnumerateArray())
            {
                count++;
                if (count > 10) break; // o contrato é no máximo 5; proteção extra
                PrintJob? job = ParseJob(item);
                if (job != null) r.Jobs.Add(job);
            }
            return r;
        }

        private static PrintJob? ParseJob(JsonElement item)
        {
            if (item.ValueKind != JsonValueKind.Object) return null;

            string? id = GetString(item, "id", 64);
            Guid parsed;
            if (string.IsNullOrEmpty(id) || !Guid.TryParse(id, out parsed)) return null;

            JsonElement payload;
            if (!item.TryGetProperty("payload", out payload) || payload.ValueKind != JsonValueKind.Object) return null;

            JsonElement printer;
            if (!item.TryGetProperty("impressora", out printer) || printer.ValueKind != JsonValueKind.Object) return null;
            JobPrinter jp = new JobPrinter();
            jp.Id = GetString(printer, "id", 64);
            jp.Nome = GetString(printer, "nome", AgentConstants.MaxPrinterNameLength) ?? string.Empty;
            jp.Identificador = GetString(printer, "identificador", AgentConstants.MaxIdentifierLength) ?? string.Empty;
            jp.Conexao = GetString(printer, "conexao", 30);
            jp.PortaWindows = GetString(printer, "porta_windows", AgentConstants.MaxPortNameLength);
            if (jp.Nome.Length == 0 && jp.Identificador.Length == 0) return null;

            PrintJob job = new PrintJob();
            job.Id = parsed.ToString("D");
            job.Destino = GetString(item, "destino", 32) ?? string.Empty;
            job.Tipo = GetString(item, "tipo", 32) ?? string.Empty;
            job.Titulo = GetString(item, "titulo", 120) ?? string.Empty;
            job.Tentativa = GetInt(item, "tentativa") ?? 1;
            job.MaxTentativas = GetInt(item, "max_tentativas") ?? 1;
            job.ReservaSegundos = GetInt(item, "reserva_segundos") ?? 120;
            job.Payload = payload.Clone(); // independe do JsonDocument (que é descartado ao fim de Interpret)
            job.Impressora = jp;
            return job;
        }

        // ------------------------------------------------------------------------------------------------------
        // Leitura defensiva de JSON
        // ------------------------------------------------------------------------------------------------------

        private static string? GetString(JsonElement obj, string name, int maxLength)
        {
            JsonElement v;
            if (obj.ValueKind != JsonValueKind.Object || !obj.TryGetProperty(name, out v) || v.ValueKind != JsonValueKind.String) return null;
            string? s = v.GetString();
            if (s == null) return null;
            return PrinterClassifier.CleanText(s, maxLength);
        }

        private static bool GetBool(JsonElement obj, string name)
        {
            JsonElement v;
            return obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(name, out v) && v.ValueKind == JsonValueKind.True;
        }

        private static int? GetInt(JsonElement obj, string name)
        {
            JsonElement v;
            if (obj.ValueKind != JsonValueKind.Object || !obj.TryGetProperty(name, out v) || v.ValueKind != JsonValueKind.Number) return null;
            int n;
            return v.TryGetInt32(out n) ? n : (int?)null;
        }
    }
}
