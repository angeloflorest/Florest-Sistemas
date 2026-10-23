using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using FlorestPrintAgent.Core;
using FlorestPrintAgent.Core.Jobs;
using FlorestPrintAgent.Tests.TestSupport;
using Xunit;

namespace FlorestPrintAgent.Tests
{
    public class TicketTests
    {
        internal static JsonElement Json(string json)
        {
            using (JsonDocument doc = JsonDocument.Parse(json))
            {
                return doc.RootElement.Clone();
            }
        }

        internal const string KitchenOrder =
            "{\"versao\":1,\"tipo\":\"pedido_bar\",\"empresa\":\"Restaurante Nova Ponte\",\"setor\":\"COZINHA\",\"mesa\":5,\"pedido\":123," +
            "\"data_hora\":\"05/10/2026 14:32\",\"itens\":[" +
            "{\"quantidade\":2,\"nome\":\"X-Burger\",\"observacao\":\"sem cebola\",\"preco_unitario\":10.5,\"subtotal\":21," +
            " \"filhos\":[{\"quantidade\":1,\"nome\":\"Bacon\",\"grupo\":\"Adicionais\"}]}," +
            "{\"quantidade\":1.5,\"nome\":\"Porção de Fritas\"}]}";

        private static TicketData Parse(string json, string type)
        {
            TicketData? data;
            string error;
            Assert.True(TicketParser.TryParse(type, Json(json), out data, out error), error);
            return data!;
        }

        private static string Text(byte[] bytes)
        {
            return Encoding.Latin1.GetString(bytes);
        }

        // ------------------------------------------------------------------ parser

        [Fact]
        public void ParsesKitchenOrder()
        {
            TicketData d = Parse(KitchenOrder, "pedido_bar");
            Assert.Equal("COZINHA", d.Setor);
            Assert.Equal(123, d.Pedido);
            Assert.Equal(5, d.Mesa);
            Assert.Equal(2, d.Itens.Count);
            Assert.Equal("2", d.Itens[0].Quantidade);
            Assert.Equal("X-Burger", d.Itens[0].Nome);
            Assert.Equal("sem cebola", d.Itens[0].Observacao);
            Assert.Equal("Bacon", d.Itens[0].Filhos.Single().Nome);
            Assert.Equal("1,5", d.Itens[1].Quantidade);
        }

        [Fact]
        public void ParserRemovesControlCharactersSoProductNamesNeverBecomePrinterCommands()
        {
            string json = "{\"tipo\":\"pedido_bar\",\"setor\":\"BAR\",\"itens\":[{\"quantidade\":1,\"nome\":\"Cerveja\\u001b@\\u001dV\\u0000\\nX\"}]}";
            TicketData d = Parse(json, "pedido_bar");
            Assert.DoesNotContain(d.Itens[0].Nome, c => c < ' ');
        }

        [Fact]
        public void OrderWithoutItemsIsRejected()
        {
            TicketData? data;
            string error;
            Assert.False(TicketParser.TryParse("pedido_bar", Json("{\"tipo\":\"pedido_bar\",\"setor\":\"BAR\",\"itens\":[]}"), out data, out error));
            Assert.NotEmpty(error);
        }

        [Fact]
        public void UnknownTypeAndNonObjectPayloadAreRejected()
        {
            TicketData? data;
            string error;
            Assert.False(TicketParser.TryParse("x", Json("{\"tipo\":\"hack\"}"), out data, out error));
            Assert.False(TicketParser.TryParse("pedido_bar", Json("[1,2]"), out data, out error));
        }

        [Fact]
        public void TypeFallsBackToJobTypeWhenPayloadHasNone()
        {
            TicketData d = Parse("{\"setor\":\"BAR\",\"itens\":[{\"quantidade\":1,\"nome\":\"Chopp\"}]}", "pedido_bar");
            Assert.Equal(TicketKinds.PedidoBar, d.Tipo);
        }

        [Fact]
        public void NumbersAsStringsAreAccepted()
        {
            TicketData d = Parse("{\"tipo\":\"pedido_bar\",\"mesa\":\"7\",\"pedido\":\"9\",\"itens\":[{\"quantidade\":\"2\",\"nome\":\"Suco\"}]}", "pedido_bar");
            Assert.Equal(7, d.Mesa);
            Assert.Equal(9, d.Pedido);
            Assert.Equal("2", d.Itens[0].Quantidade);
        }

        [Fact]
        public void MoneyIsFormattedInBrazilianStyle()
        {
            Assert.Equal("1.234,50", TicketParser.FormatMoney(1234.5m));
            Assert.Equal("0,00", TicketParser.FormatMoney(0m));
            Assert.Equal("10,00", TicketParser.FormatMoney(10m));
        }

