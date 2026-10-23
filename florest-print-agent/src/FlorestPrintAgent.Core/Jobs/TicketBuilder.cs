using System;
using System.Collections.Generic;
using System.Text;

namespace FlorestPrintAgent.Core.Jobs
{
    /// <summary>
    /// Monta os bytes ESC/POS de cada papel (cozinha, bar, recibo não fiscal e teste).
    /// A composição original é pura; apenas a renderização Montserrat depende do Windows (sem rede).
    /// Nenhum texto vindo do servidor é interpretado como comando (TicketParser já removeu os controles).
    /// Tickets de cozinha/bar NUNCA levam preço.
    /// </summary>
    public static class TicketBuilder
    {
        public static byte[] Build(TicketData data, TicketLayout layout)
        {
            if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("A impressão Montserrat requer Windows.");
            return MontserratRaster.Render(BuildText(data, layout, true), layout.Normalized());
        }

        // Mantém a composição original separada da renderização da fonte para comparação de conteúdo.
        internal static byte[] BuildText(TicketData data, TicketLayout layout, bool measureMontserrat = false)
        {
            TicketLayout l = layout.Normalized();
            EscPosWriter w = new EscPosWriter(l, measureMontserrat);
            w.Init();

            switch (data.Tipo)
            {
                case TicketKinds.Recibo:
                    BuildReceipt(w, data, l);
                    break;
                case TicketKinds.RelatorioMesa:
                    BuildTableReport(w, data);
                    break;
                case TicketKinds.Teste:
                    BuildTest(w, data);
                    break;
                default:
                    BuildOrder(w, data);
                    break;
            }

            w.Finish();
            return w.ToArray();
        }

        // ------------------------------------------------------------------------------------------------------
        // Pedido de cozinha / bar
        // ------------------------------------------------------------------------------------------------------

        private static void BuildOrder(EscPosWriter w, TicketData d)
        {
            if (d.Empresa.Length > 0)
            {
                w.Align(1);
                w.Bold(true);
                w.WrappedText(d.Empresa, 1);
                w.Bold(false);
            }
            w.Align(0);
            w.Rule('-');

            // MESA em destaque (1.2.0: sem número de pedido, nem no cabeçalho nem no rodapé)
            string head = HeadLine(d);
            if (head.Length > 0)
            {
                w.Bold(true);
                w.Size(false, true);
                w.WrappedText(head, 1);
                w.Size(false, false);
                w.Bold(false);
            }
            if (d.DataHora.Length > 0) w.WrappedText("Data: " + d.DataHora, 1);

            w.Rule('=');
            w.Align(1);
            w.Bold(true);
            w.Size(true, true);
            w.WrappedText("*** " + (d.Setor.Length > 0 ? d.Setor : "PEDIDO") + " ***", 2);
            w.Size(false, false);
            w.Bold(false);
            w.Align(0);
            w.Rule('=');

            foreach (TicketItem item in d.Itens)
            {
                // quantidade + nome (negrito, dupla altura: legível à distância na cozinha)
                string line = (item.Quantidade.Length > 0 ? item.Quantidade + "x " : string.Empty) + item.Nome;
                w.Bold(true);
                w.Size(false, true);
                w.WrappedText(line, 1);
                w.Size(false, false);
                w.Bold(false);

                foreach (TicketChild child in item.Filhos)
                {
                    string c = "  > " + (child.Quantidade.Length > 0 ? child.Quantidade + "x " : string.Empty) + child.Nome;
                    if (child.Grupo.Length > 0) c += " (" + child.Grupo + ")";
                    w.Bold(true);
                    w.WrappedText(c, 1, "      ");
                    w.Bold(false);
                }

                if (!string.IsNullOrEmpty(item.Observacao))
                {
                    // observação DESTACADA (1.2.0): negrito + letra mais alta (dupla altura) + vídeo reverso quando a impressora
                    // suporta + marcador no texto. A largura não muda, então a quebra de linha continua a mesma.
                    w.Reverse(true);
                    w.Bold(true);
                    w.Size(false, true);
                    w.WrappedText(" OBS: " + item.Observacao + " ", 1, "  ");
                    w.Size(false, false);
                    w.Bold(false);
                    w.Reverse(false);
                }
                w.NewLine();
            }

            w.Rule('-');
            if (head.Length > 0)
            {
                w.Align(1);
                w.Bold(true);
                w.Size(true, true);
                w.WrappedText(head, 2);
                w.Size(false, false);
                w.Bold(false);
                w.Align(0);
            }
        }

