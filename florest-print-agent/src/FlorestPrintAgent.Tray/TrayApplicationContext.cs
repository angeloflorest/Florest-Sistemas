using System;
using System.Drawing;
using System.Runtime.Versioning;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using FlorestPrintAgent.Core.Agent;
using FlorestPrintAgent.Core.Printers;
using Microsoft.Extensions.Logging;

namespace FlorestPrintAgent.Tray
{
    /// <summary>
    /// Ícone na bandeja do sistema + menu + rotina em segundo plano:
    ///  - consulta o Service a cada poucos segundos (status e lista de impressoras);
    ///  - entrega ao Service as impressoras do usuário logado (ao iniciar, a cada 10 min e quando o usuário pede);
    ///  - "Sair" fecha SOMENTE o Tray: o Service continua rodando.
    /// </summary>
    [SupportedOSPlatform("windows")]
    internal sealed class TrayApplicationContext : ApplicationContext
    {
        private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(5);
        private static readonly TimeSpan UserSubmitInterval = TimeSpan.FromMinutes(10);
        private static readonly TimeSpan UserSubmitRetryAfterDiscoveryFailure = TimeSpan.FromMinutes(2);

        private readonly TrayController _controller;
        private readonly ILogger _log;
        private readonly EventWaitHandle _showSignal;
        private readonly CancellationTokenSource _cts = new CancellationTokenSource();
        private readonly NotifyIcon _notify;
        private readonly ContextMenuStrip _menu;
        private readonly MainForm _form;
        private readonly System.Windows.Forms.Timer _pollTimer = new System.Windows.Forms.Timer();
        private readonly System.Windows.Forms.Timer _signalTimer = new System.Windows.Forms.Timer();

        private bool _polling;
        private bool _autoScanDone;
        private bool _exiting;
        private DateTime _nextUserSubmitUtc = DateTime.MinValue;

        public TrayApplicationContext(TrayController controller, ILogger log, EventWaitHandle showSignal, bool startMinimized)
        {
            _controller = controller;
            _log = log;
            _showSignal = showSignal;

            _form = new MainForm(controller, StatusIcons.For(AgentStatusKind.NaoVinculado));

            _menu = new ContextMenuStrip();
            ToolStripMenuItem open = new ToolStripMenuItem("Abrir Florest Print Agent");
            open.Font = new Font(open.Font, FontStyle.Bold);
            open.Click += delegate { ShowWindow(); };
            ToolStripMenuItem scan = new ToolStripMenuItem("Buscar impressoras");
            scan.Click += OnScanMenuClick;
            ToolStripMenuItem status = new ToolStripMenuItem("Status");
            status.Click += delegate { ShowStatusDialog(); };
            ToolStripMenuItem exit = new ToolStripMenuItem("Sair");
            exit.Click += delegate { ExitTrayOnly(); };
            _menu.Items.Add(open);
            _menu.Items.Add(scan);
            _menu.Items.Add(status);
            _menu.Items.Add(new ToolStripSeparator());
            _menu.Items.Add(exit);

            _notify = new NotifyIcon();
            _notify.ContextMenuStrip = _menu;
            _notify.Icon = StatusIcons.For(AgentStatusKind.NaoVinculado);
            _notify.Text = "Florest Print Agent";
            _notify.DoubleClick += delegate { ShowWindow(); };
            _notify.Visible = true;

            _controller.SnapshotChanged += OnSnapshotChanged;

            _pollTimer.Interval = 500; // primeira consulta logo que o laço de mensagens iniciar; depois, PollInterval
            _pollTimer.Tick += OnPollTick;
            _pollTimer.Start();

            // outra instância (ex.: atalho do menu Iniciar) pede para mostrar a janela por este sinal
            _signalTimer.Interval = 700;
            _signalTimer.Tick += OnSignalTick;
            _signalTimer.Start();

            if (!startMinimized) ShowWindow();
        }

        // ------------------------------------------------------------------------------------------------------
        // Rotina em segundo plano
        // ------------------------------------------------------------------------------------------------------

