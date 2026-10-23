using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;
using System.Text.RegularExpressions;

namespace FlorestPrintAgent.Core.Jobs
{
    // Conversão apenas do texto produzido pelo TicketBuilder; não interpreta dados RAW externos.
    // Mantém comandos originais, corte e avanço final. GS v 0 exige impressora ESC/POS com raster.
    [SupportedOSPlatform("windows")]
    internal sealed class MontserratRaster : IDisposable
    {
        internal const float FontPixels = 24f * 1.10f;
        private static readonly object FontGate = new object();
        private static readonly Lazy<FontResources> SharedFonts = new Lazy<FontResources>(() => new FontResources());
        private readonly List<byte> _output = new List<byte>();
        private readonly TicketLayout _layout;
        private readonly Bitmap _measure = new Bitmap(1, 1);
        private readonly Graphics _graphics;
        private readonly StringFormat _format = (StringFormat)StringFormat.GenericTypographic.Clone();
        private readonly Action<string>? _observe;
        private readonly Action<string>? _observeRendered;
        private bool _bold, _wide, _tall, _reverse;
        private int _align;
        internal int PaperPixels => _layout.Columns * 12; // Font A: 32 colunas = 384 pontos; 48 = 576.

        private MontserratRaster(TicketLayout layout, Action<string>? observe, Action<string>? observeRendered)
        {
            _layout = layout;
            _observe = observe;
            _observeRendered = observeRendered;
            _graphics = Graphics.FromImage(_measure);
            _format.FormatFlags |= StringFormatFlags.MeasureTrailingSpaces | StringFormatFlags.NoWrap;
        }

        // As fontes privadas permanecem válidas durante toda a vida do processo, inclusive no serviço.
        // A coleção e a memória nunca são descartadas entre trabalhos concorrentes do GDI+.
        private sealed class FontResources
        {
            internal readonly PrivateFontCollection Fonts = new PrivateFontCollection();
            private readonly List<IntPtr> _memory = new List<IntPtr>();
            internal readonly FontFamily Family;
            internal FontResources()
            {
                try
                {
                    foreach (string name in new[] { "Montserrat-Regular.ttf", "Montserrat-Bold.ttf" })
                    {
                        using Stream source = Assembly.GetExecutingAssembly().GetManifestResourceStream(
                            "FlorestPrintAgent.Core.Jobs.Fonts." + name)
                            ?? throw new InvalidOperationException("Fonte incorporada ausente: " + name);
                        using MemoryStream buffer = new MemoryStream();
                        source.CopyTo(buffer);
                        byte[] bytes = buffer.ToArray();
                        IntPtr memory = Marshal.AllocCoTaskMem(bytes.Length);
                        _memory.Add(memory);
                        Marshal.Copy(bytes, 0, memory, bytes.Length);
                        Fonts.AddMemoryFont(memory, bytes.Length);
                    }
                    Family = Fonts.Families[0];
                    if (Family.Name != "Montserrat" || !Family.IsStyleAvailable(FontStyle.Regular) || !Family.IsStyleAvailable(FontStyle.Bold))
                        throw new InvalidOperationException("Montserrat incorporada indisponível; impressão cancelada sem substituir a fonte.");
                }
                catch
                {
                    Fonts.Dispose();
                    foreach (IntPtr memory in _memory) Marshal.FreeCoTaskMem(memory);
                    throw;
                }
            }
        }

        internal static byte[] Render(byte[] original, TicketLayout layout, Action<string>? observe = null, Action<string>? observeRendered = null)
        {
            lock (FontGate)
            {
                _ = SharedFonts.Value;
                using MontserratRaster r = new MontserratRaster(layout, observe, observeRendered);
                r.Convert(original);
                return r._output.ToArray();
            }
        }

