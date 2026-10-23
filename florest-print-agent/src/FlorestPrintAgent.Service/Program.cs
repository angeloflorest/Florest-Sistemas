using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Security;
using System.Runtime.Versioning;
using System.Security.Authentication;
using System.Threading;
using FlorestPrintAgent.Core;
using FlorestPrintAgent.Core.Agent;
using FlorestPrintAgent.Core.Api;
using FlorestPrintAgent.Core.Ipc;
using FlorestPrintAgent.Core.Jobs;
using FlorestPrintAgent.Core.Logging;
using FlorestPrintAgent.Core.Printers;
using FlorestPrintAgent.Core.Security;
using FlorestPrintAgent.Core.Storage;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace FlorestPrintAgent.Service
{
    /// <summary>
    /// Florest Print Agent — Serviço do Windows.
    /// Executa como serviço (LocalSystem, início automático) e também em modo console para desenvolvimento
    /// (dotnet run). Uma única instância por computador (mutex global).
    /// </summary>
    public static class Program
    {
        public static int Main(string[] args)
        {
            if (!OperatingSystem.IsWindows())
            {
                Console.Error.WriteLine("O Florest Print Agent só funciona no Windows.");
                return 2;
            }
            return RunWindows(args);
        }

        [SupportedOSPlatform("windows")]
        private static int RunWindows(string[] args)
        {
            // Instância única. Como SERVIÇO, o próprio Gerenciador de Serviços do Windows já garante uma única instância;
            // um mutex global com ACL padrão permitiria que qualquer usuário comum o criasse antes e impedisse o serviço de
            // iniciar para sempre. Por isso o mutex só é usado no modo console/desenvolvimento (Environment.UserInteractive).
            bool createdNew = true;
            Mutex? singleInstance = null;
            if (Environment.UserInteractive)
            {
                try
                {
                    singleInstance = new Mutex(false, AgentConstants.ServiceMutexName, out createdNew);
                }
                catch (UnauthorizedAccessException)
                {
                    // o mutex já existe e pertence a outra conta: há uma instância em execução
                    createdNew = false;
                }
            }

            using (singleInstance)
            {
                if (!createdNew)
                {
                    Console.Error.WriteLine("O Florest Print Agent já está em execução neste computador.");
                    return 3;
                }

                FileLoggerProvider? fileLogger = null;
                try
                {
                    AgentPaths paths = AgentPaths.CreateDefault();
                    PrepareFolders(paths);

                    fileLogger = new FileLoggerProvider(paths.LogDir, "service");

                    // Identidade permanente da instalação (criada uma única vez, nunca muda).
                    // Se já existe um vínculo (credencial) e a identidade sumiu/corrompeu, NÃO se cria outra: o agente sobe em
                    // estado de erro recuperável (sem falar com o servidor) em vez de causar "instalacao_divergente".
                    InstallationIdentityStore identityStore = new InstallationIdentityStore(paths.IdentityFile, () => CredentialFileExists(paths.CredentialFile));
                    string installationId = string.Empty;
                    string? identityProblem = null;
                    try
                    {
                        installationId = identityStore.GetOrCreate();
                    }
                    catch (IdentityProblemException ex)
                    {
                        identityProblem = ex.Message;
                    }

                    HostApplicationBuilder builder = Host.CreateApplicationBuilder(args);
                    builder.Services.AddWindowsService(options =>
                    {
                        options.ServiceName = AgentConstants.ServiceName;
                    });

                    // Somente o log em arquivo (rotativo, sanitizado). O console só aparece em modo desenvolvimento.
                    builder.Logging.ClearProviders();
                    builder.Logging.SetMinimumLevel(LogLevel.Information);
                    builder.Logging.AddFilter("Microsoft", LogLevel.Warning);
                    builder.Logging.AddFilter("System", LogLevel.Warning);
                    builder.Logging.AddProvider(fileLogger);
                    if (Environment.UserInteractive)
                    {
                        builder.Logging.AddConsole();
                    }

                    RegisterServices(builder.Services, paths, installationId, identityStore, identityProblem);

                    using (IHost host = builder.Build())
                    {
                        // Lê identidade, credencial protegida e estado ANTES de aceitar comandos do Tray.
                        host.Services.GetRequiredService<AgentCoordinator>().Initialize();

                        ILogger log = host.Services.GetRequiredService<ILoggerFactory>().CreateLogger("Service");
                        log.LogInformation("Serviço iniciando (versão {Versao}).", AgentConstants.AgentVersion);
                        if (identityProblem != null)
                        {
                            log.LogError("Identificação da instalação indisponível: {Mensagem}", identityProblem);
                        }

                        host.Run();

                        log.LogInformation("Serviço parado.");
                    }
                    return 0;
                }
                catch (Exception ex)
                {
                    // Falha de inicialização: registra o tipo/mensagem (sem dados sensíveis) e devolve erro ao Windows.
                    try
                    {
                        if (fileLogger != null)
                        {
                            fileLogger.CreateLogger("Service").LogCritical(ex, "O serviço não conseguiu iniciar.");
                        }
                    }
                    catch (Exception)
                    {
                        // sem log, sem problema
                    }
                    Console.Error.WriteLine("O serviço não conseguiu iniciar: " + ex.GetType().Name);
                    return 1;
                }
            }
        }

        /// <summary>
        /// "Existe um vínculo?" para a regra da identidade. Ausente (arquivo/pasta não encontrados) = false; QUALQUER outro
        /// erro (acesso negado, arquivo bloqueado...) propaga, e o repositório da identidade o trata como "há vínculo"
        /// (File.Exists devolveria false nesses casos e permitiria criar outra identidade).
        /// </summary>
        private static bool CredentialFileExists(string path)
        {
            try
            {
                File.GetAttributes(path);
                return true;
            }
            catch (FileNotFoundException)
            {
                return false;
            }
            catch (DirectoryNotFoundException)
            {
                return false;
            }
        }

        /// <summary>Recusa pastas que sejam links (junction/symlink): o serviço roda como SYSTEM e ajustaria permissões do destino.</summary>
        private static void EnsureNotReparsePoint(string path)
        {
            FileAttributes attributes = File.GetAttributes(path);
            if ((attributes & FileAttributes.ReparsePoint) != 0)
                throw new IOException("A pasta de dados do agente é um link; inicialização recusada por segurança.");
        }

        [SupportedOSPlatform("windows")]
        private static void PrepareFolders(AgentPaths paths)
        {
            Directory.CreateDirectory(paths.Root);
            Directory.CreateDirectory(paths.DataDir);
            Directory.CreateDirectory(paths.LogDir);

            if (AgentPaths.DevelopmentOverrideDir() == null)
            {
                EnsureNotReparsePoint(paths.Root);
                EnsureNotReparsePoint(paths.DataDir);
                EnsureNotReparsePoint(paths.LogDir);
            }

            // A pasta de dados pode ter sido redirecionada (somente desenvolvimento): nesse caso não mexemos nas permissões.
            bool redirected = AgentPaths.DevelopmentOverrideDir() != null;
            if (redirected) return;

            if (FileSecurity.CanManageAcls())
            {
                // Raiz e logs: SYSTEM/Administradores controle total; usuários comuns só leitura.
                // data: SYSTEM/Administradores APENAS (herança desativada).
                FileSecurity.ApplyRootAcl(paths.Root);
                FileSecurity.ApplyRootAcl(paths.LogDir);
                FileSecurity.ApplyDataAcl(paths.DataDir);
            }
        }

        [SupportedOSPlatform("windows")]
        private static void RegisterServices(IServiceCollection services, AgentPaths paths, string installationId, InstallationIdentityStore identityStore, string? identityProblem)
        {
            IClock clock = new SystemClock();
            services.AddSingleton<IClock>(clock);

            // UM HttpClient de vida longa para o processo inteiro (nunca um por requisição).
            // HTTPS obrigatório (validado no EdgeApiClient), TLS 1.2/1.3, sem redirecionamento, validação padrão do certificado.
            SocketsHttpHandler handler = new SocketsHttpHandler();
            handler.AllowAutoRedirect = false;
            handler.UseCookies = false;
            handler.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate;
            handler.PooledConnectionLifetime = TimeSpan.FromMinutes(10);
            handler.ConnectTimeout = TimeSpan.FromSeconds(15);
            handler.SslOptions = new SslClientAuthenticationOptions
            {
                EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13,
            };

            HttpClient http = new HttpClient(handler, true);
            http.BaseAddress = new Uri(AgentConstants.EdgeBaseUrl, UriKind.Absolute);
            http.Timeout = AgentConstants.HttpTimeout;

            services.AddSingleton<IEdgeApi>(new EdgeApiClient(http));

            ISecretProtector protector = new DpapiSecretProtector();
            ICredentialStore credentialStore = new CredentialStore(paths.CredentialFile, protector);
            services.AddSingleton<CredentialVault>(new CredentialVault(credentialStore, clock));
            services.AddSingleton<AgentStateStore>(new AgentStateStore(paths.StateFile));
            services.AddSingleton<IPrinterDiscovery>(new WindowsPrinterDiscovery());
            services.AddSingleton<HostInfo>(HostInfo.FromEnvironment());

            services.AddSingleton<AgentCoordinator>(sp =>
            {
                AgentCoordinator coordinator = new AgentCoordinator(
                    sp.GetRequiredService<IEdgeApi>(),
                    sp.GetRequiredService<IPrinterDiscovery>(),
                    sp.GetRequiredService<CredentialVault>(),
                    sp.GetRequiredService<AgentStateStore>(),
                    installationId,
                    sp.GetRequiredService<HostInfo>(),
                    sp.GetRequiredService<IClock>(),
                    sp.GetRequiredService<ILoggerFactory>().CreateLogger("AgentCoordinator"));
                if (identityProblem != null)
                {
                    coordinator.SetIdentityProblem(identityProblem, identityStore.GetOrCreate);
                }
                return coordinator;
            });
            services.AddSingleton<IAgentController>(sp => sp.GetRequiredService<AgentCoordinator>());

            // ----- Fila de impressão (1.1.0): o serviço consulta, imprime (RAW no spooler) e confirma. Sem Tray, sem navegador. -----
            services.AddSingleton<IPrintActivity>(sp => new PrintActivity(sp.GetRequiredService<IClock>()));
            services.AddSingleton<IPrintedJournal>(sp => new PrintedJournal(
                paths.PrintedJournalFile,
                sp.GetRequiredService<IClock>(),
                sp.GetRequiredService<ILoggerFactory>().CreateLogger("DiarioImpressoes")));
            services.AddSingleton<IRawPrinterWriter>(new WinSpoolRawWriter());
            services.AddSingleton<IPrinterResolver>(sp => new DiscoveryPrinterResolver(sp.GetRequiredService<IPrinterDiscovery>()));
            services.AddSingleton<PrintJobProcessor>(sp => new PrintJobProcessor(
                sp.GetRequiredService<IPrinterResolver>(),
                sp.GetRequiredService<IRawPrinterWriter>(),
                printerName => TicketLayoutSettings.Load(paths.LayoutFile, printerName),
                sp.GetRequiredService<ILoggerFactory>().CreateLogger("Impressao")));
            services.AddSingleton<PrintJobWorker>(sp =>
            {
                AgentCoordinator coordinator = sp.GetRequiredService<AgentCoordinator>();
                IPrintActivity activity = sp.GetRequiredService<IPrintActivity>();
                coordinator.PrintActivity = activity;
                return new PrintJobWorker(
                    sp.GetRequiredService<IEdgeApi>(),
                    coordinator,
                    sp.GetRequiredService<PrintJobProcessor>(),
                    sp.GetRequiredService<IPrintedJournal>(),
                    activity,
                    sp.GetRequiredService<IClock>(),
                    sp.GetRequiredService<ILoggerFactory>().CreateLogger("FilaImpressao"));
            });

            services.AddSingleton<IpcCommandHandler>(sp => new IpcCommandHandler(
                sp.GetRequiredService<IAgentController>(),
                sp.GetRequiredService<ILoggerFactory>().CreateLogger("IpcCommandHandler")));

            services.AddHostedService<AgentWorker>();
            services.AddHostedService<PrintJobWorkerService>();
            services.AddHostedService<IpcServer>();
        }
    }
}
