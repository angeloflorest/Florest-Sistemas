using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Text.Json;
using FlorestPrintAgent.Core.Printers;

namespace FlorestPrintAgent.Core.Jobs
{
    /// <summary>Complemento / escolha de um item (ex.: "Escolha o espeto: Espeto de Carne").</summary>
    public sealed class TicketChild
    {
        public string Quantidade { get; set; } = string.Empty;
        public string Nome { get; set; } = string.Empty;
        public string Grupo { get; set; } = string.Empty;
    }

    public sealed class TicketItem
    {
        public string Quantidade { get; set; } = string.Empty;
        public string Nome { get; set; } = string.Empty;
        /// <summary>Observação do item (ex.: SEM CEBOLA). Impressa em destaque.</summary>
        public string? Observacao { get; set; }
        public List<TicketChild> Filhos { get; set; } = new List<TicketChild>();
        /// <summary>Somente recibo: preço unitário e subtotal já formatados.</summary>
        public string? PrecoUnitario { get; set; }
        public string? Subtotal { get; set; }
    }

    public sealed class TicketPayment
    {
        public string Forma { get; set; } = string.Empty;
        public string Valor { get; set; } = string.Empty;
    }

    public static class TicketKinds
    {
        public const string PedidoBar = "pedido_bar";
        public const string Recibo = "recibo";
        /// <summary>Relatório térmico da mesa ABERTA (1.2.0): consulta de conta, NÃO é pagamento nem documento fiscal.</summary>
        public const string RelatorioMesa = "relatorio_mesa";
        public const string Teste = "teste";
    }

    /// <summary>Conteúdo de um papel, já higienizado (sem caracteres de controle: nada de ESC/POS vindo de texto de produto).</summary>
    public sealed class TicketData
    {
        public string Tipo { get; set; } = TicketKinds.PedidoBar;
        public string Empresa { get; set; } = string.Empty;
        /// <summary>COZINHA, BAR ou CAIXA.</summary>
        public string Setor { get; set; } = string.Empty;
        public int? Mesa { get; set; }
        public int? Pedido { get; set; }
        public int? Venda { get; set; }
        public string DataHora { get; set; } = string.Empty;
        public List<TicketItem> Itens { get; set; } = new List<TicketItem>();
        public List<TicketPayment> Pagamentos { get; set; } = new List<TicketPayment>();
        public string? Subtotal { get; set; }
        public string? Desconto { get; set; }
        public string? Acrescimo { get; set; }
        public string? TaxaServico { get; set; }
        public string? Total { get; set; }
        /// <summary>Somente relatório da mesa: quanto já foi pago e quanto falta (opcionais).</summary>
        public string? JaPago { get; set; }
        public string? FaltaPagar { get; set; }
    }

    /// <summary>Converte o payload JSON do servidor em TicketData. Tolerante com campos ausentes; recusa só o que impede imprimir.</summary>
    public static class TicketParser
    {
        private const int MaxItems = 200;
        private const int MaxChildren = 100;
        private const int MaxText = 200;

        public static bool TryParse(string jobType, JsonElement payload, out TicketData? data, out string error)
        {
            data = null;
            error = string.Empty;
            if (payload.ValueKind != JsonValueKind.Object)
            {
                error = "O conteúdo do pedido de impressão é inválido.";
                return false;
            }

            string tipo = Text(payload, "tipo", 30);
            if (tipo.Length == 0) tipo = jobType;
            if (tipo != TicketKinds.PedidoBar && tipo != TicketKinds.Recibo && tipo != TicketKinds.RelatorioMesa && tipo != TicketKinds.Teste)
            {
                error = "Tipo de impressão desconhecido.";
                return false;
            }

            TicketData d = new TicketData();
            d.Tipo = tipo;
            d.Empresa = Text(payload, "empresa", 120);
            d.Setor = Text(payload, "setor", 30).ToUpperInvariant();
            d.Mesa = Int(payload, "mesa");
            d.Pedido = Int(payload, "pedido");
            d.Venda = Int(payload, "venda");
            d.DataHora = Text(payload, "data_hora", 30);
            d.Subtotal = Money(payload, "subtotal");
            d.Desconto = Money(payload, "desconto");
            d.Acrescimo = Money(payload, "acrescimo");
            d.TaxaServico = Money(payload, "taxa_servico");
            d.Total = Money(payload, "total");
            d.JaPago = Money(payload, "ja_pago");
            d.FaltaPagar = Money(payload, "falta_pagar");

            JsonElement itens;
            if (payload.TryGetProperty("itens", out itens) && itens.ValueKind == JsonValueKind.Array)
            {
                int n = 0;
                foreach (JsonElement it in itens.EnumerateArray())
                {
                    if (++n > MaxItems) break;
                    if (it.ValueKind != JsonValueKind.Object) continue;
                    TicketItem item = new TicketItem();
                    item.Quantidade = Quantity(it, "quantidade");
                    item.Nome = Text(it, "nome", MaxText);
                    string obs = Text(it, "observacao", MaxText);
                    item.Observacao = obs.Length > 0 ? obs : null;
                    item.PrecoUnitario = Money(it, "preco_unitario");
                    item.Subtotal = Money(it, "subtotal");
                    JsonElement filhos;
                    if (it.TryGetProperty("filhos", out filhos) && filhos.ValueKind == JsonValueKind.Array)
                    {
                        int c = 0;
                        foreach (JsonElement f in filhos.EnumerateArray())
                        {
                            if (++c > MaxChildren) break;
                            if (f.ValueKind != JsonValueKind.Object) continue;
                            TicketChild child = new TicketChild();
                            child.Quantidade = Quantity(f, "quantidade");
                            child.Nome = Text(f, "nome", MaxText);
                            child.Grupo = Text(f, "grupo", MaxText);
                            if (child.Nome.Length > 0) item.Filhos.Add(child);
                        }
                    }
                    if (item.Nome.Length > 0) d.Itens.Add(item);
                }
            }

            JsonElement pagamentos;
            if (payload.TryGetProperty("pagamentos", out pagamentos) && pagamentos.ValueKind == JsonValueKind.Array)
            {
                int n = 0;
                foreach (JsonElement p in pagamentos.EnumerateArray())
                {
                    if (++n > 20) break;
                    if (p.ValueKind != JsonValueKind.Object) continue;
                    TicketPayment pay = new TicketPayment();
                    pay.Forma = Text(p, "forma", 40);
                    pay.Valor = Money(p, "valor") ?? string.Empty;
                    if (pay.Forma.Length > 0) d.Pagamentos.Add(pay);
                }
            }

            if (tipo == TicketKinds.PedidoBar && d.Itens.Count == 0)
            {
                error = "O pedido não tem itens para imprimir.";
                return false;
            }
            if (tipo == TicketKinds.RelatorioMesa && d.Itens.Count == 0)
            {
                error = "O relatório da mesa não tem itens para imprimir.";
                return false;
            }

            data = d;
            return true;
        }