        /// <summary>Cabeçalho/rodapé do pedido: SOMENTE "MESA n". O número do pedido (d.Pedido) é ignorado de propósito.</summary>
        private static string HeadLine(TicketData d)
        {
            if (!d.Mesa.HasValue) return string.Empty;
            return "MESA " + d.Mesa.Value.ToString(System.Globalization.CultureInfo.InvariantCulture);
        }

        // ------------------------------------------------------------------------------------------------------
        // Recibo NÃO FISCAL (Caixa / PDV)
        // ------------------------------------------------------------------------------------------------------

        private static void BuildReceipt(EscPosWriter w, TicketData d, TicketLayout l)
        {
            if (d.Empresa.Length > 0)
            {
                w.Align(1);
                w.Bold(true);
                w.WrappedText(d.Empresa, 1);
                w.Bold(false);
            }
            w.Align(1);
            w.WrappedText("RECIBO - NAO E DOCUMENTO FISCAL", 1);
            w.Align(0);
            w.Rule('-');

            StringBuilder head = new StringBuilder();
            if (d.Venda.HasValue) head.Append("VENDA ").Append(d.Venda.Value.ToString(System.Globalization.CultureInfo.InvariantCulture));
            if (d.Mesa.HasValue)
            {
                if (head.Length > 0) head.Append(" - ");
                head.Append("MESA ").Append(d.Mesa.Value.ToString(System.Globalization.CultureInfo.InvariantCulture));
            }
            if (head.Length > 0)
            {
                w.Bold(true);
                w.WrappedText(head.ToString(), 1);
                w.Bold(false);
            }
            if (d.DataHora.Length > 0) w.WrappedText("Data: " + d.DataHora, 1);
            w.Rule('-');

            foreach (TicketItem item in d.Itens)
            {
                w.WrappedText((item.Quantidade.Length > 0 ? item.Quantidade + "x " : string.Empty) + item.Nome, 1);
                if (item.PrecoUnitario != null || item.Subtotal != null)
                {
                    string left = "   " + (item.PrecoUnitario ?? string.Empty);
                    w.TwoColumns(left, item.Subtotal ?? string.Empty);
                }
            }
            w.Rule('-');

            if (d.Subtotal != null && (d.Desconto != null || d.Acrescimo != null || d.TaxaServico != null)) w.TwoColumns("Subtotal", d.Subtotal);
            if (d.Desconto != null && d.Desconto != "0,00") w.TwoColumns("Desconto", "-" + d.Desconto);
            if (d.Acrescimo != null && d.Acrescimo != "0,00") w.TwoColumns("Acrescimo", d.Acrescimo);
            if (d.TaxaServico != null && d.TaxaServico != "0,00") w.TwoColumns("Taxa de servico", d.TaxaServico);
            if (d.Total != null)
            {
                w.Bold(true);
                w.Size(false, true);
                w.TwoColumns("TOTAL R$", d.Total);
                w.Size(false, false);
                w.Bold(false);
            }

            foreach (TicketPayment p in d.Pagamentos)
            {
                w.TwoColumns(p.Forma, p.Valor);
            }
            w.Rule('-');
            w.Align(1);
            w.WrappedText("Obrigado pela preferencia!", 1);
            w.Align(0);
        }

        // ------------------------------------------------------------------------------------------------------
        // Relatório da MESA (1.2.0) — mesa ainda ABERTA. Não é pagamento, não é recibo e não é documento fiscal.
        // ------------------------------------------------------------------------------------------------------

        /// <summary>Texto do rodapé do relatório da mesa (o travessão do pedido vira hífen: a página de código não o tem).</summary>
        public const string TableReportFooter = "RELATÓRIO DA MESA - NÃO É DOCUMENTO FISCAL";

