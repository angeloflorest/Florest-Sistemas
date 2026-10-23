using System;
using System.Threading;
using System.Threading.Tasks;
using FlorestPrintAgent.Core.Agent;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace FlorestPrintAgent.Service
{
    /// <summary>
    /// Executa o laço do agente (heartbeat, renovação e sincronização) enquanto o serviço estiver ativo.
    /// Funciona sem nenhum usuário logado e sem o Tray aberto.
    /// </summary>
    public sealed class AgentWorker : BackgroundService
    {
        private readonly AgentCoordinator _coordinator;
        private readonly ILogger<AgentWorker> _log;

        public AgentWorker(AgentCoordinator coordinator, ILogger<AgentWorker> log)
        {
            _coordinator = coordinator;
            _log = log;
        }

        protected override async Task ExecuteAsync(CancellationToken stoppingToken)
        {
            while (!stoppingToken.IsCancellationRequested)
            {
                try
                {
                    await _coordinator.RunAsync(stoppingToken).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
                {
                    break;
                }
                catch (Exception ex)
                {
                    // RunAsync já trata os próprios erros; isto é só a última rede de proteção para o serviço não cair.
                    _log.LogError("Falha inesperada no laço do agente ({Tipo}). Reiniciando o laço em 30 s.", ex.GetType().Name);
                }

                if (stoppingToken.IsCancellationRequested) break;

                try
                {
                    await Task.Delay(TimeSpan.FromSeconds(30), stoppingToken).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
            }
        }
    }
}
