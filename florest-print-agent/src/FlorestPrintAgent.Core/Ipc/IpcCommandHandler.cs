using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using FlorestPrintAgent.Core.Agent;
using FlorestPrintAgent.Core.Printers;
using FlorestPrintAgent.Core.Security;
using Microsoft.Extensions.Logging;

namespace FlorestPrintAgent.Core.Ipc
{
    /// <summary>
    /// Valida e despacha os comandos do Tray. Tudo que chega pelo pipe é NÃO CONFIÁVEL (qualquer usuário local
    /// interativo pode falar com ele): comando em lista fixa, código normalizado, impressoras revalidadas.
    /// Não registra o corpo das mensagens nem o código de pareamento.
    /// </summary>
    public sealed class IpcCommandHandler
    {
        private readonly IAgentController _controller;
        private readonly ILogger _log;

        public IpcCommandHandler(IAgentController controller, ILogger log)
        {
            _controller = controller;
            _log = log;
        }

        /// <param name="caller">Identidade do chamador obtida do Windows (nunca da mensagem).</param>
        public async Task<IpcResponse> HandleAsync(IpcRequest request, CallerIdentity caller, CancellationToken ct)
        {
            if (request.Version != 1)
                return IpcResponse.Fail("versao_nao_suportada", "Versão do protocolo não suportada.");

            try
            {
                switch (request.Cmd)
                {
                    case IpcCommands.GetStatus:
                        return IpcResponse.Success(_controller.GetStatus());

                    case IpcCommands.GetPrinters:
                    {
                        PrintersDto dto = new PrintersDto();
                        dto.Impressoras = new List<PrinterInfo>(_controller.GetPrinters());
                        return IpcResponse.Success(dto);
                    }

                    case IpcCommands.PairVerify:
                    {
                        string code;
                        if (!PairingCode.TryNormalize(request.Codigo, out code))
                            return IpcResponse.Fail("codigo_invalido", "Código de pareamento inválido. Use o formato XXXX-XXXX.");
                        return Map(await _controller.VerifyPairingAsync(code, caller, ct).ConfigureAwait(false));
                    }

                    case IpcCommands.PairConfirm:
                    {
                        string code;
                        if (!PairingCode.TryNormalize(request.Codigo, out code))
                            return IpcResponse.Fail("codigo_invalido", "Código de pareamento inválido. Use o formato XXXX-XXXX.");
                        return Map(await _controller.ConfirmPairingAsync(code, caller, ct).ConfigureAwait(false));
                    }

                    case IpcCommands.ScanPrinters:
                        return Map(await _controller.ScanPrintersAsync(ct).ConfigureAwait(false));

                    case IpcCommands.SubmitUserPrinters:
                    {
                        // a sessão vem do WINDOWS (SID + sessão do cliente do pipe); nada escrito pelo cliente decide de quem é a lista
                        string session = caller.Key;
                        if (request.Impressoras == null)
                            return IpcResponse.Fail("dados_invalidos", "Lista de impressoras ausente.");
                        List<PrinterInfo> clean = PrinterSanitizer.SanitizeList(request.Impressoras, AgentConstants.MaxPrintersPerSync);
                        return Map(_controller.SubmitUserPrinters(session, clean));
                    }

                    case IpcCommands.Unlink:
                        return Map(await _controller.UnlinkAsync(request.Forcar, caller, ct).ConfigureAwait(false));

                    default:
                        return IpcResponse.Fail("comando_invalido", "Comando desconhecido.");
                }
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception ex)
            {
                _log.LogError("Erro ao tratar comando do Tray ({Tipo}).", ex.GetType().Name);
                return IpcResponse.Fail("erro_interno", "Erro interno no serviço.");
            }
        }

        private static IpcResponse Map(ControllerResult r)
        {
            if (r.Ok) return IpcResponse.Success(r.Data, r.Mensagem);
            return IpcResponse.Fail(r.Erro ?? "erro", r.Mensagem ?? "Operação não concluída.");
        }
    }
}