        private static void BuildTableReport(EscPosWriter w, TicketData d)
        {
            if (d.Empresa.Length > 0)
            {
                w.Align(1);
                w.Bold(true);
                w.WrappedText(d.Empresa, 1);
                w.Bold(false);
            }
            w.Align(1);
            w.WrappedText("RELATÓRIO DA MESA", 1);
            w.Align(0);
            w.Rule('-');

            string head = HeadLine(d);
            if (head.Length > 0)
            {
                w.Bold(true);
                w.Size(false, true);
                w.WrappedText(head, 1);
                w.Size(false, false);
                w.Bold(false);
            }
            if (d.DataHora.Length > 0) w.WrappedText("Data: " + d.DataHora, 1);
            w.Rule('-');

            foreach (TicketItem item in d.Itens)
            {
                w.Bold(true);
                w.WrappedText((item.Quantidade.Length > 0 ? item.Quantidade + "x " : string.Empty) + item.Nome, 1);
                w.Bold(false);
                foreach (TicketChild child in item.Filhos)
                {
                    string c = "  > " + (child.Quantidade.Length > 0 ? child.Quantidade + "x " : string.Empty) + child.Nome;
                    if (child.Grupo.Length > 0) c += " (" + child.Grupo + ")";
                    w.WrappedText(c, 1, "      ");
                }
                if (item.PrecoUnitario != null || item.Subtotal != null)
                {
                    // "  2 x 12,00 ........ 24,00": quantidade x preço unitário à esquerda, valor total do item à direita
                    string left = "   " + (item.Quantidade.Length > 0 ? item.Quantidade + " x " : string.Empty) + (item.PrecoUnitario ?? string.Empty);
                    w.TwoColumns(left, item.Subtotal ?? string.Empty);
                }
                if (!string.IsNullOrEmpty(item.Observacao))
                {
                    w.Bold(true);
                    w.WrappedText("   OBS: " + item.Observacao, 1, "        ");
                    w.Bold(false);
                }
            }
            w.Rule('-');

            bool temAjuste = IsMoneyPresent(d.Desconto) || IsMoneyPresent(d.Acrescimo) || IsMoneyPresent(d.TaxaServico);
            if (d.Subtotal != null && temAjuste) w.TwoColumns("Subtotal", d.Subtotal);
            if (IsMoneyPresent(d.Desconto)) w.TwoColumns("Desconto", "-" + d.Desconto);
            if (IsMoneyPresent(d.Acrescimo)) w.TwoColumns("Acréscimo", d.Acrescimo!);
            if (IsMoneyPresent(d.TaxaServico)) w.TwoColumns("Taxa de serviço", d.TaxaServico!);
            string? total = d.Total ?? d.Subtotal;
            if (total != null)
            {
                w.Bold(true);
                w.Size(false, true);
                w.TwoColumns("TOTAL DA MESA R$", total);
                w.Size(false, false);
                w.Bold(false);
            }
            if (IsMoneyPresent(d.JaPago))
            {
                w.TwoColumns("Já pago", d.JaPago!);
                if (d.FaltaPagar != null) w.TwoColumns("Falta pagar", d.FaltaPagar);
            }
            w.Rule('-');
            w.Align(1);
            w.Bold(true);
            w.WrappedText(TableReportFooter, 1);
            w.Bold(false);
            w.Align(0);
        }

        private static bool IsMoneyPresent(string? v)
        {
            return v != null && v != "0,00";
        }

        // ------------------------------------------------------------------------------------------------------
        // Teste de impressão
        // ------------------------------------------------------------------------------------------------------

        private static void BuildTest(EscPosWriter w, TicketData d)
        {
            w.Align(1);
            w.Bold(true);
            w.Size(true, true);
            w.WrappedText("TESTE DE IMPRESSAO", 2);
            w.Size(false, false);
            w.Bold(false);
            w.Rule('=');
            if (d.Empresa.Length > 0) w.WrappedText(d.Empresa, 1);
            if (d.Setor.Length > 0)
            {
                w.Bold(true);
                w.Size(false, true);
                w.WrappedText("Destino: " + d.Setor, 1);
                w.Size(false, false);
                w.Bold(false);
            }
            if (d.DataHora.Length > 0) w.WrappedText(d.DataHora, 1);
            w.Rule('-');
            w.WrappedText("Acentuacao: aeiou ç ã õ é í ó ú", 1);
            w.WrappedText("Se voce esta lendo isto, a impressora esta configurada corretamente.", 1);
            w.NewLine();
            w.WrappedText("Florest Print Agent " + AgentConstants.AgentVersion, 1);
            w.Align(0);
        }
    }

    /// <summary>Escritor de comandos ESC/POS (somente os comandos básicos, aceitos por Epson, Bematech, Elgin e compatíveis).</summary>
    internal sealed class EscPosWriter
    {
        private readonly List<byte> _bytes = new List<byte>(1024);
        private readonly TicketLayout _layout;
        private bool _wide;
        private bool _bold;
        private readonly bool _measureMontserrat;

        public EscPosWriter(TicketLayout layout, bool measureMontserrat = false)
        {
            _layout = layout;
            _measureMontserrat = measureMontserrat;
        }

        public byte[] ToArray()
        {
            return _bytes.ToArray();
        }

        private void Raw(params byte[] data)
        {
            _bytes.AddRange(data);
        }

        public void Init()
        {
            Raw(0x1B, 0x40);                                            // ESC @  : reinicia a impressora
            Raw(0x1B, 0x74, (byte)TicketLayout.EscTCode(_layout.CodePage)); // ESC t n: página de código
        }

