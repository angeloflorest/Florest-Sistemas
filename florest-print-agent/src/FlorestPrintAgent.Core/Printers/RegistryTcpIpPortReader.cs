using System;
using System.Runtime.Versioning;
using System.Security;
using Microsoft.Win32;

namespace FlorestPrintAgent.Core.Printers
{
    /// <summary>
    /// Lê (SOMENTE LEITURA) os dados de uma porta "Standard TCP/IP Port" no registro do Windows:
    /// HKLM\SYSTEM\CurrentControlSet\Control\Print\Monitors\Standard TCP/IP Port\Ports\&lt;porta&gt;
    /// (HostName, IPAddress, PortNumber, Protocol). Nunca escreve no registro.
    /// </summary>
    [SupportedOSPlatform("windows")]
    public sealed class RegistryTcpIpPortReader : ITcpIpPortReader
    {
        private const string BasePath = "SYSTEM\\CurrentControlSet\\Control\\Print\\Monitors\\Standard TCP/IP Port\\Ports";

        public TcpIpPortInfo? TryRead(string portName)
        {
            if (string.IsNullOrWhiteSpace(portName) || portName.Length > 200) return null;
            if (portName.IndexOf('\\') >= 0 || portName.IndexOf('/') >= 0) return null; // nome de porta nunca é caminho de registro

            try
            {
                using (RegistryKey hklm = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64))
                using (RegistryKey? key = hklm.OpenSubKey(BasePath + "\\" + portName, false))
                {
                    if (key == null) return null;

                    TcpIpPortInfo info = new TcpIpPortInfo();
                    info.HostName = key.GetValue("HostName") as string;
                    info.IpAddress = key.GetValue("IPAddress") as string;
                    object? portValue = key.GetValue("PortNumber");
                    if (portValue is int) info.PortNumber = (int)portValue;
                    object? protocolValue = key.GetValue("Protocol");
                    if (protocolValue is int) info.Protocol = (int)protocolValue;
                    return info;
                }
            }
            catch (Exception ex) when (ex is SecurityException || ex is UnauthorizedAccessException || ex is System.IO.IOException || ex is ArgumentException)
            {
                return null;
            }
        }
    }
}
