using System;

namespace FlorestPrintAgent.Core.Agent
{
    /// <summary>
    /// Quem está falando com o Service pelo Named Pipe, segundo o WINDOWS (token do cliente do pipe), e não segundo
    /// o que o cliente escreve na mensagem. É a base de toda autorização de operações sensíveis.
    /// </summary>
    public sealed class CallerIdentity
    {
        /// <summary>SID do usuário (ex.: S-1-5-21-...-1001).</summary>
        public string Sid { get; }

        /// <summary>Sessão do Windows em que o cliente roda (console = 1, cada RDP/troca rápida de usuário tem a sua).</summary>
        public int SessionId { get; }

        /// <summary>Token ELEVADO com o grupo Administradores habilitado (Tray "executar como administrador").</summary>
        public bool IsAdministrator { get; }

        /// <summary>O chamador é a conta SYSTEM.</summary>
        public bool IsSystem { get; }

        /// <summary>Identifica usuário + sessão (usada para ligar o fluxo de pareamento e as listas de impressoras).</summary>
        public string Key { get; }

        public CallerIdentity(string sid, int sessionId, bool isAdministrator, bool isSystem)
        {
            if (string.IsNullOrWhiteSpace(sid) || sid.Length > 184) throw new ArgumentException("SID inválido.", nameof(sid));
            Sid = sid.Trim();
            SessionId = sessionId;
            IsAdministrator = isAdministrator;
            IsSystem = isSystem;
            Key = Sid + "#" + sessionId.ToString(System.Globalization.CultureInfo.InvariantCulture);
        }

        public bool SameUser(string? sid)
        {
            return sid != null && string.Equals(Sid, sid, StringComparison.OrdinalIgnoreCase);
        }
    }
}
