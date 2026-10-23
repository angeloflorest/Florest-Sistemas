using System;
using System.Collections.Generic;
using System.Text.Json.Serialization;
using FlorestPrintAgent.Core.Printers;
using FlorestPrintAgent.Core.Storage;

namespace FlorestPrintAgent.Core.Agent
{
    /// <summary>Estados mostrados ao usuário.</summary>
    public static class AgentStatusKind
    {
        public const string NaoVinculado = "NaoVinculado";
        public const string Conectado = "Conectado";
        public const string SemConexao = "SemConexao";
        public const string Erro = "Erro";
    }

    /// <summary>Status do agente enviado ao Tray. NÃO contém token, segredo nem credencial.</summary>
    public sealed class AgentStatusDto
    {
        [JsonPropertyName("estado")] public string Estado { get; set; } = AgentStatusKind.NaoVinculado;
        [JsonPropertyName("mensagem")] public string? Mensagem { get; set; }
        [JsonPropertyName("computador")] public string Computador { get; set; } = string.Empty;
        [JsonPropertyName("empresa")] public string? Empresa { get; set; }
        [JsonPropertyName("estacao")] public string? Estacao { get; set; }
        [JsonPropertyName("ultima_comunicacao_utc")] public DateTime? UltimaComunicacaoUtc { get; set; }
        [JsonPropertyName("ultima_sincronizacao_utc")] public DateTime? UltimaSincronizacaoUtc { get; set; }
        [JsonPropertyName("impressoras_ativas")] public int? ImpressorasAtivas { get; set; }
        [JsonPropertyName("versao")] public string Versao { get; set; } = AgentConstants.AgentVersion;
        [JsonPropertyName("vinculado")] public bool Vinculado { get; set; }
        /// <summary>Última impressão concluída (Fase C). Ausente em versões antigas: o Tray 1.0.0 simplesmente ignora o campo.</summary>
        [JsonPropertyName("ultima_impressao")] public PrintEventDto? UltimaImpressao { get; set; }
        /// <summary>Último erro de impressão (Fase C).</summary>
        [JsonPropertyName("ultimo_erro_impressao")] public PrintEventDto? UltimoErroImpressao { get; set; }
    }

    /// <summary>Um evento de impressão para o Tray (sem conteúdo do pedido, sem credencial).</summary>
    public sealed class PrintEventDto
    {
        [JsonPropertyName("titulo")] public string Titulo { get; set; } = string.Empty;
        [JsonPropertyName("destino")] public string Destino { get; set; } = string.Empty;
        [JsonPropertyName("impressora")] public string? Impressora { get; set; }
        [JsonPropertyName("sucesso")] public bool Sucesso { get; set; }
        [JsonPropertyName("em_utc")] public DateTime EmUtc { get; set; }
        [JsonPropertyName("mensagem")] public string? Mensagem { get; set; }
    }

    public sealed class PairingPreviewDto
    {
        [JsonPropertyName("empresa")] public string Empresa { get; set; } = string.Empty;
        [JsonPropertyName("estacao")] public string? Estacao { get; set; }
        [JsonPropertyName("reinstalacao")] public bool Reinstalacao { get; set; }
    }

    public sealed class PrintersDto
    {
        [JsonPropertyName("impressoras")] public List<PrinterInfo> Impressoras { get; set; } = new List<PrinterInfo>();
    }

    public sealed class ScanResultDto
    {
        [JsonPropertyName("impressoras")] public List<PrinterInfo> Impressoras { get; set; } = new List<PrinterInfo>();
        /// <summary>True quando a lista foi enviada ao servidor nesta busca.</summary>
        [JsonPropertyName("sincronizado")] public bool Sincronizado { get; set; }
        [JsonPropertyName("resumo")] public SyncSummary? Resumo { get; set; }
    }

    /// <summary>Resultado de uma operação do controlador (convertido em resposta IPC).</summary>
    public sealed class ControllerResult
    {
        public bool Ok { get; private set; }
        public string? Erro { get; private set; }
        public string? Mensagem { get; private set; }
        public object? Data { get; private set; }

        public static ControllerResult Success(object? data)
        {
            return Success(data, null);
        }

        public static ControllerResult Success(object? data, string? message)
        {
            ControllerResult r = new ControllerResult();
            r.Ok = true;
            r.Data = data;
            r.Mensagem = message;
            return r;
        }

        public static ControllerResult Fail(string erro, string mensagem)
        {
            ControllerResult r = new ControllerResult();
            r.Ok = false;
            r.Erro = erro;
            r.Mensagem = mensagem;
            return r;
        }
    }
}
