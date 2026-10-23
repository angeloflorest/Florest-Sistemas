using System;
using System.IO;
using System.IO.Pipes;
using System.Runtime.Versioning;
using System.Threading;
using System.Threading.Tasks;
using FlorestPrintAgent.Core;
using FlorestPrintAgent.Core.Agent;
using FlorestPrintAgent.Core.Ipc;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace FlorestPrintAgent.Service
{
    /// <summary>
    /// Servidor do Named Pipe local (sem TCP, sem HTTP).
    ///  - Acesso só para SYSTEM, Administradores e usuários com logon INTERATIVO (console/RDP); logons de REDE são negados
    ///    (e o .NET ainda cria o pipe rejeitando clientes remotos);
    ///  - somente SYSTEM e Administradores podem criar novas instâncias do pipe;
    ///  - mensagens com tamanho validado ANTES de alocar memória; leitura com prazo; no máximo N clientes simultâneos;
    ///  - o tipo de comando e os dados são tratados como NÃO CONFIÁVEIS (IpcCommandHandler);
    ///  - nenhum token trafega por aqui.
    /// </summary>
    [SupportedOSPlatform("windows")]
    public sealed class IpcServer : BackgroundService
    {
        private DateTime _lastProtocolWarnUtc = DateTime.MinValue;
        private static readonly TimeSpan OperationTimeout = TimeSpan.FromSeconds(120);

        private readonly IpcCommandHandler _handler;
        private readonly ILogger<IpcServer> _log;

        public IpcServer(IpcCommandHandler handler, ILogger<IpcServer> log)
        {
            _handler = handler;
            _log = log;
        }

        protected override async Task ExecuteAsync(CancellationToken stoppingToken)
        {
            PipeSecurity security;
            try
            {
                security = PipeSecurityFactory.Create();
            }
            catch (Exception ex)
            {
                _log.LogError("Não foi possível montar a proteção do pipe local ({Tipo}). O Tray não conseguirá falar com o serviço.", ex.GetType().Name);
                return;
            }

            using (SemaphoreSlim slots = new SemaphoreSlim(AgentConstants.MaxIpcConcurrentClients, AgentConstants.MaxIpcConcurrentClients))
            {
                _log.LogInformation("Servidor local (Named Pipe) pronto.");
                bool firstInstanceCreated = false;
                DateTime lastAcceptWarnUtc = DateTime.MinValue;

                while (!stoppingToken.IsCancellationRequested)
                {
                    bool slotHeld = false;
                    NamedPipeServerStream? pipe = null;
                    try
                    {
                        await slots.WaitAsync(stoppingToken).ConfigureAwait(false);
                        slotHeld = true;

                        // A PRIMEIRA instância usa FirstPipeInstance: se outro processo já criou este nome de pipe
                        // (pipe squatting), a criação falha em vez de o Service aceitar clientes num pipe alheio.
                        PipeOptions options = PipeOptions.Asynchronous;
                        if (!firstInstanceCreated) options |= PipeOptions.FirstPipeInstance;

                        pipe = NamedPipeServerStreamAcl.Create(
                            AgentConstants.PipeName,
                            PipeDirection.InOut,
                            AgentConstants.MaxIpcConcurrentClients,
                            PipeTransmissionMode.Byte,
                            options,
                            AgentConstants.IpcPipeBufferBytes,
                            AgentConstants.IpcPipeBufferBytes,
                            security);
                        firstInstanceCreated = true;

                        await pipe.WaitForConnectionAsync(stoppingToken).ConfigureAwait(false);

                        NamedPipeServerStream accepted = pipe;
                        pipe = null;
                        slotHeld = false; // a tarefa abaixo devolve a vaga ao terminar
                        _ = Task.Run(() => HandleClientAsync(accepted, slots, stoppingToken), CancellationToken.None);
                    }
                    catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
                    {
                        break;
                    }
                    catch (Exception ex)
                    {
                        // no máximo 1 aviso por minuto (um pipe ocupado por outro processo não pode encher o log)
                        DateTime nowAccept = DateTime.UtcNow;
                        if ((nowAccept - lastAcceptWarnUtc) > TimeSpan.FromMinutes(1))
                        {
                            lastAcceptWarnUtc = nowAccept;
                            _log.LogWarning("Falha ao aceitar conexão local ({Tipo}). Se persistir, outro programa pode estar usando o nome do pipe.", ex.GetType().Name);
                        }
                        try
                        {
                            await Task.Delay(TimeSpan.FromSeconds(2), stoppingToken).ConfigureAwait(false);
                        }
                        catch (OperationCanceledException)
                        {
                            break;
                        }
                    }
                    finally
                    {
                        if (pipe != null) pipe.Dispose();
                        if (slotHeld) slots.Release();
                    }
                }
            }
        }

        private async Task HandleClientAsync(NamedPipeServerStream pipe, SemaphoreSlim slots, CancellationToken stoppingToken)
        {
            try
            {
                using (pipe)
                {
                    IpcResponse response;
                    try
                    {
                        response = await ProcessAsync(pipe, stoppingToken).ConfigureAwait(false);
                    }
                    catch (IpcProtocolException)
                    {
                        // no máximo 1 aviso por minuto: um usuário local não pode encher o log
                        DateTime nowWarn = DateTime.UtcNow;
                        if ((nowWarn - _lastProtocolWarnUtc) > TimeSpan.FromMinutes(1))
                        {
                            _lastProtocolWarnUtc = nowWarn;
                            _log.LogWarning("Mensagem local rejeitada (protocolo inválido).");
                        }
                        response = IpcResponse.Fail("mensagem_invalida", "Mensagem inválida.");
                    }

                    byte[] payload = IpcSerializer.Serialize(response);
                    if (payload.Length > AgentConstants.MaxIpcResponseBytes)
                    {
                        payload = IpcSerializer.Serialize(IpcResponse.Fail("resposta_grande", "A resposta excede o limite permitido."));
                    }

                    using (CancellationTokenSource writeCts = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken))
                    {
                        writeCts.CancelAfter(AgentConstants.IpcReadTimeout);
                        await IpcFraming.WriteFrameAsync(pipe, payload, AgentConstants.MaxIpcResponseBytes, writeCts.Token).ConfigureAwait(false);
                    }
                }
            }
            catch (OperationCanceledException)
            {
                // serviço parando ou prazo de leitura/escrita estourado: apenas encerra esta conexão
            }
            catch (IOException)
            {
                // o cliente fechou a conexão
            }
            catch (ObjectDisposedException)
            {
                // idem
            }
            catch (Exception ex)
            {
                _log.LogWarning("Erro ao atender conexão local ({Tipo}).", ex.GetType().Name);
            }
            finally
            {
                try
                {
                    slots.Release();
                }
                catch (ObjectDisposedException)
                {
                    // serviço encerrando
                }
            }
        }

        private async Task<IpcResponse> ProcessAsync(NamedPipeServerStream pipe, CancellationToken stoppingToken)
        {
            byte[] payload;
            using (CancellationTokenSource readCts = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken))
            {
                readCts.CancelAfter(AgentConstants.IpcReadTimeout);
                payload = await IpcFraming.ReadFrameAsync(pipe, AgentConstants.MaxIpcSubmitBytes, readCts.Token).ConfigureAwait(false);
            }

            IpcRequest request = IpcSerializer.Deserialize<IpcRequest>(payload);

            // Só o envio de impressoras pode ser grande; os demais comandos têm limite menor.
            if (!string.Equals(request.Cmd, IpcCommands.SubmitUserPrinters, StringComparison.Ordinal)
                && payload.Length > AgentConstants.MaxIpcRequestBytes)
            {
                throw new IpcProtocolException("Mensagem grande demais para este comando.");
            }

            // QUEM está falando vem do Windows (token do cliente do pipe), nunca do conteúdo da mensagem.
            CallerIdentity caller;
            try
            {
                caller = PipeCallerIdentity.Identify(pipe);
            }
            catch (Exception ex) when (ex is InvalidOperationException || ex is IOException || ex is UnauthorizedAccessException || ex is ArgumentException)
            {
                _log.LogWarning("Cliente do pipe sem identidade verificável; pedido recusado ({Tipo}).", ex.GetType().Name);
                return IpcResponse.Fail("acesso_negado", "Não foi possível identificar o usuário que fez o pedido.");
            }

            using (CancellationTokenSource opCts = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken))
            {
                opCts.CancelAfter(OperationTimeout);
                return await _handler.HandleAsync(request, caller, opCts.Token).ConfigureAwait(false);
            }
        }
    }
}