        internal static List<string> WrapText(string text, string indent, TicketLayout layout, bool bold, bool wide)
        {
            lock (FontGate)
            {
                using MontserratRaster r = new MontserratRaster(layout, null, null);
                r._wide = wide;
                using Font font = new Font(SharedFonts.Value.Family, FontPixels,
                    bold ? FontStyle.Bold : FontStyle.Regular, GraphicsUnit.Pixel);
                string normalized = string.Join(" ", text.Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries));
                if (r.Width(indent, font) >= r.PaperPixels / 2f) indent = string.Empty;
                return r.Wrap(normalized, font, r.PaperPixels, indent);
            }
        }

        private void Convert(byte[] input)
        {
            // Encoding já registrado por EscPosText ao gerar o documento original.
            Encoding encoding = Encoding.GetEncoding(_layout.CodePage);
            List<byte> line = new List<byte>();
            for (int i = 0; i < input.Length;)
            {
                byte b = input[i];
                if (b == 0x1B || b == 0x1D)
                {
                    if (line.Count != 0) throw new InvalidOperationException("Comando inesperado no meio de uma linha.");
                    int length = b == 0x1B && input[i + 1] == 0x40 ? 2 :
                        b == 0x1D && input[i + 1] == 0x56 ? 4 : 3;
                    if (i + length > input.Length) throw new InvalidOperationException("Comando ESC/POS incompleto.");
                    byte command = input[i + 1];
                    if (b == 0x1B && command == 0x61) _align = input[i + 2];
                    else if (b == 0x1B && command == 0x45) _bold = input[i + 2] != 0;
                    else if (b == 0x1D && command == 0x42) _reverse = input[i + 2] != 0;
                    else if (b == 0x1D && command == 0x21)
                    { _wide = (input[i + 2] & 0x10) != 0; _tall = (input[i + 2] & 1) != 0; }
                    for (int k = 0; k < length; k++) _output.Add(input[i + k]);
                    i += length;
                }
                else if (b == 0x0A)
                {
                    if (line.Count == 0) _output.Add(b);
                    else PrintLine(encoding.GetString(line.ToArray()));
                    line.Clear();
                    i++;
                }
                else { line.Add(b); i++; }
            }
            if (line.Count != 0) throw new InvalidOperationException("Linha de impressão incompleta.");
        }

        private float Width(string text, Font font) =>
            _graphics.MeasureString(text, font, int.MaxValue, _format).Width * (_wide ? 2 : 1);

        private void PrintLine(string text)
        {
            _observe?.Invoke(text); // Usado apenas por testes offline de equivalência de conteúdo.
            using Font font = new Font(SharedFonts.Value.Family, FontPixels,
                _bold ? FontStyle.Bold : FontStyle.Regular, GraphicsUnit.Pixel);
            bool rule = text.Length > 1 && (text[0] == '-' || text[0] == '=') && text.Trim(text[0]).Length == 0;
            if (rule)
            {
                // Os mesmos separadores existentes, distribuídos na largura útil.
                Draw(text.Substring(0, 1), null, font, true);
                return;
            }
            // TwoColumns original usa dois ou mais espaços entre rótulo e valor. Recuos não são colunas.
            Match columns = Regex.Match(text, @"^(\s*\S.*?) {2,}(\S.*)$");
            if (columns.Success)
            {
                string left = columns.Groups[1].Value;
                string right = columns.Groups[2].Value;
                float available = PaperPixels - Width(right, font) - Width(" ", font);
                if (available > 0)
                {
                    List<string> wrapped = Wrap(left, font, available, string.Empty);
                    for (int n = 0; n < wrapped.Count - 1; n++) Draw(wrapped[n], null, font, false);
                    Draw(wrapped[wrapped.Count - 1], right, font, false);
                }
                else
                {
                    foreach (string part in Wrap(left, font, PaperPixels, string.Empty)) Draw(part, null, font, false);
                    foreach (string part in Wrap(right, font, PaperPixels, string.Empty)) Draw(part, null, font, false);
                }
                return;
            }
            int spaces = text.Length - text.TrimStart(' ').Length;
            string indent = new string(' ', spaces);
            foreach (string part in Wrap(text, font, PaperPixels, indent)) Draw(part, null, font, false);
        }

