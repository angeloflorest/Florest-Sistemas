using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace FlorestPrintAgent.Core.Printers
{
    /// <summary>P/Invoke do spooler do Windows (winspool.drv). Somente leitura: nada é criado, alterado ou removido.</summary>
    [SupportedOSPlatform("windows")]
    internal static class WinSpool
    {
        private const uint PRINTER_ENUM_LOCAL = 0x00000002;
        private const uint PRINTER_ENUM_CONNECTIONS = 0x00000004;
        private const int ERROR_INSUFFICIENT_BUFFER = 122;

#pragma warning disable CS0649 // campos preenchidos pelo marshaller nativo
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct PRINTER_INFO_2
        {
            public string? pServerName;
            public string? pPrinterName;
            public string? pShareName;
            public string? pPortName;
            public string? pDriverName;
            public string? pComment;
            public string? pLocation;
            public IntPtr pDevMode;
            public string? pSepFile;
            public string? pPrintProcessor;
            public string? pDatatype;
            public string? pParameters;
            public IntPtr pSecurityDescriptor;
            public uint Attributes;
            public uint Priority;
            public uint DefaultPriority;
            public uint StartTime;
            public uint UntilTime;
            public uint Status;
            public uint cJobs;
            public uint AveragePPM;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct PORT_INFO_2
        {
            public string? pPortName;
            public string? pMonitorName;
            public string? pDescription;
            public uint fPortType;
            public uint Reserved;
        }
#pragma warning restore CS0649

        [DllImport("winspool.drv", EntryPoint = "EnumPrintersW", SetLastError = true, CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern bool EnumPrinters(uint flags, string? name, uint level, IntPtr pPrinterEnum, uint cbBuf, out uint pcbNeeded, out uint pcReturned);

        [DllImport("winspool.drv", EntryPoint = "EnumPortsW", SetLastError = true, CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern bool EnumPorts(string? name, uint level, IntPtr pPorts, uint cbBuf, out uint pcbNeeded, out uint pcReturned);

        /// <summary>Filas locais + conexões do usuário atual. Falha técnica = false (NUNCA confundir com "zero impressoras").</summary>
        internal static bool TryEnumPrinters(out List<RawPrinter> printers, out string? error)
        {
            printers = new List<RawPrinter>();
            error = null;
            const uint flags = PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS;

            uint needed;
            uint returned;
            bool ok = EnumPrinters(flags, null, 2, IntPtr.Zero, 0, out needed, out returned);
            int lastError = Marshal.GetLastWin32Error();
            if (ok)
            {
                if (needed == 0) return true; // varredura concluída: nenhuma fila instalada
            }
            else if (lastError != ERROR_INSUFFICIENT_BUFFER)
            {
                error = "EnumPrinters falhou (erro Windows " + lastError.ToString(System.Globalization.CultureInfo.InvariantCulture) + ").";
                return false;
            }

            for (int attempt = 0; attempt < 4; attempt++)
            {
                if (needed == 0) return true;
                IntPtr buffer = Marshal.AllocHGlobal((int)needed);
                try
                {
                    uint needed2;
                    ok = EnumPrinters(flags, null, 2, buffer, needed, out needed2, out returned);
                    lastError = Marshal.GetLastWin32Error();
                    if (ok)
                    {
                        int size = Marshal.SizeOf(typeof(PRINTER_INFO_2));
                        for (int i = 0; i < (int)returned; i++)
                        {
                            IntPtr p = IntPtr.Add(buffer, i * size);
                            object? boxed = Marshal.PtrToStructure(p, typeof(PRINTER_INFO_2));
                            if (boxed == null) continue;
                            PRINTER_INFO_2 info = (PRINTER_INFO_2)boxed;

                            RawPrinter raw = new RawPrinter();
                            raw.Name = info.pPrinterName ?? string.Empty;
                            raw.ServerName = info.pServerName;
                            raw.ShareName = info.pShareName;
                            raw.PortName = info.pPortName;
                            raw.DriverName = info.pDriverName;
                            raw.Attributes = info.Attributes;
                            raw.Status = info.Status;
                            raw.StatusKnown = true;
                            printers.Add(raw);
                        }
                        return true;
                    }
                    if (lastError != ERROR_INSUFFICIENT_BUFFER)
                    {
                        error = "EnumPrinters falhou (erro Windows " + lastError.ToString(System.Globalization.CultureInfo.InvariantCulture) + ").";
                        printers.Clear();
                        return false;
                    }
                    needed = needed2; // o tamanho mudou entre as chamadas: tenta de novo
                }
                finally
                {
                    Marshal.FreeHGlobal(buffer);
                }
            }

            printers.Clear();
            error = "EnumPrinters: o tamanho da lista mudou durante a leitura.";
            return false;
        }

        /// <summary>Portas do spooler (para saber o monitor: USB Monitor, Standard TCP/IP Port, WSD...). Falha aqui NÃO é fatal.</summary>
        internal static List<PortDetails> EnumPortsSafe()
        {
            List<PortDetails> result = new List<PortDetails>();
            try
            {
                uint needed;
                uint returned;
                bool ok = EnumPorts(null, 2, IntPtr.Zero, 0, out needed, out returned);
                int lastError = Marshal.GetLastWin32Error();
                if (ok && needed == 0) return result;
                if (!ok && lastError != ERROR_INSUFFICIENT_BUFFER) return result;

                for (int attempt = 0; attempt < 4; attempt++)
                {
                    if (needed == 0) return result;
                    IntPtr buffer = Marshal.AllocHGlobal((int)needed);
                    try
                    {
                        uint needed2;
                        ok = EnumPorts(null, 2, buffer, needed, out needed2, out returned);
                        lastError = Marshal.GetLastWin32Error();
                        if (ok)
                        {
                            int size = Marshal.SizeOf(typeof(PORT_INFO_2));
                            for (int i = 0; i < (int)returned; i++)
                            {
                                IntPtr p = IntPtr.Add(buffer, i * size);
                                object? boxed = Marshal.PtrToStructure(p, typeof(PORT_INFO_2));
                                if (boxed == null) continue;
                                PORT_INFO_2 info = (PORT_INFO_2)boxed;
                                PortDetails d = new PortDetails();
                                d.PortName = info.pPortName ?? string.Empty;
                                d.MonitorName = info.pMonitorName;
                                d.Description = info.pDescription;
                                result.Add(d);
                            }
                            return result;
                        }
                        if (lastError != ERROR_INSUFFICIENT_BUFFER) return new List<PortDetails>();
                        needed = needed2;
                    }
                    finally
                    {
                        Marshal.FreeHGlobal(buffer);
                    }
                }
            }
            catch (Exception)
            {
                // sem informação de portas, a classificação segue com o que tiver
            }
            return new List<PortDetails>();
        }
    }
}
