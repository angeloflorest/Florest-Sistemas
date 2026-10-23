using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Runtime.Versioning;
using System.Text;
using System.Text.RegularExpressions;
using FlorestPrintAgent.Core.Jobs;
using Xunit;

namespace FlorestPrintAgent.Tests
{
    public class MontserratPrintTests
    {
        public static IEnumerable<object[]> Cases()
        {
            foreach (string kind in new[] { "cozinha", "bar", "recibo", "relatorio_mesa", "teste" })
                foreach (int columns in new[] { 32, 48 })
                    foreach (bool cut in new[] { false, true }) yield return new object[] { kind, columns, cut };
        }

        [Theory]
        [MemberData(nameof(Cases))]
        public void RasterPreservesEveryOriginalLineAndHardwareCommand(string kind, int columns, bool cut)
        {
            if (!OperatingSystem.IsWindows()) return;
            TicketData ticket = Sample(kind);
            TicketLayout layout = new TicketLayout { Columns = columns, Cut = cut };
            byte[] logical = TicketBuilder.BuildText(ticket, layout);
            List<string> observed = new List<string>();
            List<string> rendered = new List<string>();
            byte[] measured = TicketBuilder.BuildText(ticket, layout, true);
            byte[] raster = MontserratRaster.Render(measured, layout, observed.Add, rendered.Add);
            List<string> expected = new List<string>();
            List<byte> textControls = Controls(logical, false, expected, layout);
            List<byte> rasterControls = Controls(raster, true, null, layout);
            string Characters(IEnumerable<string> lines) => Regex.Replace(string.Concat(lines.Where(l => !Regex.IsMatch(l, @"^[-=]+$"))), @"\s", string.Empty);
            Assert.Equal(Characters(expected), Characters(observed));
            Assert.Equal(Characters(expected), Characters(rendered));
            Assert.Equal(textControls, rasterControls);
            Assert.Equal(new byte[] { 0x1B, 0x40, 0x1B, 0x74, 3 }, raster.Take(5));
            Assert.Equal(cut, raster.TakeLast(4).SequenceEqual(new byte[] { 0x1D, 0x56, 0x42, 0 }));
            Assert.Equal(raster, TicketBuilder.Build(ticket, layout));
            string all = string.Join("\n", observed);
            Assert.DoesNotContain("999999", all);
            if (kind == "cozinha" || kind == "bar")
            {
                Assert.Contains("3x", all);
                Assert.Contains("OBS:", all);
                Assert.DoesNotContain("R$", all);
            }
            if (kind == "recibo" || kind == "relatorio_mesa") Assert.Contains("1.234,50", all);
            string? preview = Environment.GetEnvironmentVariable("FLOREST_FONT_PREVIEWS");
            if (cut && preview != null) SavePreview(raster, Path.Combine(preview, kind + "-" + columns + "col.png"));
        }

        [Fact]
        public void SizeIsTenPercentAboveThe24DotFontABaseline()
        {
            if (!OperatingSystem.IsWindows()) return;
            Assert.Equal(26.4f, MontserratRaster.FontPixels, 3);
        }

        [Fact]
        public void BoldReverseDoubleHeightAndDoubleWidthAreActuallyRendered()
        {
            if (!OperatingSystem.IsWindows()) return;
            byte[] Render(params byte[] style) => MontserratRaster.Render(
                style.Concat(Encoding.ASCII.GetBytes("Montserrat 123\n")).ToArray(), new TicketLayout());
            byte[] normal = Render();
            byte[] bold = Render(0x1B, 0x45, 1);
            byte[] reverse = Render(0x1D, 0x42, 1);
            byte[] tall = Render(0x1D, 0x21, 1);
            byte[] wide = Render(0x1D, 0x21, 0x10);
            static int Ink(byte[] b, int skip) => b.Skip(skip).Sum(v => System.Numerics.BitOperations.PopCount((uint)v));
            Assert.True(Ink(bold, 11) > Ink(normal, 8), "O negrito precisa ter mais pontos pretos.");
            Assert.True(Ink(reverse, 11) > Ink(normal, 8) * 3, "O reverso precisa de fundo preto.");
            Assert.Equal((normal[6] + 256 * normal[7]) * 2, tall[9] + 256 * tall[10]);
            Assert.True(Ink(wide, 11) > Ink(normal, 8) * 1.5, "A largura dupla deve ampliar os glifos.");
        }

