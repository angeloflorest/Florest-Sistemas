using System;
using System.Collections.Generic;
using System.Linq;
using FlorestPrintAgent.Core;
using FlorestPrintAgent.Core.Printers;
using FlorestPrintAgent.Tests.TestSupport;
using Xunit;

namespace FlorestPrintAgent.Tests
{
    public class PrinterIdentifierTests
    {
        [Fact]
        public void IsAnSha256HexLowerCaseString()
        {
            string id = PrinterIdentifier.Compute("Epson TM-T20X", "USB001", null, null);
            Assert.Equal(64, id.Length);
            Assert.Matches("^[0-9a-f]{64}$", id);
        }

        [Fact]
        public void IsDeterministic()
        {
            string a = PrinterIdentifier.Compute("Epson TM-T20X", "192.168.0.50", null, null);
            string b = PrinterIdentifier.Compute("Epson TM-T20X", "192.168.0.50", null, null);
            Assert.Equal(a, b);
        }

        [Fact]
        public void IgnoresCaseAndExtraSpaces()
        {
            string a = PrinterIdentifier.Compute("Epson TM-T20X", "IP_192.168.0.50", null, null);
            string b = PrinterIdentifier.Compute("  epson   tm-t20x ", "ip_192.168.0.50", null, null);
            Assert.Equal(a, b);
        }

        [Fact]
        public void DifferentQueueNamesGiveDifferentIds()
        {
            Assert.NotEqual(
                PrinterIdentifier.Compute("Cozinha", "USB001", null, null),
                PrinterIdentifier.Compute("Balcao", "USB001", null, null));
        }

        [Fact]
        public void DifferentWindowsPortsGiveDifferentIds()
        {
            Assert.NotEqual(
                PrinterIdentifier.Compute("Cozinha", "IP_192.168.0.50", null, null),
                PrinterIdentifier.Compute("Cozinha", "IP_192.168.0.51", null, null));
        }

        [Fact]
        public void UsbPortNumberDoesNotChangeTheId()
        {
            // o número da porta USB muda quando o cabo vai para outra entrada: a identidade não deve mudar
            Assert.Equal(
                PrinterIdentifier.Compute("Balcao", "USB001", null, null),
                PrinterIdentifier.Compute("Balcao", "USB003", null, null));
        }

        [Fact]
        public void SharedPrintersDependOnServerAndShare()
        {
            string a = PrinterIdentifier.Compute("\\\\SRV1\\Fiscal", "\\\\SRV1\\Fiscal", "\\\\SRV1", "Fiscal");
            string b = PrinterIdentifier.Compute("\\\\SRV2\\Fiscal", "\\\\SRV2\\Fiscal", "\\\\SRV2", "Fiscal");
            Assert.NotEqual(a, b);
        }

        [Fact]
        public void DoesNotDependOnPositionOrOrder()
        {
            RawPrinter[] list1 =
            {
                Samples.Raw("Balcao", "USB001", "Generic / Text Only"),
                Samples.Raw("Cozinha", "IP_10.0.0.5", "Generic / Text Only"),
            };
            RawPrinter[] list2 = list1.Reverse().ToArray();
            List<PrinterInfo> a = PrinterCollector.Build(list1, new List<PortDetails>(), new NoTcpReader());
            List<PrinterInfo> b = PrinterCollector.Build(list2, new List<PortDetails>(), new NoTcpReader());
            Assert.Equal(
                a.Select(x => x.Nome + "=" + x.Identificador).OrderBy(x => x, StringComparer.Ordinal),
                b.Select(x => x.Nome + "=" + x.Identificador).OrderBy(x => x, StringComparer.Ordinal));
        }
    }

    internal sealed class NoTcpReader : ITcpIpPortReader
    {
        public TcpIpPortInfo? TryRead(string portName)
        {
            return null;
        }
    }

    internal sealed class DictionaryTcpReader : ITcpIpPortReader
    {
        private readonly Dictionary<string, TcpIpPortInfo> _ports = new Dictionary<string, TcpIpPortInfo>(StringComparer.OrdinalIgnoreCase);

        public DictionaryTcpReader Add(string port, string? host, string? ip, int? number, int? protocol)
        {
            TcpIpPortInfo info = new TcpIpPortInfo();
            info.HostName = host;
            info.IpAddress = ip;
            info.PortNumber = number;
            info.Protocol = protocol;
            _ports[port] = info;
            return this;
        }