        // Mede a fonte real, incluindo negrito/largura dupla. Nunca corta caracteres para caber.
        private List<string> Wrap(string text, Font font, float width, string indent)
        {
            List<string> lines = new List<string>();
            string remaining = text;
            while (remaining.Length > 0)
            {
                if (Width(remaining, font) <= width) { lines.Add(remaining); break; }
                int fit = 0;
                foreach (Rune rune in remaining.EnumerateRunes())
                {
                    int next = fit + rune.Utf16SequenceLength;
                    if (Width(remaining.Substring(0, next), font) > width) break;
                    fit = next;
                }
                if (fit == 0) throw new InvalidOperationException("Largura insuficiente para Montserrat; impressão cancelada sem cortes.");
                int space = remaining.LastIndexOf(' ', Math.Min(fit, remaining.Length - 1));
                if (space > 0 && remaining.Substring(0, space).Trim().Length > 0) fit = space;
                lines.Add(remaining.Substring(0, fit).TrimEnd());
                remaining = remaining.Substring(fit).TrimStart();
                if (remaining.Length > 0 && Width(indent, font) < width / 2) remaining = indent + remaining;
            }
            if (lines.Count == 0) lines.Add(string.Empty);
            return lines;
        }

        private void Draw(string left, string? right, Font font, bool rule)
        {
            if (!rule)
            {
                float occupied = Width(left, font) + (right == null ? 0 : Width(" " + right, font));
                if (occupied > PaperPixels + 0.01f)
                    throw new InvalidOperationException("Texto Montserrat fora da largura útil; impressão cancelada sem cortes.");
                _observeRendered?.Invoke(left + (right == null ? string.Empty : " " + right));
            }
            int height = (int)Math.Ceiling(font.GetHeight(_graphics)) + 2;
            int sx = _wide ? 2 : 1, sy = _tall ? 2 : 1;
            int width = PaperPixels;
            using Bitmap bitmap = new Bitmap(width, height * sy, PixelFormat.Format32bppArgb);
            using (Graphics g = Graphics.FromImage(bitmap))
            {
                g.Clear(_reverse ? Color.Black : Color.White);
                g.TextRenderingHint = TextRenderingHint.SingleBitPerPixelGridFit;
                g.ScaleTransform(sx, sy);
                Brush ink = _reverse ? Brushes.White : Brushes.Black;
                if (rule)
                {
                    float step = Width(left, font) / sx;
                    for (float x = 0; x + step <= width / (float)sx; x += step)
                        g.DrawString(left, font, ink, x, 1, _format);
                }
                else
                {
                    float x = right != null || _align == 0 ? 0 :
                        (_align == 1 ? (width - Width(left, font)) / 2 : width - Width(left, font));
                    g.DrawString(left, font, ink, x / sx, 1, _format);
                    if (right != null) g.DrawString(right, font, ink, (width - Width(right, font)) / sx, 1, _format);
                }
            }
            int stride = (width + 7) / 8;
            int rows = bitmap.Height;
            _output.AddRange(new byte[] { 0x1D, 0x76, 0x30, 0, (byte)stride, (byte)(stride >> 8), (byte)rows, (byte)(rows >> 8) });
            // Pixels gráficos já contêm negrito, reverso e as duas escalas. GS v 0 avança sua própria altura.
            BitmapData data = bitmap.LockBits(new Rectangle(0, 0, width, rows), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            try
            {
                byte[] pixels = new byte[data.Stride * rows];
                Marshal.Copy(data.Scan0, pixels, 0, pixels.Length);
                for (int y = 0; y < rows; y++)
                    for (int xb = 0; xb < stride; xb++)
                    {
                        byte value = 0;
                        for (int bit = 0; bit < 8; bit++)
                        {
                            int x = xb * 8 + bit;
                            if (x < width && pixels[y * data.Stride + x * 4] < 128) value |= (byte)(0x80 >> bit);
                        }
                        _output.Add(value);
                    }
            }
            finally { bitmap.UnlockBits(data); }
        }

        public void Dispose()
        {
            _graphics.Dispose();
            _measure.Dispose();
            _format.Dispose();
        }
    }
}