        private static TicketData Sample(string kind)
        {
            return new TicketData
            {
                Tipo = kind == "cozinha" || kind == "bar" ? TicketKinds.PedidoBar : kind,
                Setor = kind == "cozinha" ? "COZINHA" : kind == "bar" ? "BAR" : "CAIXA",
                Empresa = "Restaurante São João", Mesa = 41, Pedido = 999999, Venda = 77,
                DataHora = "18/10/2026 20:40", Subtotal = "1.234,50", Total = "1.234,50",
                Desconto = "0,00", JaPago = "20,00", FaltaPagar = "1.214,50",
                Itens = new List<TicketItem>
                {
                    new TicketItem { Quantidade = "3", Nome = kind == "bar" ? "Água com gás e limão" : "Porção de frango à parmegiana",
                        PrecoUnitario = "12,00", Subtotal = "36,00",
                        Observacao = "Sem cebola, sem pimenta; molho separado. Atenção: entregar os três produtos juntos na mesa e confirmar a preferência do cliente.",
                        Filhos = new List<TicketChild> { new TicketChild { Quantidade = "2", Nome = "Queijo", Grupo = "Adicionais" } } },
                    new TicketItem { Quantidade = "1,5", Nome = "Açaí, açúcar, maçã e café", PrecoUnitario = "15,50", Subtotal = "23,25" },
                    new TicketItem { Quantidade = "2", Nome = "WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW", PrecoUnitario = "5,00", Subtotal = "10,00" }
                },
                Pagamentos = new List<TicketPayment> { new TicketPayment { Forma = "Cartão de crédito", Valor = "1.234,50" } }
            };
        }

        // Parser independente: ignora exclusivamente payloads raster, compara todos os comandos originais
        // e os avanços em branco. Um LF textual é substituído pelo avanço implícito de GS v 0.
        private static List<byte> Controls(byte[] bytes, bool raster, List<string>? lines, TicketLayout layout)
        {
            List<byte> commands = new List<byte>();
            List<byte> line = new List<byte>();
            int images = 0;
            for (int i = 0; i < bytes.Length;)
            {
                if (bytes[i] == 0x1D && bytes[i + 1] == 0x76)
                {
                    Assert.True(raster);
                    Assert.Equal(0x30, bytes[i + 2]);
                    Assert.Equal(0, bytes[i + 3]);
                    int width = bytes[i + 4] + 256 * bytes[i + 5];
                    int height = bytes[i + 6] + 256 * bytes[i + 7];
                    Assert.Equal(layout.Columns * 12, width * 8);
                    Assert.InRange(height, 24, 100);
                    Assert.True(i + 8 + width * height <= bytes.Length);
                    Assert.Contains(bytes.Skip(i + 8).Take(width * height), b => b != 0);
                    images++;
                    i += 8 + width * height;
                }
                else if (bytes[i] == 0x1B || bytes[i] == 0x1D)
                {
                    int n = bytes[i] == 0x1B && bytes[i + 1] == 0x40 ? 2 :
                        bytes[i] == 0x1D && bytes[i + 1] == 0x56 ? 4 : 3;
                    commands.AddRange(bytes.Skip(i).Take(n));
                    i += n;
                }
                else if (bytes[i] == 10)
                {
                    if (line.Count == 0) commands.Add(10);
                    else lines?.Add(Encoding.GetEncoding(layout.CodePage).GetString(line.ToArray()));
                    line.Clear();
                    i++;
                }
                else { Assert.False(raster, "Texto cru inesperado no documento Montserrat."); line.Add(bytes[i++]); }
            }
            if (raster) Assert.True(images > 0);
            return commands;
        }

        [SupportedOSPlatform("windows")]
        private static void SavePreview(byte[] data, string path)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            List<(int Width, int Height, byte[] Pixels)> images = new List<(int, int, byte[])>();
            int paperWidth = 0;
            for (int i = 0; i < data.Length;)
            {
                if (data[i] == 0x1D && data[i + 1] == 0x76)
                {
                    int stride = data[i + 4] + 256 * data[i + 5], height = data[i + 6] + 256 * data[i + 7];
                    images.Add((stride * 8, height, data.Skip(i + 8).Take(stride * height).ToArray()));
                    paperWidth = stride * 8;
                    i += 8 + stride * height;
                }
                else if (data[i] == 0x1B || data[i] == 0x1D)
                    i += data[i] == 0x1B && data[i + 1] == 0x40 ? 2 : data[i] == 0x1D && data[i + 1] == 0x56 ? 4 : 3;
                else { if (paperWidth > 0) images.Add((paperWidth, 30, new byte[paperWidth / 8 * 30])); i++; }
            }
            using Bitmap bmp = new Bitmap(paperWidth, images.Sum(p => p.Height));
            using (Graphics g = Graphics.FromImage(bmp)) g.Clear(Color.White);
            int y0 = 0;
            foreach (var image in images)
            {
                for (int y = 0; y < image.Height; y++)
                    for (int x = 0; x < image.Width; x++)
                        if ((image.Pixels[y * (image.Width / 8) + x / 8] & (0x80 >> (x % 8))) != 0) bmp.SetPixel(x, y0 + y, Color.Black);
                y0 += image.Height;
            }
            bmp.Save(path, ImageFormat.Png);
        }
    }
}