        public void Align(int mode)
        {
            Raw(0x1B, 0x61, (byte)mode);                                // ESC a n: 0 esquerda, 1 centro, 2 direita
        }

        public void Bold(bool on)
        {
            _bold = on;
            Raw(0x1B, 0x45, (byte)(on ? 1 : 0));                        // ESC E n
        }

        public void Reverse(bool on)
        {
            Raw(0x1D, 0x42, (byte)(on ? 1 : 0));                        // GS B n : vídeo reverso
        }

        /// <summary>GS ! n : largura/altura dupla.</summary>
        public void Size(bool wide, bool tall)
        {
            byte n = 0;
            if (wide) n |= 0x10;
            if (tall) n |= 0x01;
            Raw(0x1D, 0x21, n);
            _wide = wide;
        }

        public void NewLine()
        {
            Raw(0x0A);
        }

        public void Text(string text)
        {
            _bytes.AddRange(EscPosText.Encode(text, _layout.CodePage));
        }

        public void Line(string text)
        {
            Text(text);
            NewLine();
        }

        public void Rule(char ch)
        {
            Line(new string(ch, _layout.Columns));
        }

        /// <summary>Quebra o texto na largura útil (a metade quando a letra está em largura dupla) e imprime cada linha.</summary>
        public void WrappedText(string text, int widthFactor)
        {
            WrappedText(text, widthFactor, string.Empty);
        }

        public void WrappedText(string text, int widthFactor, string continuationIndent)
        {
            if (_measureMontserrat)
            {
                if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("A impressão Montserrat requer Windows.");
                foreach (string line in MontserratRaster.WrapText(text, continuationIndent, _layout, _bold, _wide)) Line(line);
                return;
            }
            int width = Math.Max(8, _layout.Columns / Math.Max(1, widthFactor));
            foreach (string line in Wrap(text, width, continuationIndent))
            {
                Line(line);
            }
        }

        /// <summary>Esquerda e direita na mesma linha (a direita alinhada à margem).</summary>
        public void TwoColumns(string left, string right)
        {
            int width = Math.Max(8, _wide ? _layout.Columns / 2 : _layout.Columns);
            string l = left ?? string.Empty;
            string r = right ?? string.Empty;
            if (r.Length >= width) r = r.Substring(0, width);
            int room = width - r.Length - 1;
            if (room < 1)
            {
                Line(r);
                return;
            }
            if (l.Length > room) l = l.Substring(0, room);
            Line(l + new string(' ', width - l.Length - r.Length) + r);
        }

        public void Finish()
        {
            Align(0);
            Size(false, false);
            Reverse(false);
            Bold(false);
            for (int i = 0; i < _layout.FeedLines; i++) NewLine();
            if (_layout.Cut)
            {
                Raw(0x1D, 0x56, 0x42, 0x00);                            // GS V B 0 : corte parcial (avança o papel e corta)
            }
        }

        // ------------------------------------------------------------------------------------------------------

        public static List<string> Wrap(string text, int width, string continuationIndent)
        {
            List<string> lines = new List<string>();
            if (string.IsNullOrEmpty(text) || width < 1)
            {
                lines.Add(string.Empty);
                return lines;
            }

            string indent = (continuationIndent ?? string.Empty);
            if (indent.Length >= width / 2) indent = string.Empty;

            StringBuilder current = new StringBuilder();
            string[] words = text.Split(new char[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);

            foreach (string rawWord in words)
            {
                string word = rawWord;
                while (word.Length > 0)
                {
                    // a primeira linha não tem recuo; as seguintes têm
                    string prefix = lines.Count == 0 ? string.Empty : indent;
                    if (current.Length == 0) current.Append(prefix);

                    bool hasContent = current.Length > prefix.Length;
                    int room = width - current.Length - (hasContent ? 1 : 0);

                    if (word.Length <= room)
                    {
                        if (hasContent) current.Append(' ');
                        current.Append(word);
                        word = string.Empty;
                    }
                    else if (hasContent)
                    {
                        // não cabe: fecha a linha e tenta de novo na próxima
                        lines.Add(current.ToString());
                        current.Clear();
                    }
                    else
                    {
                        // linha vazia e a palavra é maior que a linha: quebra à força (sempre avança ao menos 1 caractere)
                        int take = Math.Max(1, room);
                        current.Append(word, 0, take);
                        word = word.Substring(take);
                        lines.Add(current.ToString());
                        current.Clear();
                    }
                }
            }

            string lastPrefix = lines.Count == 0 ? string.Empty : indent;
            if (current.Length > lastPrefix.Length) lines.Add(current.ToString());
            if (lines.Count == 0) lines.Add(string.Empty);
            return lines;
        }
    }
}
