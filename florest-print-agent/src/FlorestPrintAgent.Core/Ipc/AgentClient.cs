using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using FlorestPrintAgent.Core.Agent;
using FlorestPrintAgent.Core.Printers;

namespace FlorestPrintAgent.Core.Ipc
{
    /// <summary>Resultado de um comando enviado ao Service (ok, erro, mensagem e dados opcionais).</summary>
    public sealed class ClientResult
    {
        private readonly IpcResponse _raw;

        public ClientResult(IpcResponse raw)
        {
            _raw = raw;
        }

        public bool Ok
        {
            get { return _raw.Ok; }
        }

        public string? Erro
        {
            get { return _raw.Erro; }
        }

        public string? Mensagem
        {
            get { return _raw.Mensagem; }
        }

        public T? Data<T>() where T : class
        {
            return _raw.ReadData<T>();
        }
    }

    /// <summary>
    /// Interface tipada do Tray para o Service. Só envia comandos, o código de pareamento e as impressoras da sessão
    /// do usuário. Não conhece nem recebe token.
    /// </summary>
    public sealed class AgentClient
    {
        private readonly IpcClient _ipc;

        public AgentClient(IpcClient ipc)
        {
            _ipc = ipc;
        }

        public async Task<ClientResult> GetStatusAsync(CancellationToken ct)
        {
            return await Send(IpcCommands.GetStatus, null, null, false, ct).ConfigureAwait(false);
        }

        public async Task<ClientResult> GetPrintersAsync(CancellationToken ct)
        {
            return await Send(IpcCommands.GetPrinters, null, null, false, ct).ConfigureAwait(false);
        }

        public async Task<ClientResult> PairVerifyAsync(string code, CancellationToken ct)
        {
            return await Send(IpcCommands.PairVerify, code, null, false, ct).ConfigureAwait(false);
        }

        public async Task<ClientResult> PairConfirmAsync(string code, CancellationToken ct)
        {
            return await Send(IpcCommands.PairConfirm, code, null, false, ct).ConfigureAwait(false);
        }

        public async Task<ClientResult> ScanPrintersAsync(CancellationToken ct)
        {
            return await Send(IpcCommands.ScanPrinters, null, null, false, ct).ConfigureAwait(false);
        }

        public async Task<ClientResult> SubmitUserPrintersAsync(IReadOnlyList<PrinterInfo> printers, CancellationToken ct)
        {
            return await Send(IpcCommands.SubmitUserPrinters, null, new List<PrinterInfo>(printers), false, ct).ConfigureAwait(false);
        }

        public async Task<ClientResult> UnlinkAsync(bool force, CancellationToken ct)
        {
            return await Send(IpcCommands.Unlink, null, null, force, ct).ConfigureAwait(false);
        }

        private async Task<ClientResult> Send(string cmd, string? code, List<PrinterInfo>? printers, bool force, CancellationToken ct)
        {
            IpcRequest request = new IpcRequest();
            request.Cmd = cmd;
            request.Codigo = code;
            request.Impressoras = printers;
            request.Forcar = force;
            IpcResponse response = await _ipc.SendAsync(request, ct).ConfigureAwait(false);
            return new ClientResult(response);
        }
    }
}