        // ------------------------------------------------------------------ builder

        [Fact]
        public void KitchenTicketHasAllRequiredContentAndNoPrice()
        {
            TicketData d = Parse(KitchenOrder, "pedido_bar");
            byte[] bytes = TicketBuilder.BuildText(d, TicketLayout.Default());
            string t = Text(bytes);

            Assert.Contains("Restaurante Nova Ponte", t, StringComparison.Ordinal);
            Assert.Contains("MESA 5", t, StringComparison.Ordinal);
            Assert.DoesNotContain("PEDIDO", t, StringComparison.Ordinal);
            Assert.DoesNotContain("123", t, StringComparison.Ordinal);
            Assert.Contains("*** COZINHA ***", t, StringComparison.Ordinal);
            Assert.Contains("05/10/2026 14:32", t, StringComparison.Ordinal);
            Assert.Contains("2x X-Burger", t, StringComparison.Ordinal);
            Assert.Contains("> 1x Bacon (Adicionais)", t, StringComparison.Ordinal);
            Assert.Contains("OBS: sem cebola", t, StringComparison.Ordinal);
            Assert.Contains("1,5x Por", t, StringComparison.Ordinal);

            // jamais preço, mesmo que o servidor mande
            Assert.DoesNotContain("10,50", t, StringComparison.Ordinal);
            Assert.DoesNotContain("21,00", t, StringComparison.Ordinal);
            Assert.DoesNotContain("R$", t, StringComparison.Ordinal);
        }

        [Fact]
        public void TableNumberAppearsAgainAtTheEnd()
        {
            TicketData d = Parse(KitchenOrder, "pedido_bar");
            string t = Text(TicketBuilder.BuildText(d, TicketLayout.Default()));
            int first = t.IndexOf("MESA 5", StringComparison.Ordinal);
            int last = t.LastIndexOf("MESA 5", StringComparison.Ordinal);
            Assert.True(last > first);
            Assert.True(last > t.IndexOf("Fritas", StringComparison.Ordinal) || last > t.IndexOf("Por", StringComparison.Ordinal));
        }

        [Fact]
        public void TicketStartsWithInitAndCodePageAndEndsWithPartialCut()
        {
            byte[] bytes = TicketBuilder.BuildText(Parse(KitchenOrder, "pedido_bar"), TicketLayout.Default());
            Assert.Equal(new byte[] { 0x1B, 0x40, 0x1B, 0x74, 0x03 }, bytes.Take(5).ToArray());
            Assert.Equal(new byte[] { 0x1D, 0x56, 0x42, 0x00 }, bytes.Skip(bytes.Length - 4).ToArray());
        }

        [Fact]
        public void CutCanBeDisabled()
        {
            TicketLayout l = TicketLayout.Default();
            l.Cut = false;
            byte[] bytes = TicketBuilder.BuildText(Parse(KitchenOrder, "pedido_bar"), l);
            Assert.NotEqual(new byte[] { 0x1D, 0x56, 0x42, 0x00 }, bytes.Skip(bytes.Length - 4).ToArray());
        }

        [Fact]
        public void AccentsUseTheConfiguredCodePage()
        {
            TicketData d = Parse("{\"tipo\":\"pedido_bar\",\"setor\":\"COZINHA\",\"itens\":[{\"quantidade\":1,\"nome\":\"Pão ção\"}]}", "pedido_bar");
            byte[] bytes = TicketBuilder.BuildText(d, TicketLayout.Default());
            // CP860: ã = 0x84, ç = 0x87
            Assert.Contains((byte)0x84, bytes);
            Assert.Contains((byte)0x87, bytes);
        }

        [Fact]
        public void ReceiptIsMarkedNotFiscalAndShowsPricesAndPayments()
        {
            string json = "{\"tipo\":\"recibo\",\"empresa\":\"Loja X\",\"setor\":\"CAIXA\",\"venda\":77,\"data_hora\":\"05/10/2026 15:00\"," +
                "\"itens\":[{\"quantidade\":2,\"nome\":\"Coca\",\"preco_unitario\":6,\"subtotal\":12}],\"total\":1234.5," +
                "\"pagamentos\":[{\"forma\":\"Dinheiro\",\"valor\":1234.5}]}";
            string t = Text(TicketBuilder.BuildText(Parse(json, "recibo"), TicketLayout.Default()));
            Assert.Contains("NAO E DOCUMENTO FISCAL", t, StringComparison.Ordinal);
            Assert.Contains("1.234,50", t, StringComparison.Ordinal);
            Assert.Contains("Dinheiro", t, StringComparison.Ordinal);
            Assert.Contains("12,00", t, StringComparison.Ordinal);
        }