        public TcpIpPortInfo? TryRead(string portName)
        {
            TcpIpPortInfo? info;
            return _ports.TryGetValue(portName, out info) ? info : null;
        }
    }

    public class PrinterFilterTests
    {
        [Theory]
        [InlineData("Microsoft Print to PDF", "PORTPROMPT:", "Microsoft Print To PDF")]
        [InlineData("Microsoft XPS Document Writer", "PORTPROMPT:", "Microsoft XPS Document Writer v4")]
        [InlineData("Fax", "SHRFAX:", "Microsoft Shared Fax Driver")]
        [InlineData("OneNote (Desktop)", "nul:", "Send to Microsoft OneNote 16 Driver")]
        [InlineData("Send To OneNote 2016", "Microsoft.Office.OneNote_16001.14326.20404.0_x64__8wekyb3d8bbwe", "Send to Microsoft OneNote 16 Driver")]
        [InlineData("Adobe PDF", "Documents\\*.pdf", "Adobe PDF Converter")]
        [InlineData("CutePDF Writer", "CPW2:", "CutePDF Writer v4.0")]
        [InlineData("Impressora PDF", "FILE:", "Generic")]
        [InlineData("Printer (redirected 2)", "TS001", "Remote Desktop Easy Print")]
        [InlineData("Gerador de documentos", "CPW2:", "Some PDF Writer")] // driver com "PDF" e porta que não é de hardware
        public void ExcludesVirtualPrinters(string name, string port, string driver)
        {
            Assert.True(PrinterFilter.IsVirtual(Samples.Raw(name, port, driver)));
        }

        [Theory]
        [InlineData("EPSON TM-T20X Receipt", "USB001", "EPSON TM-T20II Receipt5")]
        [InlineData("Zebra ZD220", "USB002", "ZDesigner ZD220-203dpi EPL")]
        [InlineData("Impressora Cozinha", "IP_192.168.0.50", "Generic / Text Only")]
        [InlineData("Fabricante Desconhecido XPTO-9000", "COM3", "Driver Desconhecido")]
        [InlineData("Bematech MP-4200 TH", "USB001", "Generic / Text Only")]
        [InlineData("Elgin i9", "LPT1:", "Elgin i9")]
        [InlineData("Daruma DR800", "COM1", "Daruma DR800")]
        [InlineData("Faxon Etiquetas", "USB001", "Generic / Text Only")] // contém as letras "fax" mas não é fax
        [InlineData("HP LaserJet Pro M404", "WSD-1234-5678", "HP Universal Printing PCL 6")]
        [InlineData("Caixa", "192.168.1.20", "Generic / Text Only")]
        [InlineData("Escritório Brother", "USB001", "Brother PDF Class Driver")] // driver com "PDF", mas porta de hardware real
        [InlineData("Multifuncional", "IP_10.0.0.9", "Vendor XPS Class Driver")]
        public void KeepsPhysicalAndUnknownVendorPrinters(string name, string port, string driver)
        {
            Assert.False(PrinterFilter.IsVirtual(Samples.Raw(name, port, driver)));
        }
    }

    public class PrinterClassifierTests
    {
        private static RawPrinter Raw(string name, string port, uint status, uint attributes)
        {
            RawPrinter r = Samples.Raw(name, port, "Generic / Text Only");
            r.Status = status;
            r.Attributes = attributes;
            return r;
        }

        [Fact]
        public void UsbPrinterIsClassifiedAsUsbWithoutIpOrPort()
        {
            PrinterInfo? p = PrinterClassifier.Classify(Raw("Balcao", "USB001", 0, 0), new PortDetails { PortName = "USB001", MonitorName = "USB Monitor" }, null);
            Assert.NotNull(p);
            Assert.Equal(PrinterConnection.Usb, p!.Conexao);
            Assert.Null(p.Ip);
            Assert.Null(p.Porta);
            Assert.Equal("USB001", p.PortaWindows);
        }

        [Fact]
        public void StandardTcpIpRawPortReportsRealIpAndPort()
        {
            TcpIpPortInfo tcp = new TcpIpPortInfo { HostName = "192.168.0.50", IpAddress = "192.168.0.50", PortNumber = 9100, Protocol = 1 };
            PrinterInfo? p = PrinterClassifier.Classify(Raw("Cozinha", "IP_192.168.0.50", 0, 0), new PortDetails { PortName = "IP_192.168.0.50", MonitorName = "Standard TCP/IP Port" }, tcp);
            Assert.Equal(PrinterConnection.Rede, p!.Conexao);
            Assert.Equal("192.168.0.50", p.Ip);
            Assert.Equal(9100, p.Porta);
        }

