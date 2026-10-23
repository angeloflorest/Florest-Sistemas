using System;
using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace FlorestPrintAgent.Core.Printers
{
    /// <summary>
    /// Impressora no formato do contrato com o servidor (/agent/sync). Também é o formato do IPC e do estado local.
    /// ip e porta são null quando não foram CONFIRMADOS pelo Windows: nunca são inventados.
    /// </summary>
    public sealed class PrinterInfo
    {
        [JsonPropertyName("identificador")] public string Identificador { get; set; } = string.Empty;
        [JsonPropertyName("nome")] public string Nome { get; set; } = string.Empty;
        [JsonPropertyName("conexao")] public string Conexao { get; set; } = PrinterConnection.Outro;
        [JsonPropertyName("ip")] public string? Ip { get; set; }
        [JsonPropertyName("porta")] public int? Porta { get; set; }
        [JsonPropertyName("porta_windows")] public string? PortaWindows { get; set; }
        [JsonPropertyName("status")] public string Status { get; set; } = PrinterStatus.Desconhecido;

        public PrinterInfo Clone()
        {
            PrinterInfo c = new PrinterInfo();
            c.Identificador = Identificador;
            c.Nome = Nome;
            c.Conexao = Conexao;
            c.Ip = Ip;
            c.Porta = Porta;
            c.PortaWindows = PortaWindows;
            c.Status = Status;
            return c;
        }
    }

    /// <summary>
    /// Valores de conexão. A Migration 029 só exige o FORMATO ^[a-z][a-z0-9_]{0,29}$ (sem lista fechada); estes são os
    /// valores que o agente usa (os mesmos citados nos comentários da 029).
    /// </summary>
    public static class PrinterConnection
    {
        public const string Usb = "usb";
        public const string Rede = "rede";
        public const string Compartilhada = "compartilhada";
        public const string Windows = "windows";
        public const string Outro = "outro";
    }

    /// <summary>
    /// Valores de status. A tela do ERP entende "disponivel" (Conectada) e "offline"; os demais aparecem como Indisponível.
    /// "desconhecido" é o DEFAULT do banco.
    /// </summary>
    public static class PrinterStatus
    {
        public const string Disponivel = "disponivel";
        public const string Offline = "offline";
        public const string Erro = "erro";
        public const string Desconhecido = "desconhecido";
    }

    /// <summary>Dados brutos de uma fila do spooler (PRINTER_INFO_2), antes da classificação.</summary>
    public sealed class RawPrinter
    {
        public string Name { get; set; } = string.Empty;
        public string? ServerName { get; set; }
        public string? ShareName { get; set; }
        public string? PortName { get; set; }
        public string? DriverName { get; set; }
        public uint Attributes { get; set; }
        public uint Status { get; set; }
        /// <summary>False quando o status do spooler não pôde ser lido.</summary>
        public bool StatusKnown { get; set; } = true;
    }

    /// <summary>Informações de uma porta do spooler (PORT_INFO_2).</summary>
    public sealed class PortDetails
    {
        public string PortName { get; set; } = string.Empty;
        public string? MonitorName { get; set; }
        public string? Description { get; set; }
    }

    /// <summary>Dados REAIS de uma porta "Standard TCP/IP Port" lidos (somente leitura) do registro do Windows.</summary>
    public sealed class TcpIpPortInfo
    {
        public string? HostName { get; set; }
        public string? IpAddress { get; set; }
        public int? PortNumber { get; set; }
        /// <summary>1 = RAW, 2 = LPR (valores do monitor TCP/IP do Windows).</summary>
        public int? Protocol { get; set; }
    }

    public interface ITcpIpPortReader
    {
        TcpIpPortInfo? TryRead(string portName);
    }

    public sealed class DiscoveryResult
    {
        public bool Success { get; private set; }
        public IReadOnlyList<PrinterInfo> Printers { get; private set; } = new List<PrinterInfo>();
        public string? Error { get; private set; }

        /// <summary>Varredura COMPLETA bem-sucedida (pode ter zero impressoras: isso é um resultado válido).</summary>
        public static DiscoveryResult Ok(IReadOnlyList<PrinterInfo> printers)
        {
            DiscoveryResult r = new DiscoveryResult();
            r.Success = true;
            r.Printers = printers;
            return r;
        }

        /// <summary>Falha técnica na descoberta: NUNCA deve virar "lista vazia" no servidor.</summary>
        public static DiscoveryResult Fail(string error)
        {
            DiscoveryResult r = new DiscoveryResult();
            r.Success = false;
            r.Error = error;
            return r;
        }
    }

    public interface IPrinterDiscovery
    {
        /// <summary>Enumera as impressoras visíveis ao contexto atual (síncrono; chamar fora da thread de UI).</summary>
        DiscoveryResult Discover();
    }
}
