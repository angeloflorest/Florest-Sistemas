using System;
using System.Collections.Generic;
using FlorestPrintAgent.Core.Api;
using FlorestPrintAgent.Core.Printers;

namespace FlorestPrintAgent.Core.Jobs
{
    public sealed class PrinterResolution
    {
        public bool Found { get; private set; }
        /// <summary>Nome da fila no Windows a usar (somente quando Found).</summary>
        public string Name { get; private set; } = string.Empty;
        public string ErrorCode { get; private set; } = string.Empty;
        public string Message { get; private set; } = string.Empty;
        /// <summary>Status informado pelo Windows (disponivel/offline/erro/desconhecido); apenas informativo.</summary>
        public string? Status { get; private set; }
        /// <summary>Aviso opcional (ex.: a fila mudou de porta desde a última sincronização); só para o log.</summary>
        public string? Note { get; private set; }

        public static PrinterResolution Ok(string name, string? status)
        {
            return Ok(name, status, null);
        }

        public static PrinterResolution Ok(string name, string? status, string? note)
        {
            PrinterResolution r = new PrinterResolution();
            r.Found = true;
            r.Name = name;
            r.Status = status;
            r.Note = note;
            return r;
        }

        public static PrinterResolution NotFound(string wanted)
        {
            PrinterResolution r = new PrinterResolution();
            r.Found = false;
            r.ErrorCode = PrintErrorCodes.PrinterNotFound;
            r.Message = "Impressora " + (string.IsNullOrWhiteSpace(wanted) ? "do destino" : wanted) + " não encontrada neste computador.";
            return r;
        }
    }

    /// <summary>Encontra, neste computador, a fila do Windows que o servidor indicou para o job. NUNCA devolve a impressora padrão.</summary>
    public interface IPrinterResolver
    {
        PrinterResolution Resolve(JobPrinter wanted);
    }

    public sealed class DiscoveryPrinterResolver : IPrinterResolver
    {
        private readonly IPrinterDiscovery _discovery;

        public DiscoveryPrinterResolver(IPrinterDiscovery discovery)
        {
            _discovery = discovery;
        }

        public PrinterResolution Resolve(JobPrinter wanted)
        {
            string wantedName = (wanted.Nome ?? string.Empty).Trim();
            string wantedId = (wanted.Identificador ?? string.Empty).Trim();

            DiscoveryResult found;
            try
            {
                found = _discovery.Discover();
            }
            catch (Exception)
            {
                found = DiscoveryResult.Fail("descoberta indisponível");
            }

            if (!found.Success)
            {
                // Não deu para listar as filas agora: tenta o nome que o servidor já conhece; se a fila não existir,
                // o spooler recusa (OpenPrinter) e o job volta para nova tentativa.
                if (wantedName.Length == 0) return PrinterResolution.NotFound(wantedName);
                return PrinterResolution.Ok(wantedName, null);
            }

            IReadOnlyList<PrinterInfo> list = found.Printers;

            // 1) Identificador estável sincronizado pelo próprio agente (SHA-256 de nome + porta + servidor/compartilhamento).
            //    É a chave principal: bate exatamente a fila que o ERP conhece.
            if (wantedId.Length > 0)
            {
                foreach (PrinterInfo p in list)
                {
                    if (string.Equals(p.Identificador, wantedId, StringComparison.OrdinalIgnoreCase))
                    {
                        return PrinterResolution.Ok(p.Nome, p.Status);
                    }
                }
            }

            // 2) Nome da fila (igualdade EXATA após normalizar maiúsculas, espaços e Unicode; nunca "parecido"). Dois nomes iguais não
            //    existem no Windows, então o resultado é único. O identificador muda quando a porta da fila muda: nesse caso a fila
            //    continua sendo a mesma pelo nome, e a mudança de porta é só registrada no log.
            if (wantedName.Length > 0)
            {
                string wantedKey = PrinterIdentifier.Normalize(wantedName);
                foreach (PrinterInfo p in list)
                {
                    if (!string.Equals(PrinterIdentifier.Normalize(p.Nome), wantedKey, StringComparison.Ordinal)) continue;

                    string? note = null;
                    string wantedPort = PrinterIdentifier.NormalizePort(wanted.PortaWindows);
                    string localPort = PrinterIdentifier.NormalizePort(p.PortaWindows);
                    if (wantedPort.Length > 0 && localPort.Length > 0 && !string.Equals(wantedPort, localPort, StringComparison.Ordinal))
                    {
                        note = "A fila '" + p.Nome + "' agora usa a porta '" + p.PortaWindows + "' (o ERP tinha '" + wanted.PortaWindows + "'); usando a fila pelo nome.";
                    }
                    return PrinterResolution.Ok(p.Nome, p.Status, note);
                }
            }

            // 3) Nada confere: FALHA CONTROLADA (impressora_nao_encontrada). Nunca a impressora padrão do Windows, nunca "a mais parecida".
            return PrinterResolution.NotFound(wantedName);
        }
    }
}