        [Fact]
        public void RawPortOtherThan9100IsReportedAsConfigured()
        {
            TcpIpPortInfo tcp = new TcpIpPortInfo { IpAddress = "10.1.1.8", PortNumber = 9101, Protocol = 1 };
            PrinterInfo? p = PrinterClassifier.Classify(Raw("Bar", "IP_10.1.1.8", 0, 0), new PortDetails { PortName = "IP_10.1.1.8", MonitorName = "Standard TCP/IP Port" }, tcp);
            Assert.Equal(9101, p!.Porta);
        }

        [Fact]
        public void HostNameThatIsNotAnIpIsNeverReportedAsIp()
        {
            TcpIpPortInfo tcp = new TcpIpPortInfo { HostName = "impressora-cozinha", IpAddress = null, PortNumber = 9100, Protocol = 1 };
            PrinterInfo? p = PrinterClassifier.Classify(Raw("Cozinha", "IP_impressora-cozinha", 0, 0), new PortDetails { PortName = "IP_impressora-cozinha", MonitorName = "Standard TCP/IP Port" }, tcp);
            Assert.Equal(PrinterConnection.Rede, p!.Conexao);
            Assert.Null(p.Ip);
        }

        [Fact]
        public void PortNumberIsNeverAssumedWhenWindowsDoesNotReportIt()
        {
            TcpIpPortInfo tcp = new TcpIpPortInfo { IpAddress = "192.168.0.50", PortNumber = null, Protocol = 1 };
            PrinterInfo? p = PrinterClassifier.Classify(Raw("Cozinha", "IP_192.168.0.50", 0, 0), new PortDetails { PortName = "IP_192.168.0.50", MonitorName = "Standard TCP/IP Port" }, tcp);
            Assert.Equal("192.168.0.50", p!.Ip);
            Assert.Null(p.Porta);
        }

        [Fact]
        public void LprProtocolDoesNotReportAnRawPort()
        {
            TcpIpPortInfo tcp = new TcpIpPortInfo { IpAddress = "192.168.0.60", PortNumber = 515, Protocol = 2 };
            PrinterInfo? p = PrinterClassifier.Classify(Raw("Etiquetas", "IP_192.168.0.60", 0, 0), new PortDetails { PortName = "IP_192.168.0.60", MonitorName = "Standard TCP/IP Port" }, tcp);
            Assert.Equal("192.168.0.60", p!.Ip);
            Assert.Null(p.Porta);
        }

        [Fact]
        public void NetworkPrinterWithoutTcpInfoHasNoIpAndNoPort()
        {
            PrinterInfo? p = PrinterClassifier.Classify(Raw("Impressora WSD", "WSD-aaaa-bbbb", 0, 0), new PortDetails { PortName = "WSD-aaaa-bbbb", MonitorName = "WSD Port" }, null);
            Assert.Equal(PrinterConnection.Rede, p!.Conexao);
            Assert.Null(p.Ip);
            Assert.Null(p.Porta);
        }

        [Fact]
        public void IpIsNotInferredFromThePrinterOrPortName()
        {
            PrinterInfo? p = PrinterClassifier.Classify(Raw("Impressora 192.168.0.77", "USB001", 0, 0), new PortDetails { PortName = "USB001", MonitorName = "USB Monitor" }, null);
            Assert.Null(p!.Ip);
            Assert.Null(p.Porta);
        }

        [Fact]
        public void SharedPrinterFromAnotherComputerIsShared()
        {
            RawPrinter raw = Raw("\\\\SERVIDOR\\Fiscal", "\\\\SERVIDOR\\Fiscal", 0, PrinterStatusMapper.AttrNetwork);
            raw.ServerName = "\\\\SERVIDOR";
            raw.ShareName = "Fiscal";
            PrinterInfo? p = PrinterClassifier.Classify(raw, null, null);
            Assert.Equal(PrinterConnection.Compartilhada, p!.Conexao);
        }

