using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using FlorestPrintAgent.Core.Security;
using Microsoft.Extensions.Logging;

namespace FlorestPrintAgent.Core.Logging
{
    /// <summary>
    /// Log em arquivo, rotativo e limitado: "{prefixo}.log" é o arquivo atual; ao passar de maxFileBytes ele é
    /// renomeado para "{prefixo}.{data-hora}.log" e os mais antigos além de maxFiles são apagados.
    /// Toda linha passa por LogSanitizer (rede de proteção contra token/hash/código/Authorization).
    /// Falha ao gravar log NUNCA derruba o agente.
    /// </summary>
    public sealed class FileLoggerProvider : ILoggerProvider
    {
        private readonly string _directory;
        private readonly string _prefix;
        private readonly long _maxFileBytes;
        private readonly int _maxFiles;
        private readonly LogLevel _minLevel;
        private readonly object _lock = new object();

        public FileLoggerProvider(string directory, string prefix, long maxFileBytes, int maxFiles, LogLevel minLevel)
        {
            _directory = directory;
            _prefix = prefix;
            _maxFileBytes = maxFileBytes;
            _maxFiles = maxFiles;
            _minLevel = minLevel;
            try
            {
                Directory.CreateDirectory(_directory);
                Prune();
            }
            catch (Exception)
            {
                // sem pasta de log o agente continua funcionando
            }
        }

        public FileLoggerProvider(string directory, string prefix)
            : this(directory, prefix, 5L * 1024 * 1024, 10, LogLevel.Information)
        {
        }

        public ILogger CreateLogger(string categoryName)
        {
            return new FileLogger(this, categoryName);
        }

        public void Dispose()
        {
        }

        internal bool IsEnabled(LogLevel level)
        {
            return level >= _minLevel && level != LogLevel.None;
        }

        internal void Write(LogLevel level, string category, string message, Exception? exception)
        {
            try
            {
                StringBuilder sb = new StringBuilder();
                sb.Append(DateTimeOffset.Now.ToString("yyyy-MM-dd HH:mm:ss.fff zzz", CultureInfo.InvariantCulture));
                sb.Append(" [").Append(LevelName(level)).Append("] ");
                sb.Append(ShortCategory(category)).Append(": ");
                sb.Append(LogSanitizer.Scrub(message).Replace("\r", " ").Replace("\n", " "));
                if (exception != null)
                {
                    sb.Append(" | ").Append(exception.GetType().Name).Append(": ");
                    sb.Append(LogSanitizer.Scrub(exception.Message).Replace("\r", " ").Replace("\n", " "));
                }
                sb.Append(Environment.NewLine);

                lock (_lock)
                {
                    Directory.CreateDirectory(_directory);
                    string path = Path.Combine(_directory, _prefix + ".log");
                    RotateIfNeeded(path);
                    File.AppendAllText(path, sb.ToString(), new UTF8Encoding(false));
                }
            }
            catch (Exception)
            {
                // nunca propaga falha de log
            }
        }

        private void RotateIfNeeded(string path)
        {
            FileInfo info = new FileInfo(path);
            if (!info.Exists || info.Length < _maxFileBytes) return;
            string stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture);
            string target = Path.Combine(_directory, _prefix + "." + stamp + ".log");
            int n = 1;
            while (File.Exists(target))
            {
                target = Path.Combine(_directory, _prefix + "." + stamp + "-" + n.ToString(CultureInfo.InvariantCulture) + ".log");
                n++;
            }
            File.Move(path, target);
            Prune();
        }

        private void Prune()
        {
            DirectoryInfo dir = new DirectoryInfo(_directory);
            if (!dir.Exists) return;
            List<FileInfo> rotated = dir.GetFiles(_prefix + ".*.log")
                .OrderByDescending(f => f.LastWriteTimeUtc)
                .ToList();
            for (int i = _maxFiles; i < rotated.Count; i++)
            {
                try
                {
                    rotated[i].Delete();
                }
                catch (Exception)
                {
                    // ignora
                }
            }
        }

        private static string LevelName(LogLevel level)
        {
            switch (level)
            {
                case LogLevel.Trace: return "TRC";
                case LogLevel.Debug: return "DBG";
                case LogLevel.Information: return "INF";
                case LogLevel.Warning: return "WRN";
                case LogLevel.Error: return "ERR";
                case LogLevel.Critical: return "CRT";
                default: return "???";
            }
        }

        private static string ShortCategory(string category)
        {
            int i = category.LastIndexOf('.');
            return i >= 0 && i < category.Length - 1 ? category.Substring(i + 1) : category;
        }

        private sealed class FileLogger : ILogger
        {
            private readonly FileLoggerProvider _provider;
            private readonly string _category;

            public FileLogger(FileLoggerProvider provider, string category)
            {
                _provider = provider;
                _category = category;
            }

            public IDisposable? BeginScope<TState>(TState state) where TState : notnull
            {
                return null;
            }

            public bool IsEnabled(LogLevel logLevel)
            {
                return _provider.IsEnabled(logLevel);
            }

            public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
            {
                if (!IsEnabled(logLevel)) return;
                string message = formatter(state, exception);
                _provider.Write(logLevel, _category, message, exception);
            }
        }
    }
}
