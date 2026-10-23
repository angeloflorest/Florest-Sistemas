using System;
using System.IO;
using System.IO.Pipes;
using System.Security.Principal;
using System.Threading;
using System.Threading.Tasks;

namespace FlorestPrintAgent.Core.Ipc
{
    /// <summary>
    /// Cliente do Named Pipe local (usado pelo Tray). Uma conexão por comando. Não envia credenciais.
    /// TokenImpersonationLevel.Identification: o servidor não pode se passar pelo usuário.
    /// </summary>
    public sealed class IpcClient
    {
        private readonly string _pipeName;

        public IpcClient()
            : this(AgentConstants.PipeName)
        {
        }

        public IpcClient(string pipeName)
        {
            _pipeName = pipeName;
        }

        public async Task<IpcResponse> SendAsync(IpcRequest request, CancellationToken ct)
        {
            try
            {
                byte[] payload = IpcSerializer.Serialize(request);
                int max = request.Cmd == IpcCommands.SubmitUserPrinters ? AgentConstants.MaxIpcSubmitBytes : AgentConstants.MaxIpcRequestBytes;

                using (CancellationTokenSource timeout = CancellationTokenSource.CreateLinkedTokenSource(ct))
                {
                    timeout.CancelAfter(AgentConstants.IpcClientResponseTimeout);
                    using (NamedPipeClientStream pipe = new NamedPipeClientStream(
                        ".", _pipeName, PipeDirection.InOut, PipeOptions.Asynchronous, TokenImpersonationLevel.Identification))
                    {
                        await pipe.ConnectAsync((int)AgentConstants.IpcClientConnectTimeout.TotalMilliseconds, timeout.Token).ConfigureAwait(false);
                        await IpcFraming.WriteFrameAsync(pipe, payload, max, timeout.Token).ConfigureAwait(false);
                        byte[] response = await IpcFraming.ReadFrameAsync(pipe, AgentConstants.MaxIpcResponseBytes, timeout.Token).ConfigureAwait(false);
                        return IpcSerializer.Deserialize<IpcResponse>(response);
                    }
                }
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                throw;
            }
            catch (TimeoutException)
            {
                return IpcResponse.Fail("servico_indisponivel", "O serviço Florest Print Agent não está respondendo. Verifique se ele está em execução.");
            }
            catch (OperationCanceledException)
            {
                return IpcResponse.Fail("tempo_esgotado", "O serviço demorou demais para responder.");
            }
            catch (UnauthorizedAccessException)
            {
                return IpcResponse.Fail("acesso_negado", "Sem permissão para falar com o serviço.");
            }
            catch (IOException)
            {
                return IpcResponse.Fail("servico_indisponivel", "O serviço Florest Print Agent não está em execução.");
            }
            catch (IpcProtocolException)
            {
                return IpcResponse.Fail("resposta_invalida", "Resposta inválida do serviço.");
            }
        }
    }
}
