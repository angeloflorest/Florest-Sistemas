using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using FlorestPrintAgent.Core.Agent;
using FlorestPrintAgent.Core.Ipc;
using FlorestPrintAgent.Core.Printers;
using Microsoft.Extensions.Logging;

namespace FlorestPrintAgent.Tray
{
    /// <summary>Foto do que o Tray sabe do serviço neste momento.</summary>
    internal sealed class AgentSnapshot
    {
        /// <summary>Null quando o serviço não pôde ser consultado.</summary>
        public AgentStatusDto? Status { get; set; }

        /// <summary>Motivo de não ter falado com o serviço (quando Status é null).</summary>
        public string? ServiceError { get; set; }

        public List<PrinterInfo> Printers { get; set; } = new List<PrinterInfo>();

        public string Kind
        {
            get { return Status != null ? Status.Estado : AgentStatusKind.Erro; }
        }
    }

    internal sealed class OperationOutcome
    {
        public bool Ok { get; set; }
        public string? Erro { get; set; }
        public string Message { get; set; } = string.Empty;
        public PairingPreviewDto? Preview { get; set; }

        public static OperationOutcome Success(string message)
        {
            OperationOutcome o = new OperationOutcome();
            o.Ok = true;
            o.Message = message;
            return o;
        }

        public static OperationOutcome Fail(string? erro, string message)
        {
            OperationOutcome o = new OperationOutcome();
            o.Ok = false;
            o.Erro = erro;
            o.Message = message;
            return o;
        }
    }

    internal enum UserSubmitResult
    {
        Sent,
        DiscoveryFailed,
        ServiceError,
    }

    /// <summary>
    /// Lógica do Tray sem elementos de tela: fala com o Service (Named Pipe), detecta as impressoras do usuário logado
    /// e as entrega ao Service. Não conhece o token da credencial (ele nunca sai do Service).
    /// Os eventos são disparados na thread de interface (os "await" retomam nela).
    /// </summary>
    internal sealed class TrayController
    {
        private readonly AgentClient _client;
        private readonly IPrinterDiscovery _discovery;
        private readonly ILogger _log;
        private readonly SemaphoreSlim _scanGate = new SemaphoreSlim(1, 1);

        public AgentSnapshot Last { get; private set; } = new AgentSnapshot();

        public event EventHandler? SnapshotChanged;

        public TrayController(AgentClient client, IPrinterDiscovery discovery, ILogger log)
        {
            _client = client;
            _discovery = discovery;
            _log = log;
            Last.ServiceError = "Consultando o serviço...";
        }

        public async Task RefreshAsync(CancellationToken ct)
        {
            AgentSnapshot snapshot = new AgentSnapshot();
            snapshot.Printers = Last.Printers;

            ClientResult status = await _client.GetStatusAsync(ct);
            if (status.Ok)
            {
                snapshot.Status = status.Data<AgentStatusDto>();
                if (snapshot.Status == null) snapshot.ServiceError = "Resposta inválida do serviço.";
            }
            else
            {
                snapshot.ServiceError = status.Mensagem ?? "O serviço Florest Print Agent não está respondendo.";
            }

            if (snapshot.Status != null)
            {
                ClientResult printers = await _client.GetPrintersAsync(ct);
                if (printers.Ok)
                {
                    PrintersDto? dto = printers.Data<PrintersDto>();
                    if (dto != null) snapshot.Printers = dto.Impressoras;
                }
            }

            Last = snapshot;
            EventHandler? handler = SnapshotChanged;
            if (handler != null) handler(this, EventArgs.Empty);
        }

