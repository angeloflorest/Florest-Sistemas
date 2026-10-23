using System;
using System.Threading;
using System.Windows.Forms;
using FlorestPrintAgent.Core;
using FlorestPrintAgent.Core.Ipc;
using FlorestPrintAgent.Core.Logging;
using FlorestPrintAgent.Core.Printers;
using Microsoft.Extensions.Logging;

namespace FlorestPrintAgent.Tray
{
    /// <summary>
    /// Florest Print Agent — Tray (ícone na bandeja e janela). Um Tray por sessão de usuário.
    /// Parâmetro --minimized: inicia só com o ícone (usado pela inicialização automática do Windows).
    /// </summary>
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            if (!OperatingSystem.IsWindows())
            {
                return 2;
            }
            return RunWindows(args);
        }

        [System.Runtime.Versioning.SupportedOSPlatform("windows")]
        private static int RunWindows(string[] args)
        {
            bool minimized = false;
            foreach (string arg in args)
            {
                if (string.Equals(arg, "--minimized", StringComparison.OrdinalIgnoreCase)) minimized = true;
            }

            // Um Tray por sessão de usuário (o prefixo Local\ do mutex é por sessão).
            bool createdNew;
            using (Mutex singleInstance = new Mutex(false, AgentConstants.TrayMutexName, out createdNew))
            {
                if (!createdNew)
                {
                    if (!minimized) SignalExistingInstance();
                    return 0;
                }

                FileLoggerProvider logProvider = new FileLoggerProvider(AgentPaths.CreateTrayLogDir(), "tray");
                ILogger log = logProvider.CreateLogger("Tray");

                Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
                Application.ThreadException += delegate (object sender, ThreadExceptionEventArgs e)
                {
                    log.LogError("Erro não tratado na interface ({Tipo}).", e.Exception.GetType().Name);
                };
                AppDomain.CurrentDomain.UnhandledException += delegate (object sender, UnhandledExceptionEventArgs e)
                {
                    Exception? ex = e.ExceptionObject as Exception;
                    log.LogCritical("Erro fatal no Tray ({Tipo}).", ex != null ? ex.GetType().Name : "desconhecido");
                };

                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.SetHighDpiMode(HighDpiMode.SystemAware);

                try
                {
                    log.LogInformation("Tray iniciado (versão {Versao}).", AgentConstants.AgentVersion);

                    AgentClient client = new AgentClient(new IpcClient());
                    IPrinterDiscovery discovery = new WindowsPrinterDiscovery();
                    TrayController controller = new TrayController(client, discovery, log);

                    using (EventWaitHandle showSignal = new EventWaitHandle(false, EventResetMode.AutoReset, AgentConstants.TrayShowEventName))
                    using (TrayApplicationContext context = new TrayApplicationContext(controller, log, showSignal, minimized))
                    {
                        Application.Run(context);
                    }

                    log.LogInformation("Tray encerrado.");
                    return 0;
                }
                catch (Exception ex)
                {
                    log.LogCritical("O Tray não conseguiu iniciar ({Tipo}).", ex.GetType().Name);
                    return 1;
                }
            }
        }

        [System.Runtime.Versioning.SupportedOSPlatform("windows")]
        private static void SignalExistingInstance()
        {
            try
            {
                using (EventWaitHandle handle = EventWaitHandle.OpenExisting(AgentConstants.TrayShowEventName))
                {
                    handle.Set();
                }
            }
            catch (Exception)
            {
                // a outra instância ainda está iniciando ou o sinal não existe: nada a fazer
            }
        }
    }
}