        private async void OnPollTick(object? sender, EventArgs e)
        {
            if (_polling || _exiting) return;
            int regular = (int)PollInterval.TotalMilliseconds;
            if (_pollTimer.Interval != regular) _pollTimer.Interval = regular;
            _polling = true;
            try
            {
                CancellationToken ct = _cts.Token;
                await _controller.RefreshAsync(ct);

                AgentSnapshot snapshot = _controller.Last;
                if (snapshot.Status == null) return; // serviço fora do ar: tenta de novo no próximo ciclo

                DateTime now = DateTime.UtcNow;
                if (now >= _nextUserSubmitUtc)
                {
                    UserSubmitResult result = await _controller.SubmitUserPrintersAsync(ct);
                    switch (result)
                    {
                        case UserSubmitResult.Sent:
                            _nextUserSubmitUtc = now + UserSubmitInterval;
                            break;
                        case UserSubmitResult.DiscoveryFailed:
                            _nextUserSubmitUtc = now + UserSubmitRetryAfterDiscoveryFailure;
                            break;
                        default:
                            _nextUserSubmitUtc = DateTime.MinValue; // serviço não aceitou: tenta no próximo ciclo
                            break;
                    }
                }

                // Sem vínculo o Service não sincroniza sozinho; faz uma detecção local uma vez para a janela já mostrar as impressoras.
                snapshot = _controller.Last;
                if (!_autoScanDone && snapshot.Status != null && !snapshot.Status.Vinculado && snapshot.Printers.Count == 0)
                {
                    _autoScanDone = true;
                    await _controller.ScanAsync(ct);
                }
            }
            catch (OperationCanceledException)
            {
                // saindo
            }
            catch (Exception ex)
            {
                _log.LogWarning("Falha no ciclo do Tray ({Tipo}).", ex.GetType().Name);
            }
            finally
            {
                _polling = false;
            }
        }

        private void OnSignalTick(object? sender, EventArgs e)
        {
            try
            {
                if (_showSignal.WaitOne(0)) ShowWindow();
            }
            catch (Exception)
            {
                // sinal indisponível: ignora
            }
        }

        private void OnSnapshotChanged(object? sender, EventArgs e)
        {
            AgentSnapshot snapshot = _controller.Last;
            string kind = snapshot.Kind;
            try
            {
                _notify.Icon = StatusIcons.For(kind);
                _notify.Text = TrimTooltip("Florest Print Agent - " + StatusLabel(kind));
            }
            catch (Exception)
            {
                // ícone indisponível: ignora
            }
        }

        // ------------------------------------------------------------------------------------------------------
        // Menu
        // ------------------------------------------------------------------------------------------------------

        private void ShowWindow()
        {
            _form.ShowWindow();
        }

        private async void OnScanMenuClick(object? sender, EventArgs e)
        {
            try
            {
                ShowWindow();
                await _form.StartScanAsync();
            }
            catch (Exception ex)
            {
                _log.LogWarning("Falha ao buscar impressoras pelo menu ({Tipo}).", ex.GetType().Name);
            }
        }

        private void ShowStatusDialog()
        {
            AgentSnapshot snapshot = _controller.Last;
            string text;
            if (snapshot.Status == null)
            {
                text = "Estado: Erro\n" + (snapshot.ServiceError ?? "O serviço não está respondendo.");
            }
            else
            {
                AgentStatusDto s = snapshot.Status;
                text = "Estado: " + StatusLabel(s.Estado)
                    + "\nComputador: " + s.Computador
                    + "\nEmpresa: " + (string.IsNullOrEmpty(s.Empresa) ? "—" : s.Empresa)
                    + "\nEstação: " + (string.IsNullOrEmpty(s.Estacao) ? "—" : s.Estacao)
                    + "\nImpressoras detectadas: " + snapshot.Printers.Count.ToString(System.Globalization.CultureInfo.InvariantCulture);
                bool printError;
                string printText = PrintStatusText.Describe(s, out printError);
                if (printText != "—") text += "\n" + (printError ? string.Empty : "Última impressão: ") + printText;
                if (!string.IsNullOrEmpty(s.Mensagem)) text += "\n\n" + s.Mensagem;
            }
            MessageBox.Show(text, "Florest Print Agent", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        private void ExitTrayOnly()
        {
            if (_exiting) return;
            _exiting = true;
            _cts.Cancel();
            _pollTimer.Stop();
            _signalTimer.Stop();
            _notify.Visible = false;
            // só o Tray termina; o serviço do Windows continua em execução
            ExitThread();
        }

        private static string StatusLabel(string kind)
        {
            switch (kind)
            {
                case AgentStatusKind.Conectado: return "Conectado";
                case AgentStatusKind.SemConexao: return "Sem conexão";
                case AgentStatusKind.NaoVinculado: return "Não vinculado";
                default: return "Erro";
            }
        }

        private static string TrimTooltip(string text)
        {
            // limite do Windows para o texto do ícone: 63 caracteres
            return text.Length <= 63 ? text : text.Substring(0, 63);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                _controller.SnapshotChanged -= OnSnapshotChanged;
                _pollTimer.Dispose();
                _signalTimer.Dispose();
                _notify.Visible = false;
                _notify.Dispose();
                _menu.Dispose();
                _form.Dispose();
                _cts.Dispose();
            }
            base.Dispose(disposing);
        }
    }
}