        [Fact]
        public void SerialPortAndMissingPortAreOutro()
        {
            Assert.Equal(PrinterConnection.Outro, PrinterClassifier.Classify(Raw("Daruma", "COM1", 0, 0), null, null)!.Conexao);
            Assert.Equal(PrinterConnection.Outro, PrinterClassifier.Classify(Raw("SemPorta", "", 0, 0), null, null)!.Conexao);
        }

        [Fact]
        public void LocalQueueOnOtherPortIsWindows()
        {
            PrinterInfo? p = PrinterClassifier.Classify(Raw("Etiqueta", "ZDesignerPort", 0, 0), new PortDetails { PortName = "ZDesignerPort", MonitorName = "Local Port" }, null);
            Assert.Equal(PrinterConnection.Windows, p!.Conexao);
        }

        [Fact]
        public void VirtualPrinterReturnsNull()
        {
            RawPrinter raw = Samples.Raw("Microsoft Print to PDF", "PORTPROMPT:", "Microsoft Print To PDF");
            Assert.Null(PrinterClassifier.Classify(raw, null, null));
        }

        [Fact]
        public void EmptyNameReturnsNull()
        {
            Assert.Null(PrinterClassifier.Classify(Raw("   ", "USB001", 0, 0), null, null));
        }

        [Fact]
        public void LongNamesAndControlCharactersAreCleaned()
        {
            string name = "Balcao\u0007" + new string('x', 400);
            PrinterInfo? p = PrinterClassifier.Classify(Raw(name, "USB001", 0, 0), null, null);
            Assert.NotNull(p);
            Assert.DoesNotContain("\u0007", p!.Nome, StringComparison.Ordinal);
            Assert.True(p.Nome.Length <= AgentConstants.MaxPrinterNameLength);
        }

        [Fact]
        public void ConnectionValuesFollowTheServerContractFormat()
        {
            // a Migration 029 exige apenas ^[a-z][a-z0-9_]{0,29}$ para a conexão
            string[] all = { PrinterConnection.Usb, PrinterConnection.Rede, PrinterConnection.Compartilhada, PrinterConnection.Windows, PrinterConnection.Outro };
            foreach (string c in all) Assert.Matches("^[a-z][a-z0-9_]{0,29}$", c);
            string[] statuses = { PrinterStatus.Disponivel, PrinterStatus.Offline, PrinterStatus.Erro, PrinterStatus.Desconhecido };
            foreach (string s in statuses) Assert.Matches("^[a-z][a-z0-9_]{0,29}$", s);
        }
    }

    public class PrinterStatusMapperTests
    {
        private static RawPrinter WithStatus(uint status, uint attributes, bool known)
        {
            RawPrinter r = Samples.Raw("X", "USB001", "d");
            r.Status = status;
            r.Attributes = attributes;
            r.StatusKnown = known;
            return r;
        }

        [Fact]
        public void NoFlagsMeansAvailable()
        {
            Assert.Equal(PrinterStatus.Disponivel, PrinterStatusMapper.Map(WithStatus(0, 0, true)));
        }

        [Fact]
        public void UnknownStatusIsNeverReportedAsAvailable()
        {
            Assert.Equal(PrinterStatus.Desconhecido, PrinterStatusMapper.Map(WithStatus(0, 0, false)));
        }

        [Theory]
        [InlineData(0x00000080u)] // OFFLINE
        [InlineData(0x00001000u)] // NOT_AVAILABLE
        [InlineData(0x02000000u)] // SERVER_OFFLINE
        public void OfflineFlagsMapToOffline(uint status)
        {
            Assert.Equal(PrinterStatus.Offline, PrinterStatusMapper.Map(WithStatus(status, 0, true)));
        }

        [Fact]
        public void WorkOfflineAttributeMapsToOffline()
        {
            Assert.Equal(PrinterStatus.Offline, PrinterStatusMapper.Map(WithStatus(0, PrinterStatusMapper.AttrWorkOffline, true)));
        }

        [Theory]
        [InlineData(0x00000002u)] // ERROR
        [InlineData(0x00000008u)] // PAPER_JAM
        [InlineData(0x00000010u)] // PAPER_OUT
        [InlineData(0x00400000u)] // DOOR_OPEN
        [InlineData(0x00000001u)] // PAUSED
        public void ProblemFlagsMapToError(uint status)
        {
            Assert.Equal(PrinterStatus.Erro, PrinterStatusMapper.Map(WithStatus(status, 0, true)));
        }

