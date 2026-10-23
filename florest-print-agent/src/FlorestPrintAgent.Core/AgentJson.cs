using System.Text.Json;
using System.Text.Json.Serialization;

namespace FlorestPrintAgent.Core
{
    /// <summary>Opções de JSON compartilhadas (IPC, estado local e corpo das requisições).</summary>
    public static class AgentJson
    {
        /// <summary>IPC e estado local: campos nulos são omitidos, leitura sem diferenciar maiúsculas.</summary>
        public static readonly JsonSerializerOptions Options = new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            WriteIndented = false,
        };

        /// <summary>Estado local legível (arquivo de estado).</summary>
        public static readonly JsonSerializerOptions IndentedOptions = new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            WriteIndented = true,
        };

        /// <summary>Corpo enviado à Edge Function: nulos são enviados como null (ex.: "ip": null).</summary>
        public static readonly JsonSerializerOptions WireOptions = new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
            DefaultIgnoreCondition = JsonIgnoreCondition.Never,
            WriteIndented = false,
        };
    }
}
