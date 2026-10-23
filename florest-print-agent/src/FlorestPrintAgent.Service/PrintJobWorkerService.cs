using System;
using System.Threading;
using System.Threading.Tasks;
using FlorestPrintAgent.Core.Jobs;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace FlorestPrintAgent.Service
{
    /// <summary>
    /// Hospeda o laço da fila de impressão DENTRO do serviço do Windows: consulta o servidor, imprime e confirma, com ou sem
    /// o Tray aberto, com ou sem usuário logado, e sem navegador. Independente do laço de heartbeat/sincronização.
    /// </summary>
    public sealed class PrintJobWorkerService : BackgroundService
    {
        private readonly PrintJobWorker _worker;
        private readonly ILogger<PrintJobWorkerService> _log;

        public PrintJobWorkerService(PrintJobWorker worker, ILogger<PrintJobWorkerService> log)
        {
            _worker = worker;
            _log = log;
        }

        protected override async Task ExecuteAsync(CancellationToken stoppingToken)
        {
            while (!stoppingToken.IsCancellationRequested)
            {
                try
                {
                    await _worker.RunAsync(stoppingToken).ConfigureAwait(false);
                    return; // RunAsync só termina quando o serviço está parando
                }
                catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
                {
                    return;
                }
                catch (Exception ex)
                {
                    _log.LogError("Falha inesperada no serviço de impressão ({Tipo}). Reiniciando em 15 s.", ex.GetType().Name);
                }

                try
                {
                    await Task.Delay(TimeSpan.FromSeconds(15), stoppingToken).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
            }
        }
    }
}