        [Fact]
        public void OfflineWinsOverError()
        {
            Assert.Equal(PrinterStatus.Offline, PrinterStatusMapper.Map(WithStatus(0x00000080u | 0x00000002u, 0, true)));
        }

        [Fact]
        public void BusyFlagsDoNotCountAsProblems()
        {
            // PRINTER_STATUS_BUSY (0x200), PRINTING (0x400) e WAITING (0x2000) são operação normal
            Assert.Equal(PrinterStatus.Disponivel, PrinterStatusMapper.Map(WithStatus(0x200u | 0x400u | 0x2000u, 0, true)));
        }
    }

    public class PrinterMergerTests
    {
        private static List<PrinterInfo> Merge(IEnumerable<PrinterInfo> service, params List<PrinterInfo>[] users)
        {
            bool truncated;
            return PrinterMerger.Merge(service, users.Select(u => (IEnumerable<PrinterInfo>)u), 100, out truncated);
        }

        [Fact]
        public void KeepsServicePrintersWhenThereAreNoUserLists()
        {
            // impressoras compartilhadas vistas só pelo Service não podem se perder
            PrinterInfo shared = Samples.Printer("\\\\SRV\\Fiscal", PrinterConnection.Compartilhada, PrinterStatus.Disponivel, null, null, "\\\\SRV\\Fiscal");
            List<PrinterInfo> merged = Merge(new[] { shared });
            Assert.Single(merged);
            Assert.Equal(shared.Identificador, merged[0].Identificador);
        }

        [Fact]
        public void AddsPrintersOnlyTheUserSessionCanSee()
        {
            PrinterInfo service = Samples.Usb("Balcao");
            PrinterInfo userOnly = Samples.Printer("\\\\SRV\\Etiquetas", PrinterConnection.Compartilhada, PrinterStatus.Disponivel, null, null, "\\\\SRV\\Etiquetas");
            List<PrinterInfo> merged = Merge(new[] { service }, new List<PrinterInfo> { userOnly });
            Assert.Equal(2, merged.Count);
        }

        [Fact]
        public void DeduplicatesByIdentifier()
        {
            PrinterInfo a = Samples.Usb("Balcao");
            PrinterInfo b = Samples.Usb("Balcao");
            List<PrinterInfo> merged = Merge(new[] { a }, new List<PrinterInfo> { b }, new List<PrinterInfo> { b });
            Assert.Single(merged);
        }

        [Fact]
        public void MoreCompleteInformationWins()
        {
            string id = PrinterIdentifier.Compute("Cozinha", "IP_192.168.0.50", null, null);
            PrinterInfo poor = new PrinterInfo { Identificador = id, Nome = "Cozinha", Conexao = PrinterConnection.Outro, Status = PrinterStatus.Desconhecido };
            PrinterInfo rich = new PrinterInfo { Identificador = id, Nome = "Cozinha", Conexao = PrinterConnection.Rede, Ip = "192.168.0.50", Porta = 9100, PortaWindows = "IP_192.168.0.50", Status = PrinterStatus.Disponivel };

            List<PrinterInfo> serviceRich = Merge(new[] { rich }, new List<PrinterInfo> { poor });
            Assert.Equal("192.168.0.50", serviceRich.Single().Ip);

            // entre duas sessões de usuário (impressora que o Service não enxerga) vale a mais completa
            List<PrinterInfo> userRich = Merge(new PrinterInfo[0], new List<PrinterInfo> { poor }, new List<PrinterInfo> { rich });
            Assert.Equal("192.168.0.50", userRich.Single().Ip);
            Assert.Equal(9100, userRich.Single().Porta);
        }

        [Fact]
        public void AUserCanNeverOverwriteAPrinterTheServiceSees()
        {
            string id = PrinterIdentifier.Compute("Caixa", "IP_192.168.0.60", null, null);
            PrinterInfo real = new PrinterInfo { Identificador = id, Nome = "Caixa", Conexao = PrinterConnection.Outro, Status = PrinterStatus.Desconhecido };
            PrinterInfo spoof = new PrinterInfo { Identificador = id, Nome = "Caixa", Conexao = PrinterConnection.Rede, Ip = "10.66.66.66", Porta = 9100, PortaWindows = "IP_10.66.66.66", Status = PrinterStatus.Disponivel };

            PrinterInfo result = Merge(new[] { real }, new List<PrinterInfo> { spoof }).Single();

            Assert.Null(result.Ip);
            Assert.Null(result.Porta);
        }

