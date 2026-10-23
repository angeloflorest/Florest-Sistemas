using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Text.Json.Serialization;
using FlorestPrintAgent.Core.Printers;

namespace FlorestPrintAgent.Core.Ipc
{
    public static class IpcCommands
    {
        public const string GetStatus = "GetStatus";
        public const string GetPrinters = "GetPrinters";
        public const string PairVerify = "PairVerify";
        public const string PairConfirm = "PairConfirm";
        public const string ScanPrinters = "ScanPrinters";
        public const string SubmitUserPrinters = "SubmitUserPrinters";
        public const string Unlink = "Unlink";
    }

    /// <summary>
    /// Requisição Tray → Service. NUNCA carrega token ou credencial: só comandos, o código de pareamento digitado
    /// pelo usuário e as impressoras detectadas na sessão do usuário. A IDENTIDADE de quem envia NÃO vai na mensagem:
    /// o Service a obtém do Windows (token do cliente do pipe).
    /// </summary>
    public sealed class IpcRequest
    {
        [JsonPropertyName("v")] public int Version { get; set; } = 1;
        [JsonPropertyName("cmd")] public string Cmd { get; set; } = string.Empty;
        [JsonPropertyName("codigo")] public string? Codigo { get; set; }
        [JsonPropertyName("impressoras")] public List<PrinterInfo>? Impressoras { get; set; }
        [JsonPropertyName("forcar")] public bool Forcar { get; set; }
    }

    /// <summary>Resposta Service → Tray: ok, erro, mensagem, dados.</summary>
    public sealed class IpcResponse
    {
        [JsonPropertyName("ok")] public bool Ok { get; set; }
        [JsonPropertyName("erro")] public string? Erro { get; set; }
        [JsonPropertyName("mensagem")] public string? Mensagem { get; set; }
        [JsonPropertyName("dados")] public JsonElement? Dados { get; set; }

        public static IpcResponse Success(object? data)
        {
            return Success(data, null);
        }

        public static IpcResponse Success(object? data, string? message)
        {
            IpcResponse r = new IpcResponse();
            r.Ok = true;
            r.Mensagem = message;
            if (data != null)
            {
                r.Dados = JsonSerializer.SerializeToElement(data, data.GetType(), AgentJson.Options);
            }
            return r;
        }

        public static IpcResponse Fail(string erro, string mensagem)
        {
            IpcResponse r = new IpcResponse();
            r.Ok = false;
            r.Erro = erro;
            r.Mensagem = mensagem;
            return r;
        }

        /// <summary>Lê o campo "dados" como o tipo esperado (null se ausente ou incompatível).</summary>
        public T? ReadData<T>() where T : class
        {
            if (!Dados.HasValue) return null;
            try
            {
                return JsonSerializer.Deserialize<T>(Dados.Value.GetRawText(), AgentJson.Options);
            }
            catch (JsonException)
            {
                return null;
            }
        }
    }
}