        private static string Text(JsonElement obj, string name, int max)
        {
            JsonElement v;
            if (obj.ValueKind != JsonValueKind.Object || !obj.TryGetProperty(name, out v) || v.ValueKind != JsonValueKind.String) return string.Empty;
            // CleanText remove TODOS os caracteres de controle (inclui ESC, GS, LF): texto de produto nunca vira comando da impressora.
            return PrinterClassifier.CleanText(v.GetString(), max);
        }

        private static int? Int(JsonElement obj, string name)
        {
            JsonElement v;
            if (obj.ValueKind != JsonValueKind.Object || !obj.TryGetProperty(name, out v)) return null;
            if (v.ValueKind == JsonValueKind.Number)
            {
                int n;
                return v.TryGetInt32(out n) ? n : (int?)null;
            }
            if (v.ValueKind == JsonValueKind.String)
            {
                int parsed;
                if (int.TryParse(v.GetString(), NumberStyles.None, CultureInfo.InvariantCulture, out parsed)) return parsed;
            }
            return null;
        }

        private static bool TryDecimal(JsonElement obj, string name, out decimal value)
        {
            value = 0m;
            JsonElement v;
            if (obj.ValueKind != JsonValueKind.Object || !obj.TryGetProperty(name, out v)) return false;
            if (v.ValueKind == JsonValueKind.Number) return v.TryGetDecimal(out value);
            if (v.ValueKind == JsonValueKind.String)
            {
                string? s = v.GetString();
                return s != null && decimal.TryParse(s, NumberStyles.Number, CultureInfo.InvariantCulture, out value);
            }
            return false;
        }

        /// <summary>Quantidade: "2" ou "2,5" (sem zeros à direita).</summary>
        public static string Quantity(JsonElement obj, string name)
        {
            decimal q;
            if (!TryDecimal(obj, name, out q)) return string.Empty;
            return FormatQuantity(q);
        }

        public static string FormatQuantity(decimal q)
        {
            string s = q.ToString("0.####", CultureInfo.InvariantCulture); // sem zeros à direita
            return s.Replace('.', ',');
        }

        /// <summary>Valor monetário "1.234,50" (sem símbolo; null quando ausente).</summary>
        public static string? Money(JsonElement obj, string name)
        {
            decimal m;
            if (!TryDecimal(obj, name, out m)) return null;
            return FormatMoney(m);
        }

        public static string FormatMoney(decimal m)
        {
            bool negative = m < 0;
            decimal abs = Math.Abs(decimal.Round(m, 2, MidpointRounding.AwayFromZero));
            string fixedText = abs.ToString("0.00", CultureInfo.InvariantCulture); // 1234.50
            int dot = fixedText.IndexOf('.');
            string whole = fixedText.Substring(0, dot);
            string cents = fixedText.Substring(dot + 1);
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < whole.Length; i++)
            {
                if (i > 0 && (whole.Length - i) % 3 == 0) sb.Append('.');
                sb.Append(whole[i]);
            }
            return (negative ? "-" : string.Empty) + sb.ToString() + "," + cents;
        }
    }
}