        [Fact]
        public void TieKeepsTheServiceVersion()
        {
            string id = PrinterIdentifier.Compute("Balcao", "USB001", null, null);
            PrinterInfo fromService = new PrinterInfo { Identificador = id, Nome = "Balcao-Service", Conexao = PrinterConnection.Usb, PortaWindows = "USB001", Status = PrinterStatus.Disponivel };
            PrinterInfo fromUser = new PrinterInfo { Identificador = id, Nome = "Balcao-Usuario", Conexao = PrinterConnection.Usb, PortaWindows = "USB001", Status = PrinterStatus.Disponivel };
            Assert.Equal("Balcao-Service", Merge(new[] { fromService }, new List<PrinterInfo> { fromUser }).Single().Nome);
        }

        [Fact]
        public void OutputIsOrderedByNameThenId()
        {
            List<PrinterInfo> merged = Merge(new[] { Samples.Usb("Zeta"), Samples.Usb("alfa"), Samples.Usb("Beta") });
            Assert.Equal(new[] { "alfa", "Beta", "Zeta" }, merged.Select(p => p.Nome).ToArray());
        }

        [Fact]
        public void TruncatesAtTheLimitAndReportsIt()
        {
            List<PrinterInfo> many = new List<PrinterInfo>();
            for (int i = 0; i < 150; i++) many.Add(Samples.Printer("Impressora " + i.ToString("D3"), PrinterConnection.Windows, PrinterStatus.Disponivel, null, null, "P" + i));
            bool truncated;
            List<PrinterInfo> merged = PrinterMerger.Merge(many, new List<IEnumerable<PrinterInfo>>(), 100, out truncated);
            Assert.True(truncated);
            Assert.Equal(100, merged.Count);

            merged = PrinterMerger.Merge(many.Take(10), new List<IEnumerable<PrinterInfo>>(), 100, out truncated);
            Assert.False(truncated);
            Assert.Equal(10, merged.Count);
        }

        [Fact]
        public void EmptyInputsGiveAnEmptyListNotAnError()
        {
            bool truncated;
            List<PrinterInfo> merged = PrinterMerger.Merge(new List<PrinterInfo>(), new List<IEnumerable<PrinterInfo>>(), 100, out truncated);
            Assert.Empty(merged);
            Assert.False(truncated);
        }

        [Fact]
        public void EntriesWithoutIdentifierAreIgnored()
        {
            PrinterInfo broken = new PrinterInfo { Identificador = "", Nome = "Sem id" };
            Assert.Empty(Merge(new[] { broken }));
        }
    }

    public class PrinterSanitizerTests
    {
        [Fact]
        public void KeepsAValidPrinterUnchanged()
        {
            PrinterInfo p = Samples.Printer("Cozinha", PrinterConnection.Rede, PrinterStatus.Disponivel, "192.168.0.50", 9100, "IP_192.168.0.50");
            PrinterInfo? clean = PrinterSanitizer.Sanitize(p);
            Assert.NotNull(clean);
            Assert.Equal(p.Identificador, clean!.Identificador);
            Assert.Equal("192.168.0.50", clean.Ip);
            Assert.Equal(9100, clean.Porta);
        }

        [Theory]
        [InlineData("")]
        [InlineData("curto")]
        [InlineData("ZZZZ000000000000000000000000000000000000000000000000000000000000")]            // 64 mas não-hex
        [InlineData("ABCDEF0000000000000000000000000000000000000000000000000000000000")]            // maiúsculas
        public void DropsPrintersWithInvalidIdentifier(string id)
        {
            PrinterInfo p = Samples.Usb("Balcao");
            p.Identificador = id;
            Assert.Null(PrinterSanitizer.Sanitize(p));
        }

        [Fact]
        public void DropsPrintersWithoutName()
        {
            PrinterInfo p = Samples.Usb("Balcao");
            p.Nome = "  \t ";
            Assert.Null(PrinterSanitizer.Sanitize(p));
            Assert.Null(PrinterSanitizer.Sanitize(null));
        }

