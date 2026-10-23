using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;
using FlorestPrintAgent.Core.Storage;
using Microsoft.Extensions.Logging;

namespace FlorestPrintAgent.Core.Jobs
{
    /// <summary>
    /// Diário local dos jobs que JÁ saíram na impressora mas cuja confirmação ao servidor ainda não foi aceita.
    /// Serve para nunca imprimir duas vezes o mesmo papel quando a internet cai entre "imprimiu" e "confirmei".
    /// Não guarda o conteúdo do pedido: só o id do job e a hora.
    /// </summary>
    public interface IPrintedJournal
    {
        bool Contains(string jobId);

        void Add(string jobId);

        void Remove(string jobId);

        /// <summary>Ids ainda sem confirmação aceita (mais antigos primeiro).</summary>
        IReadOnlyList<string> Pending();
    }

    public sealed class JournalEntry
    {
        [JsonPropertyName("job_id")] public string JobId { get; set; } = string.Empty;
        [JsonPropertyName("impresso_em_utc")] public DateTime PrintedUtc { get; set; }
    }

    internal sealed class JournalFile
    {
        [JsonPropertyName("versao")] public int Version { get; set; } = 1;
        [JsonPropertyName("jobs")] public List<JournalEntry> Jobs { get; set; } = new List<JournalEntry>();
    }

    /// <summary>Em memória (testes) ou em arquivo (quando path != null; gravação atômica).</summary>
    public sealed class PrintedJournal : IPrintedJournal
    {
        private readonly string? _path;
        private readonly IClock _clock;
        private readonly ILogger _log;
        private readonly object _lock = new object();
        private readonly List<JournalEntry> _entries = new List<JournalEntry>();
        private bool _loaded;

        public PrintedJournal(string? path, IClock clock, ILogger logger)
        {
            _path = path;
            _clock = clock;
            _log = logger;
        }

        private void EnsureLoaded()
        {
            if (_loaded) return;
            _loaded = true;
            if (_path == null) return;
            try
            {
                if (!File.Exists(_path)) return;
                JournalFile? f = JsonSerializer.Deserialize<JournalFile>(File.ReadAllText(_path), AgentJson.Options);
                if (f?.Jobs != null)
                {
                    foreach (JournalEntry e in f.Jobs)
                    {
                        if (!string.IsNullOrWhiteSpace(e.JobId)) _entries.Add(e);
                    }
                }
                Prune();
            }
            catch (Exception ex)
            {
                // arquivo corrompido: recomeça vazio (o pior caso é uma reimpressão, nunca uma perda)
                _log.LogWarning("Diário de impressões ilegível ({Tipo}); recomeçando vazio.", ex.GetType().Name);
                _entries.Clear();
                try
                {
                    // guarda uma cópia do arquivo ilegível para análise (a próxima gravação o substituiria)
                    File.Copy(_path, _path + ".corrompido", true);
                }
                catch (Exception)
                {
                    // melhor esforço
                }
            }
        }

        private void Prune()
        {
            DateTime limit = _clock.UtcNow - AgentConstants.PrintedJournalMaxAge;
            _entries.RemoveAll(e => e.PrintedUtc < limit);
            while (_entries.Count > AgentConstants.PrintedJournalMaxEntries) _entries.RemoveAt(0);
        }

        private void Save()
        {
            if (_path == null) return;
            try
            {
                JournalFile f = new JournalFile();
                f.Jobs = _entries.ToList();
                AtomicFile.WriteAllText(_path, JsonSerializer.Serialize(f, AgentJson.IndentedOptions));
            }
            catch (Exception ex)
            {
                _log.LogWarning("Não foi possível gravar o diário de impressões ({Tipo}).", ex.GetType().Name);
            }
        }

        public bool Contains(string jobId)
        {
            lock (_lock)
            {
                EnsureLoaded();
                return _entries.Any(e => string.Equals(e.JobId, jobId, StringComparison.OrdinalIgnoreCase));
            }
        }

        public void Add(string jobId)
        {
            lock (_lock)
            {
                EnsureLoaded();
                if (_entries.Any(e => string.Equals(e.JobId, jobId, StringComparison.OrdinalIgnoreCase))) return;
                JournalEntry entry = new JournalEntry();
                entry.JobId = jobId;
                entry.PrintedUtc = _clock.UtcNow;
                _entries.Add(entry);
                Prune();
                Save();
            }
        }

        public void Remove(string jobId)
        {
            lock (_lock)
            {
                EnsureLoaded();
                int n = _entries.RemoveAll(e => string.Equals(e.JobId, jobId, StringComparison.OrdinalIgnoreCase));
                if (n > 0) Save();
            }
        }

        public IReadOnlyList<string> Pending()
        {
            lock (_lock)
            {
                EnsureLoaded();
                return _entries.OrderBy(e => e.PrintedUtc).Select(e => e.JobId).ToList();
            }
        }
    }
}
