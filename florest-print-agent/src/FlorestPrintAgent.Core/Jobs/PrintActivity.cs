using System;
using FlorestPrintAgent.Core.Agent;

namespace FlorestPrintAgent.Core.Jobs
{
    /// <summary>Última impressão e último erro de impressão (somente em memória; mostrados no Tray). Thread-safe.</summary>
    public interface IPrintActivity
    {
        void RecordSuccess(string title, string destination, string printerName);

        void RecordFailure(string title, string destination, string message);

        PrintActivitySnapshot Snapshot();
    }

    public sealed class PrintActivitySnapshot
    {
        public PrintEventDto? LastSuccess { get; set; }
        public PrintEventDto? LastFailure { get; set; }
    }

    public sealed class PrintActivity : IPrintActivity
    {
        private readonly IClock _clock;
        private readonly object _lock = new object();
        private PrintEventDto? _success;
        private PrintEventDto? _failure;

        public PrintActivity(IClock clock)
        {
            _clock = clock;
        }

        public void RecordSuccess(string title, string destination, string printerName)
        {
            PrintEventDto e = new PrintEventDto();
            e.Titulo = title;
            e.Destino = destination;
            e.Impressora = printerName;
            e.Sucesso = true;
            e.EmUtc = _clock.UtcNow;
            lock (_lock) { _success = e; }
        }

        public void RecordFailure(string title, string destination, string message)
        {
            PrintEventDto e = new PrintEventDto();
            e.Titulo = title;
            e.Destino = destination;
            e.Sucesso = false;
            e.Mensagem = message;
            e.EmUtc = _clock.UtcNow;
            lock (_lock) { _failure = e; }
        }

        public PrintActivitySnapshot Snapshot()
        {
            lock (_lock)
            {
                PrintActivitySnapshot s = new PrintActivitySnapshot();
                s.LastSuccess = _success;
                s.LastFailure = _failure;
                return s;
            }
        }
    }
}