        [Fact]
        public void InvalidIpAndPortBecomeNull()
        {
            PrinterInfo p = Samples.Usb("Balcao");
            p.Ip = "nao-e-ip";
            p.Porta = 70000;
            PrinterInfo? clean = PrinterSanitizer.Sanitize(p);
            Assert.Null(clean!.Ip);
            Assert.Null(clean.Porta);

            p.Ip = "192.168.1"; // forma parcial que IPAddress.TryParse aceitaria
            p.Porta = 0;
            clean = PrinterSanitizer.Sanitize(p);
            Assert.Null(clean!.Ip);
            Assert.Null(clean.Porta);
        }

        [Fact]
        public void EnumValuesAreNormalizedOrReplacedByFallback()
        {
            PrinterInfo p = Samples.Usb("Balcao");
            p.Conexao = "  USB ";
            p.Status = "Esta Coisa; DROP TABLE";
            PrinterInfo? clean = PrinterSanitizer.Sanitize(p);
            Assert.Equal("usb", clean!.Conexao);
            Assert.Equal(PrinterStatus.Desconhecido, clean.Status);
        }

        [Fact]
        public void ListIsDeduplicatedAndLimited()
        {
            List<PrinterInfo> input = new List<PrinterInfo>();
            input.Add(Samples.Usb("Balcao"));
            input.Add(Samples.Usb("Balcao"));
            PrinterInfo invalid = Samples.Usb("Outra");
            invalid.Identificador = "x";
            input.Add(invalid);
            for (int i = 0; i < 300; i++) input.Add(Samples.Printer("P" + i, PrinterConnection.Windows, PrinterStatus.Disponivel, null, null, "PORTA" + i));

            List<PrinterInfo> clean = PrinterSanitizer.SanitizeList(input, 100);
            Assert.Equal(100, clean.Count);
            Assert.Equal(clean.Count, clean.Select(p => p.Identificador).Distinct().Count());
            Assert.DoesNotContain(clean, p => p.Nome == "Outra");
        }

        [Fact]
        public void NullListGivesEmptyList()
        {
            Assert.Empty(PrinterSanitizer.SanitizeList(null, 100));
        }
    }

    public class PrinterCollectorTests
    {
        [Fact]
        public void BuildsOnlyPhysicalPrintersAndUsesRealTcpInfo()
        {
            List<RawPrinter> raws = new List<RawPrinter>
            {
                Samples.Raw("Microsoft Print to PDF", "PORTPROMPT:", "Microsoft Print To PDF"),
                Samples.Raw("Fax", "SHRFAX:", "Microsoft Shared Fax Driver"),
                Samples.Raw("Balcao", "USB001", "EPSON TM-T20II Receipt5"),
                Samples.Raw("Cozinha", "IP_192.168.0.50", "Generic / Text Only"),
            };
            List<PortDetails> ports = new List<PortDetails>
            {
                new PortDetails { PortName = "USB001", MonitorName = "USB Monitor" },
                new PortDetails { PortName = "IP_192.168.0.50", MonitorName = "Standard TCP/IP Port" },
            };
            DictionaryTcpReader tcp = new DictionaryTcpReader().Add("IP_192.168.0.50", "192.168.0.50", "192.168.0.50", 9100, 1);

            List<PrinterInfo> result = PrinterCollector.Build(raws, ports, tcp);

            Assert.Equal(2, result.Count);
            PrinterInfo kitchen = result.Single(p => p.Nome == "Cozinha");
            Assert.Equal(PrinterConnection.Rede, kitchen.Conexao);
            Assert.Equal("192.168.0.50", kitchen.Ip);
            Assert.Equal(9100, kitchen.Porta);
            PrinterInfo counter = result.Single(p => p.Nome == "Balcao");
            Assert.Equal(PrinterConnection.Usb, counter.Conexao);
            Assert.Null(counter.Ip);
        }

        [Fact]
        public void DuplicateQueuesWithTheSameIdentityAppearOnce()
        {
            List<RawPrinter> raws = new List<RawPrinter>
            {
                Samples.Raw("Balcao", "USB001", "d"),
                Samples.Raw("balcao", "USB002", "d"),
            };
            List<PrinterInfo> result = PrinterCollector.Build(raws, new List<PortDetails>(), new NoTcpReader());
            Assert.Single(result);
        }

        [Fact]
        public void EmptyInputIsAValidEmptyResult()
        {
            Assert.Empty(PrinterCollector.Build(new List<RawPrinter>(), new List<PortDetails>(), new NoTcpReader()));
        }
    }
}
