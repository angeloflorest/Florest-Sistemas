using System;
using System.Net;
using System.Net.Sockets;
using System.Text.RegularExpressions;

namespace FlorestPrintAgent.Core.Security
{
    /// <summary>
    /// Valida literais de IP de forma ESTRITA. IPAddress.TryParse aceita formas como "192.168.1" ou "1234"
    /// (e as converte em outro endereço): isso seria "inventar" um IP, então não é usado sozinho.
    /// </summary>
    public static class IpValidator
    {
        private static readonly Regex Ipv4Literal = new Regex("^(\\d{1,3})\\.(\\d{1,3})\\.(\\d{1,3})\\.(\\d{1,3})$", RegexOptions.CultureInvariant | RegexOptions.Compiled);

        /// <summary>Devolve o IP normalizado se for um IPv4/IPv6 literal de unicast utilizável; senão false.</summary>
        public static bool TryNormalize(string? text, out string normalized)
        {
            normalized = string.Empty;
            if (string.IsNullOrWhiteSpace(text)) return false;
            string t = text.Trim();
            if (t.Length > 64) return false;

            if (t.IndexOf(':') >= 0)
            {
                if (t.IndexOf('%') >= 0 || t.IndexOf('[') >= 0 || t.IndexOf('/') >= 0) return false;
                IPAddress? v6;
                if (!IPAddress.TryParse(t, out v6) || v6 == null || v6.AddressFamily != AddressFamily.InterNetworkV6) return false;
                if (v6.Equals(IPAddress.IPv6Any) || v6.Equals(IPAddress.IPv6Loopback) || v6.IsIPv6Multicast) return false;
                normalized = v6.ToString();
                return true;
            }

            Match m = Ipv4Literal.Match(t);
            if (!m.Success) return false;
            int[] oct = new int[4];
            for (int i = 0; i < 4; i++)
            {
                if (!int.TryParse(m.Groups[i + 1].Value, System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out oct[i])) return false;
                if (oct[i] < 0 || oct[i] > 255) return false;
            }
            if (oct[0] == 0 || oct[0] == 127 || oct[0] >= 224) return false; // 0.x, loopback, multicast/reservado/broadcast
            normalized = oct[0].ToString(System.Globalization.CultureInfo.InvariantCulture) + "." +
                         oct[1].ToString(System.Globalization.CultureInfo.InvariantCulture) + "." +
                         oct[2].ToString(System.Globalization.CultureInfo.InvariantCulture) + "." +
                         oct[3].ToString(System.Globalization.CultureInfo.InvariantCulture);
            return true;
        }
    }
}
