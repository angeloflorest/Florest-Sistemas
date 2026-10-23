using System;
using System.Diagnostics.CodeAnalysis;
using System.Text.RegularExpressions;

namespace FlorestPrintAgent.Core.Security
{
    /// <summary>
    /// Credencial do agente: fpa_&lt;agente_id&gt;.&lt;segredo&gt;. ToString() NUNCA devolve o segredo,
    /// para que um log acidental ("{token}") não vaze a credencial.
    /// </summary>
    public sealed class AgentToken
    {
        private readonly string _full;

        public string AgentId { get; }

        internal AgentToken(string agentId, string full)
        {
            AgentId = agentId;
            _full = full;
        }

        /// <summary>Valor completo do token (somente para o cabeçalho Authorization e para a DPAPI).</summary>
        public string RevealForAuthorization()
        {
            return _full;
        }

        public override string ToString()
        {
            return "fpa_" + AgentId + ".[oculto]";
        }
    }

    public static class TokenParser
    {
        // fpa_<uuid>.<32 bytes em base64url sem padding = 43 caracteres>   (formato emitido pela Edge Function)
        private static readonly Regex TokenRegex = new Regex(
            "^fpa_([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\\.([A-Za-z0-9_-]{43})$",
            RegexOptions.CultureInvariant | RegexOptions.Compiled);

        public static bool TryParse(string? raw, [NotNullWhen(true)] out AgentToken? token)
        {
            token = null;
            if (string.IsNullOrEmpty(raw) || raw.Length > 128) return false;
            Match m = TokenRegex.Match(raw);
            if (!m.Success) return false;
            string id = m.Groups[1].Value.ToLowerInvariant();
            string secret = m.Groups[2].Value;
            token = new AgentToken(id, "fpa_" + id + "." + secret);
            return true;
        }
    }
}
