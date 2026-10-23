using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;

namespace FlorestPrintAgent.Core.Jobs
{
    /// <summary>Largura e codificação do papel. Padrão: bobina de 80 mm (48 colunas), página de código 860 (Português), com corte.</summary>
    public sealed class TicketLayout
    {
        public int Columns { get; set; } = AgentConstants.DefaultTicketColumns;
        /// <summary>437, 850, 860 ou 1252.</summary>
        public int CodePage { get; set; } = 860;
        public bool Cut { get; set; } = true;
        public int FeedLines { get; set; } = 4;

        public static TicketLayout Default()
        {
            return new TicketLayout();
        }

        /// <summary>Número do comando ESC t n para a página de código.</summary>
        public static int EscTCode(int codePage)
        {
            switch (codePage)
            {
                case 437: return 0;
                case 850: return 2;
                case 860: return 3;
                case 1252: return 16;
                default: return 3;
            }
        }

        public static bool IsSupportedCodePage(int codePage)
        {
            return codePage == 437 || codePage == 850 || codePage == 860 || codePage == 1252;
        }

        public TicketLayout Normalized()
        {
            TicketLayout l = new TicketLayout();
            l.Columns = Math.Max(AgentConstants.MinTicketColumns, Math.Min(AgentConstants.MaxTicketColumns, Columns));
            l.CodePage = IsSupportedCodePage(CodePage) ? CodePage : 860;
            l.Cut = Cut;
            l.FeedLines = Math.Max(0, Math.Min(12, FeedLines));
            return l;
        }
    }

    /// <summary>
    /// Ajustes OPCIONAIS do ticket, em impressao.json (pasta de dados do agente; só Administradores gravam). Exemplo:
    /// { "colunas": 48, "pagina_codigo": 860, "cortar": true,
    ///   "impressoras": { "COZINHA": { "colunas": 32 }, "Bar 58mm": { "colunas": 32, "pagina_codigo": 850, "cortar": false } } }
    /// Arquivo ausente ou inválido = padrões (nunca impede de imprimir).
    /// </summary>
    public static class TicketLayoutSettings
    {
        public static TicketLayout Load(string? path, string printerName)
        {
            TicketLayout layout = TicketLayout.Default();
            if (string.IsNullOrEmpty(path)) return layout;
            try
            {
                if (!File.Exists(path)) return layout;
                FileInfo info = new FileInfo(path);
                if (info.Length > 64 * 1024) return layout;
                using (JsonDocument doc = JsonDocument.Parse(File.ReadAllBytes(path)))
                {
                    JsonElement root = doc.RootElement;
                    if (root.ValueKind != JsonValueKind.Object) return layout;
                    Apply(root, layout);

                    JsonElement printers;
                    if (root.TryGetProperty("impressoras", out printers) && printers.ValueKind == JsonValueKind.Object)
                    {
                        foreach (JsonProperty prop in printers.EnumerateObject())
                        {
                            if (string.Equals(prop.Name.Trim(), printerName.Trim(), StringComparison.OrdinalIgnoreCase) && prop.Value.ValueKind == JsonValueKind.Object)
                            {
                                Apply(prop.Value, layout);
                                break;
                            }
                        }
                    }
                }
            }
            catch (Exception ex) when (ex is IOException || ex is JsonException || ex is UnauthorizedAccessException || ex is InvalidOperationException)
            {
                return TicketLayout.Default();
            }
            return layout.Normalized();
        }

        private static void Apply(JsonElement obj, TicketLayout layout)
        {
            JsonElement v;
            int n;
            if (obj.TryGetProperty("colunas", out v) && v.ValueKind == JsonValueKind.Number && v.TryGetInt32(out n)) layout.Columns = n;
            if (obj.TryGetProperty("pagina_codigo", out v) && v.ValueKind == JsonValueKind.Number && v.TryGetInt32(out n)) layout.CodePage = n;
            if (obj.TryGetProperty("cortar", out v) && (v.ValueKind == JsonValueKind.True || v.ValueKind == JsonValueKind.False)) layout.Cut = v.GetBoolean();
        }
    }
}