        [Fact]
        public void TestTicketSaysItIsATest()
        {
            string t = Text(TicketBuilder.BuildText(Parse("{\"tipo\":\"teste\",\"empresa\":\"Loja\",\"setor\":\"BAR\"}", "teste"), TicketLayout.Default()));
            Assert.Contains("TESTE DE IMPRESSAO", t, StringComparison.Ordinal);
            Assert.Contains("BAR", t, StringComparison.Ordinal);
        }

        // ------------------------------------------------------------------ 1.2.0: cupom da cozinha sem número do pedido

        private static int IndexOf(byte[] hay, byte[] needle, int from)
        {
            for (int i = from; i <= hay.Length - needle.Length; i++)
            {
                bool ok = true;
                for (int k = 0; k < needle.Length; k++) { if (hay[i + k] != needle[k]) { ok = false; break; } }
                if (ok) return i;
            }
            return -1;
        }

        [Fact]
        public void KitchenTicketOnlyShowsTheTableNumberInHeaderAndFooter()
        {
            string t = Text(TicketBuilder.BuildText(Parse(KitchenOrder, "pedido_bar"), TicketLayout.Default()));
            Assert.DoesNotContain("PEDIDO", t, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain("123", t, StringComparison.Ordinal);
            int first = t.IndexOf("MESA 5", StringComparison.Ordinal);
            int last = t.LastIndexOf("MESA 5", StringComparison.Ordinal);
            Assert.True(first >= 0 && last > first, "MESA deve aparecer no cabeçalho e no rodapé");
        }

        [Fact]
        public void KitchenTicketWithoutOrderNumberInThePayloadAlsoWorks()
        {
            string json = "{\"tipo\":\"pedido_bar\",\"empresa\":\"Loja\",\"setor\":\"BAR\",\"mesa\":41,\"itens\":[{\"quantidade\":1,\"nome\":\"Chopp\"}]}";
            string t = Text(TicketBuilder.BuildText(Parse(json, "pedido_bar"), TicketLayout.Default()));
            Assert.Contains("MESA 41", t, StringComparison.Ordinal);
            Assert.DoesNotContain("PEDIDO", t, StringComparison.OrdinalIgnoreCase);
        }

        [Fact]
        public void ItemObservationIsBoldReverseAndDoubleHeight()
        {
            byte[] bytes = TicketBuilder.BuildText(Parse(KitchenOrder, "pedido_bar"), TicketLayout.Default());
            int obs = IndexOf(bytes, Encoding.ASCII.GetBytes("OBS: sem cebola"), 0);
            Assert.True(obs > 0);
            // imediatamente antes do texto: GS B 1 (reverso) ... ESC E 1 (negrito) ... GS ! 0x01 (dupla altura)
            byte[] before = bytes.Skip(Math.Max(0, obs - 12)).Take(Math.Min(12, obs)).ToArray();
            Assert.True(IndexOf(before, new byte[] { 0x1D, 0x42, 0x01 }, 0) >= 0, "vídeo reverso ligado");
            Assert.True(IndexOf(before, new byte[] { 0x1B, 0x45, 0x01 }, 0) >= 0, "negrito ligado");
            Assert.True(IndexOf(before, new byte[] { 0x1D, 0x21, 0x01 }, 0) >= 0, "dupla altura ligada");
            // e tudo é desligado depois da observação
            int after = obs + "OBS: sem cebola".Length;
            Assert.True(IndexOf(bytes, new byte[] { 0x1D, 0x21, 0x00 }, after) > after);
            Assert.True(IndexOf(bytes, new byte[] { 0x1D, 0x42, 0x00 }, after) > after);
        }

        // ------------------------------------------------------------------ 1.2.0: relatório da mesa

        internal const string TableReport =
            "{\"versao\":1,\"tipo\":\"relatorio_mesa\",\"empresa\":\"RESTAURANTE NOVA PONTE\",\"setor\":\"CAIXA\",\"mesa\":41," +
            "\"data_hora\":\"16/10/2026 20:40\",\"itens\":[" +
            "{\"quantidade\":2,\"nome\":\"Espeto de Carne\",\"preco_unitario\":12,\"subtotal\":24,\"observacao\":\"ao ponto\"}," +
            "{\"quantidade\":3,\"nome\":\"Cerveja 600ml\",\"preco_unitario\":10,\"subtotal\":30}]," +
            "\"subtotal\":54,\"desconto\":4,\"acrescimo\":0,\"taxa_servico\":0,\"total\":50,\"ja_pago\":20,\"falta_pagar\":30}";

        [Fact]
        public void TableReportParsesAndIsAcceptedAsAKnownType()
        {
            TicketData d = Parse(TableReport, "relatorio_mesa");
            Assert.Equal(TicketKinds.RelatorioMesa, d.Tipo);
            Assert.Equal(41, d.Mesa);
            Assert.Equal("50,00", d.Total);
            Assert.Equal("20,00", d.JaPago);
            Assert.Equal("30,00", d.FaltaPagar);
        }

        [Fact]
        public void TableReportWithoutItemsIsRefused()
        {
            TicketData? data;
            string error;
            Assert.False(TicketParser.TryParse("relatorio_mesa", Json("{\"tipo\":\"relatorio_mesa\",\"mesa\":1,\"itens\":[]}"), out data, out error));
            Assert.NotEmpty(error);
        }

        [Fact]
        public void TableReportShowsEverythingTheCashierNeedsAndIsNotFiscal()
        {
            string t = Text(TicketBuilder.BuildText(Parse(TableReport, "relatorio_mesa"), TicketLayout.Default()));
            Assert.Contains("RESTAURANTE NOVA PONTE", t, StringComparison.Ordinal);
            Assert.Contains("MESA 41", t, StringComparison.Ordinal);
            Assert.Contains("16/10/2026 20:40", t, StringComparison.Ordinal);
            Assert.Contains("Espeto de Carne", t, StringComparison.Ordinal);
            Assert.Contains("2 x 12,00", t, StringComparison.Ordinal);
            Assert.Contains("24,00", t, StringComparison.Ordinal);
            Assert.Contains("OBS: ao ponto", t, StringComparison.Ordinal);
            Assert.Contains("Subtotal", t, StringComparison.Ordinal);
            Assert.Contains("54,00", t, StringComparison.Ordinal);
            Assert.Contains("Desconto", t, StringComparison.Ordinal);
            Assert.Contains("-4,00", t, StringComparison.Ordinal);
            Assert.Contains("TOTAL DA MESA R$", t, StringComparison.Ordinal);
            Assert.Contains("50,00", t, StringComparison.Ordinal);
            // nada de recibo / pagamento / pedido
            Assert.DoesNotContain("PEDIDO", t, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain("Obrigado", t, StringComparison.Ordinal);
            Assert.DoesNotContain("RECIBO", t, StringComparison.Ordinal);
            // rodapé exato (CP860: Ó = 0x99? conferido pela página de código abaixo)
            byte[] bytes = TicketBuilder.BuildText(Parse(TableReport, "relatorio_mesa"), TicketLayout.Default());
            byte[] footer = EscPosText.Encode(TicketBuilder.TableReportFooter, 860);
            Assert.True(IndexOf(bytes, footer, 0) > 0, "rodapé RELATÓRIO DA MESA - NÃO É DOCUMENTO FISCAL");
            Assert.Equal("RELATÓRIO DA MESA - NÃO É DOCUMENTO FISCAL", TicketBuilder.TableReportFooter);
        }

        [Fact]
        public void TableReportHidesZeroAdjustmentsAndAlwaysShowsTotal()
        {
            string json = "{\"tipo\":\"relatorio_mesa\",\"empresa\":\"Loja\",\"mesa\":3,\"itens\":[{\"quantidade\":1,\"nome\":\"Chopp\",\"preco_unitario\":9,\"subtotal\":9}]," +
                "\"subtotal\":9,\"desconto\":0,\"acrescimo\":0,\"taxa_servico\":0,\"total\":9}";
            string t = Text(TicketBuilder.BuildText(Parse(json, "relatorio_mesa"), TicketLayout.Default()));
            Assert.DoesNotContain("Desconto", t, StringComparison.Ordinal);
            Assert.DoesNotContain("Subtotal", t, StringComparison.Ordinal);
            Assert.DoesNotContain("Falta pagar", t, StringComparison.Ordinal);
            Assert.Contains("TOTAL DA MESA R$", t, StringComparison.Ordinal);
        }

        [Fact]
        public void TableReportNeverTreatsServerTextAsPrinterCommands()
        {
            string json = "{\"tipo\":\"relatorio_mesa\",\"mesa\":3,\"itens\":[{\"quantidade\":1,\"nome\":\"Chopp\",\"observacao\":\"a\\u001bb\\u001d!\\u0011c\",\"preco_unitario\":9,\"subtotal\":9}],\"total\":9}";
            byte[] bytes = TicketBuilder.BuildText(Parse(json, "relatorio_mesa"), TicketLayout.Default());
            Assert.True(IndexOf(bytes, Encoding.ASCII.GetBytes("OBS: ab!c"), 0) > 0);
        }

        [Fact]
        public void UnknownTicketTypeIsStillRefused()
        {
            TicketData? data;
            string error;
            Assert.False(TicketParser.TryParse("outro_tipo", Json("{\"tipo\":\"outro_tipo\"}"), out data, out error));
        }

        [Fact]
        public void DashesFallBackToHyphenInsteadOfQuestionMark()
        {
            byte[] b = EscPosText.Encode("A \u2014 B \u2013 C", 860);
            Assert.Equal("A - B - C", Encoding.ASCII.GetString(b));
        }

        // ------------------------------------------------------------------ quebra de linha

        [Theory]
        [InlineData("Hamburguer artesanal com queijo cheddar e bacon crocante", 20, "")]
        [InlineData("Hamburguer artesanal com queijo cheddar e bacon crocante", 20, "  ")]
        [InlineData("SUPERCALIFRAGILISTICEXPIALIDOCIOUS palavra gigante", 10, "  ")]
        [InlineData("a b c d e f g h i j k l m n o p", 8, "      ")]   // recuo maior que a metade da largura: é descartado
        [InlineData("x", 8, "")]
        public void WrapNeverExceedsWidthAndKeepsAllText(string text, int width, string indent)
        {
            var lines = EscPosWriter.Wrap(text, width, indent);
            Assert.All(lines, l => Assert.True(l.Length <= width, "linha longa: [" + l + "]"));
            string rebuilt = string.Concat(lines.Select(l => l.Trim())).Replace(" ", string.Empty);
            Assert.Equal(text.Replace(" ", string.Empty), rebuilt);
        }

        [Fact]
        public void WrapContinuationLinesAreIndented()
        {
            var lines = EscPosWriter.Wrap("um dois tres quatro cinco seis", 12, "  ");
            Assert.True(lines.Count > 1);
            Assert.False(lines[0].StartsWith(" ", StringComparison.Ordinal));
            Assert.All(lines.Skip(1), l => Assert.StartsWith("  ", l, StringComparison.Ordinal));
        }

        [Fact]
        public void WrapEmptyTextGivesOneEmptyLine()
        {
            Assert.Equal(new[] { string.Empty }, EscPosWriter.Wrap(string.Empty, 20, string.Empty).ToArray());
        }

        // ------------------------------------------------------------------ layout opcional

        [Fact]
        public void LayoutDefaultsWhenFileIsMissingOrInvalid()
        {
            using (TempDir dir = new TempDir())
            {
                TicketLayout missing = TicketLayoutSettings.Load(dir.File("nao-existe.json"), "COZINHA");
                Assert.Equal(AgentConstants.DefaultTicketColumns, missing.Columns);

                File.WriteAllText(dir.File("ruim.json"), "{ isto não é json");
                TicketLayout bad = TicketLayoutSettings.Load(dir.File("ruim.json"), "COZINHA");
                Assert.Equal(AgentConstants.DefaultTicketColumns, bad.Columns);
                Assert.Equal(860, bad.CodePage);
                Assert.True(bad.Cut);
            }
        }

        [Fact]
        public void LayoutPerPrinterOverridesGlobalAndIsClamped()
        {
            using (TempDir dir = new TempDir())
            {
                File.WriteAllText(dir.File("impressao.json"),
                    "{\"colunas\":42,\"impressoras\":{\"cozinha\":{\"colunas\":32,\"pagina_codigo\":850,\"cortar\":false},\"Bar\":{\"colunas\":5}}}");
                TicketLayout kitchen = TicketLayoutSettings.Load(dir.File("impressao.json"), "COZINHA");
                Assert.Equal(32, kitchen.Columns);
                Assert.Equal(850, kitchen.CodePage);
                Assert.False(kitchen.Cut);

                TicketLayout other = TicketLayoutSettings.Load(dir.File("impressao.json"), "Caixa");
                Assert.Equal(42, other.Columns);

                TicketLayout bar = TicketLayoutSettings.Load(dir.File("impressao.json"), "Bar");
                Assert.Equal(AgentConstants.MinTicketColumns, bar.Columns);
            }
        }

        [Fact]
        public void UnsupportedCodePageFallsBackTo860()
        {
            TicketLayout l = new TicketLayout();
            l.CodePage = 99999;
            Assert.Equal(860, l.Normalized().CodePage);
        }
    }
}
