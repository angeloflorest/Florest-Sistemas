using System;

namespace FlorestPrintAgent.Core
{
    /// <summary>Relógio injetável (permite testar prazos e backoff sem esperar).</summary>
    public interface IClock
    {
        DateTime UtcNow { get; }
    }

    public sealed class SystemClock : IClock
    {
        public DateTime UtcNow
        {
            get { return DateTime.UtcNow; }
        }
    }
}
