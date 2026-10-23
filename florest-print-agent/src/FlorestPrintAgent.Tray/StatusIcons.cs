using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using FlorestPrintAgent.Core.Agent;

namespace FlorestPrintAgent.Tray
{
    /// <summary>Ícones desenhados em código (sem arquivos .ico): um círculo colorido com a letra F, na cor do estado.</summary>
    [SupportedOSPlatform("windows")]
    internal static class StatusIcons
    {
        private static readonly object Lock = new object();
        private static readonly Dictionary<string, Icon> Cache = new Dictionary<string, Icon>();

        public static Color ColorFor(string kind)
        {
            switch (kind)
            {
                case AgentStatusKind.Conectado: return Color.FromArgb(22, 163, 74);
                case AgentStatusKind.SemConexao: return Color.FromArgb(217, 119, 6);
                case AgentStatusKind.Erro: return Color.FromArgb(220, 38, 38);
                default: return Color.FromArgb(107, 114, 128);
            }
        }

        public static Icon For(string kind)
        {
            lock (Lock)
            {
                Icon? icon;
                if (!Cache.TryGetValue(kind, out icon))
                {
                    icon = Create(ColorFor(kind));
                    Cache[kind] = icon;
                }
                return icon;
            }
        }

        private static Icon Create(Color color)
        {
            using (Bitmap bitmap = new Bitmap(32, 32))
            {
                using (Graphics g = Graphics.FromImage(bitmap))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.Clear(Color.Transparent);
                    using (Brush fill = new SolidBrush(color))
                    {
                        g.FillEllipse(fill, 1, 1, 30, 30);
                    }
                    using (Font font = new Font("Segoe UI", 19f, FontStyle.Bold, GraphicsUnit.Pixel))
                    using (StringFormat format = new StringFormat())
                    {
                        format.Alignment = StringAlignment.Center;
                        format.LineAlignment = StringAlignment.Center;
                        g.DrawString("F", font, Brushes.White, new RectangleF(0, 1, 32, 32), format);
                    }
                }

                IntPtr handle = bitmap.GetHicon();
                try
                {
                    using (Icon temporary = Icon.FromHandle(handle))
                    {
                        return (Icon)temporary.Clone();
                    }
                }
                finally
                {
                    DestroyIcon(handle);
                }
            }
        }

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DestroyIcon(IntPtr handle);
    }
}