        /// <summary>
        /// Detecta as impressoras do usuário logado e entrega ao Service. Uma falha técnica de detecção NUNCA envia lista
        /// vazia; uma lista vazia só é enviada quando a varredura terminou com sucesso e não achou nada.
        /// </summary>
        public async Task<UserSubmitResult> SubmitUserPrintersAsync(CancellationToken ct)
        {
            DiscoveryResult discovery = await Task.Run(() => _discovery.Discover(), ct);
            if (!discovery.Success)
            {
                _log.LogWarning("Falha ao detectar as impressoras do usuário: {Motivo}", discovery.Error ?? "desconhecido");
                return UserSubmitResult.DiscoveryFailed;
            }

            ClientResult result = await _client.SubmitUserPrintersAsync(discovery.Printers, ct);
            if (!result.Ok)
            {
                _log.LogWarning("O serviço não aceitou a lista de impressoras do usuário ({Erro}).", result.Erro ?? "-");
                return UserSubmitResult.ServiceError;
            }
            return UserSubmitResult.Sent;
        }

        /// <summary>"Buscar impressoras": entrega as impressoras do usuário e pede ao Service para detectar e sincronizar.</summary>
        public async Task<OperationOutcome> ScanAsync(CancellationToken ct)
        {
            if (!await _scanGate.WaitAsync(0, ct))
                return OperationOutcome.Fail("ocupado", "Já existe uma busca em andamento.");
            try
            {
                UserSubmitResult submit = await SubmitUserPrintersAsync(ct);

                ClientResult scan = await _client.ScanPrintersAsync(ct);
                await RefreshAsync(ct);

                if (!scan.Ok)
                    return OperationOutcome.Fail(scan.Erro, scan.Mensagem ?? "Não foi possível buscar as impressoras.");

                ScanResultDto? dto = scan.Data<ScanResultDto>();
                int count = dto != null ? dto.Impressoras.Count : 0;
                string message = Plural(count, "impressora encontrada", "impressoras encontradas");
                if (dto != null && dto.Sincronizado)
                {
                    message += ". Lista enviada ao Florest ERP.";
                }
                else
                {
                    message += ".";
                    if (!string.IsNullOrEmpty(scan.Mensagem)) message += " " + scan.Mensagem;
                }
                if (submit == UserSubmitResult.DiscoveryFailed)
                {
                    message += " Não foi possível ler as impressoras do seu usuário agora; foram usadas as do computador.";
                }
                return OperationOutcome.Success(message);
            }
            finally
            {
                _scanGate.Release();
            }
        }

        public async Task<OperationOutcome> VerifyPairingAsync(string code, CancellationToken ct)
        {
            ClientResult r = await _client.PairVerifyAsync(code, ct);
            if (!r.Ok) return OperationOutcome.Fail(r.Erro, r.Mensagem ?? "Não foi possível verificar o código.");

            PairingPreviewDto? preview = r.Data<PairingPreviewDto>();
            if (preview == null || string.IsNullOrWhiteSpace(preview.Empresa))
                return OperationOutcome.Fail("resposta_invalida", "Resposta inválida do serviço.");

            OperationOutcome ok = OperationOutcome.Success("Código válido.");
            ok.Preview = preview;
            return ok;
        }

        public async Task<OperationOutcome> ConfirmPairingAsync(string code, CancellationToken ct)
        {
            ClientResult r = await _client.PairConfirmAsync(code, ct);
            await RefreshAsync(ct);
            if (!r.Ok) return OperationOutcome.Fail(r.Erro, r.Mensagem ?? "Não foi possível conectar.");
            return OperationOutcome.Success("Computador conectado ao Florest ERP.");
        }

        public async Task<OperationOutcome> UnlinkAsync(bool force, CancellationToken ct)
        {
            ClientResult r = await _client.UnlinkAsync(force, ct);
            await RefreshAsync(ct);
            if (!r.Ok) return OperationOutcome.Fail(r.Erro, r.Mensagem ?? "Não foi possível desvincular.");
            return OperationOutcome.Success(r.Mensagem ?? "Computador desvinculado.");
        }

        private static string Plural(int count, string singular, string plural)
        {
            return count.ToString(CultureInfo.InvariantCulture) + " " + (count == 1 ? singular : plural);
        }
    }
}
