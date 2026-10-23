using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using FlorestPrintAgent.Core.Printers;

namespace FlorestPrintAgent.Core.Storage
{
    /// <summary>Resumo da última sincronização aceita pelo servidor.</summary>
    public sealed class SyncSummary
    {
        [JsonPropertyName("recebidas")] public int Received { get; set; }
        [JsonPropertyName("validas")] public int Valid { get; set; }
        [JsonPropertyName("rejeitadas")] public int Rejected { get; set; }
        [JsonPropertyName("novas")] public int New { get; set; }
        [JsonPropertyName("alteradas")] public int Changed { get; set; }
        [JsonPropertyName("desativadas")] public int Deactivated { get; set; }
        [JsonPropertyName("ativas")] public int Active { get; set; }
    }

    /// <summary>Impressoras da sessão de um usuário do Windows, entregues pelo Tray ao Service.</summary>
    public sealed class UserPrinterList
    {
        [JsonPropertyName("sessao")] public string Session { get; set; } = string.Empty;
        [JsonPropertyName("atualizado_em_utc")] public DateTime UpdatedUtc { get; set; }
        [JsonPropertyName("hash")] public string Hash { get; set; } = string.Empty;
        [JsonPropertyName("impressoras")] public List<PrinterInfo> Printers { get; set; } = new List<PrinterInfo>();
    }

    /// <summary>
    /// Estado NÃO sensível do agente. Persistido em estado.json. Campos [JsonIgnore] são estado transitório
    /// (só em memória). Nunca contém token, segredo, hash de credencial nem código de pareamento.
    /// </summary>
    public sealed class AgentState
    {
        [JsonPropertyName("empresa_nome")] public string? CompanyName { get; set; }
        [JsonPropertyName("estacao_nome")] public string? StationName { get; set; }
        [JsonPropertyName("pareado_em_utc")] public DateTime? PairedUtc { get; set; }
        /// <summary>SID do usuário do Windows que conectou este computador (só ele, ou um Administrador, pode desvincular). Não é sensível.</summary>
        [JsonPropertyName("pareado_por_sid")] public string? PairedBySid { get; set; }
        [JsonPropertyName("heartbeat_segundos")] public int HeartbeatSeconds { get; set; } = AgentConstants.DefaultHeartbeatSeconds;
        [JsonPropertyName("limite_impressoras")] public int PrinterLimit { get; set; } = AgentConstants.MaxPrintersPerSync;
        [JsonPropertyName("ultimo_heartbeat_ok_utc")] public DateTime? LastHeartbeatOkUtc { get; set; }
        [JsonPropertyName("ultimo_sync_ok_utc")] public DateTime? LastSyncOkUtc { get; set; }
        [JsonPropertyName("ultimo_sync_resumo")] public SyncSummary? LastSync { get; set; }
        [JsonPropertyName("impressoras_usuario")] public List<UserPrinterList> UserPrinters { get; set; } = new List<UserPrinterList>();

        // ----- transitório (não persiste) -----
        [JsonIgnore] public string? LastError { get; set; }
        [JsonIgnore] public string? LastSyncError { get; set; }
        [JsonIgnore] public bool CredentialRejected { get; set; }
        [JsonIgnore] public bool LastContactFailed { get; set; }
    }

    public sealed class AgentStateStore
    {
        private readonly string _file;

        public AgentStateStore(string file)
        {
            _file = file;
        }

        private volatile bool _loadUnavailable;

        /// <summary>
        /// Carrega o estado. Arquivo ausente/inválido gera um estado limpo (o vínculo vive na credencial, não aqui).
        /// Erro transitório de leitura (bloqueio, permissão) NÃO é tratado como "recomeçar do zero": o arquivo existente
        /// é preservado e nada é gravado por cima dele nesta execução.
        /// </summary>
        public AgentState Load()
        {
            _loadUnavailable = false;
            for (int attempt = 0; attempt < 4; attempt++)
            {
                string text;
                try
                {
                    if (!File.Exists(_file)) return new AgentState();
                    text = File.ReadAllText(_file);
                }
                catch (Exception ex) when (ex is IOException || ex is UnauthorizedAccessException)
                {
                    if (attempt < 3)
                    {
                        System.Threading.Thread.Sleep(150);
                        continue;
                    }
                    _loadUnavailable = true;
                    return new AgentState();
                }

                try
                {
                    AgentState? state = JsonSerializer.Deserialize<AgentState>(text, AgentJson.Options);
                    if (state != null) return Normalize(state);
                }
                catch (JsonException)
                {
                    // estado corrompido: recomeça limpo
                }
                return new AgentState();
            }
            return new AgentState();
        }

        public void Save(AgentState state)
        {
            if (_loadUnavailable) return; // não sobrescreve um arquivo que existe mas não pôde ser lido
            string json = JsonSerializer.Serialize(state, AgentJson.IndentedOptions);
            AtomicFile.WriteAllText(_file, json);
        }

        private static AgentState Normalize(AgentState s)
        {
            if (s.UserPrinters == null) s.UserPrinters = new List<UserPrinterList>();
            if (s.HeartbeatSeconds < AgentConstants.MinHeartbeatSeconds || s.HeartbeatSeconds > AgentConstants.MaxHeartbeatSeconds)
                s.HeartbeatSeconds = AgentConstants.DefaultHeartbeatSeconds;
            if (s.PrinterLimit < 1 || s.PrinterLimit > AgentConstants.MaxPrintersPerSync)
                s.PrinterLimit = AgentConstants.MaxPrintersPerSync;
            foreach (UserPrinterList l in s.UserPrinters)
            {
                if (l.Printers == null) l.Printers = new List<PrinterInfo>();
            }
            return s;
        }
    }
}
