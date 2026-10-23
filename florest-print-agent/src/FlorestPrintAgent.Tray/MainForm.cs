using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using FlorestPrintAgent.Core;
using FlorestPrintAgent.Core.Agent;
using FlorestPrintAgent.Core.Printers;
using FlorestPrintAgent.Core.Security;

namespace FlorestPrintAgent.Tray
{
    /// <summary>
    /// Janela "FLOREST PRINT AGENT": estado, dados do computador, impressoras detectadas e os botões
    /// Buscar impressoras / Conectar ao Florest ERP / Desvincular. Nunca mostra token nem credencial.
    /// Fechar a janela só a esconde (o Tray continua na bandeja); "Sair" fica no menu da bandeja.
    /// </summary>
    internal sealed class MainForm : Form
    {
        private enum PairingStep
        {
            Hidden,
            EnterCode,
            Confirm,
        }

        private readonly TrayController _controller;
        private readonly CancellationTokenSource _cts = new CancellationTokenSource();

        private readonly Label _lblStatus = new Label();
        private readonly Label _valComputador = new Label();
        private readonly Label _valEmpresa = new Label();
        private readonly Label _valEstacao = new Label();
        private readonly Label _valUltima = new Label();
        private readonly Label _valImpressao = new Label();
        private readonly Label _valVersao = new Label();
        private readonly Label _lblMensagem = new Label();

        private readonly Button _btnBuscar = new Button();
        private readonly Button _btnDesvincular = new Button();
        private readonly Button _btnConectar = new Button();

        private readonly GroupBox _grpPareamento = new GroupBox();
        private readonly TextBox _txtCodigo = new TextBox();
        private readonly Button _btnVerificar = new Button();
        private readonly Label _lblConfirmar = new Label();
        private readonly Button _btnConfirmar = new Button();
        private readonly Button _btnCancelar = new Button();
        private readonly FlowLayoutPanel _rowCodigo = new FlowLayoutPanel();
        private readonly FlowLayoutPanel _rowConfirmar = new FlowLayoutPanel();

        private readonly ListView _lvImpressoras = new ListView();

        private PairingStep _step = PairingStep.Hidden;
        private bool _busy;
        private string _printersKey = string.Empty;
        private string _messageText = string.Empty;
        private bool _messageIsError;

        public MainForm(TrayController controller, Icon icon)
        {
            _controller = controller;

            Text = "Florest Print Agent";
            Icon = icon;
            AutoScaleDimensions = new SizeF(96F, 96F);
            AutoScaleMode = AutoScaleMode.Dpi;
            Font = new Font("Segoe UI", 9F);
            StartPosition = FormStartPosition.CenterScreen;
            MinimumSize = new Size(760, 600);
            ClientSize = new Size(800, 640);
            ShowInTaskbar = true;

            BuildLayout();

            _controller.SnapshotChanged += OnSnapshotChanged;
            ApplySnapshot(_controller.Last);
        }

        // ------------------------------------------------------------------------------------------------------
        // Montagem da tela
        // ------------------------------------------------------------------------------------------------------

        private void BuildLayout()
        {
            TableLayoutPanel root = new TableLayoutPanel();
            root.Dock = DockStyle.Fill;
            root.Padding = new Padding(16);
            root.ColumnCount = 1;
            root.RowCount = 6;
            root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            for (int i = 0; i < 5; i++) root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            root.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));

            // 0 - título e estado
            FlowLayoutPanel header = new FlowLayoutPanel();
            header.FlowDirection = FlowDirection.TopDown;
            header.WrapContents = false;
            header.AutoSize = true;
            header.Dock = DockStyle.Top;
            Label title = new Label();
            title.Text = "FLOREST PRINT AGENT";
            title.Font = new Font("Segoe UI", 15F, FontStyle.Bold);
            title.AutoSize = true;
            _lblStatus.Font = new Font("Segoe UI", 11F, FontStyle.Bold);
            _lblStatus.AutoSize = true;
            _lblStatus.Margin = new Padding(3, 4, 3, 8);
            header.Controls.Add(title);
            header.Controls.Add(_lblStatus);
            root.Controls.Add(header, 0, 0);

            // 1 - dados
            TableLayoutPanel info = new TableLayoutPanel();
            info.ColumnCount = 2;
            info.RowCount = 6;
            info.AutoSize = true;
            info.Dock = DockStyle.Top;
            info.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 150F));
            info.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            AddInfoRow(info, 0, "Computador:", _valComputador);
            AddInfoRow(info, 1, "Empresa:", _valEmpresa);
            AddInfoRow(info, 2, "Estação:", _valEstacao);
            AddInfoRow(info, 3, "Última comunicação:", _valUltima);
            AddInfoRow(info, 4, "Última impressão:", _valImpressao);
            AddInfoRow(info, 5, "Versão:", _valVersao);
            root.Controls.Add(info, 0, 1);

            // 2 - mensagem
            _lblMensagem.Dock = DockStyle.Top;
            _lblMensagem.AutoSize = false;
            _lblMensagem.Height = 44;
            _lblMensagem.Margin = new Padding(3, 8, 3, 4);
            root.Controls.Add(_lblMensagem, 0, 2);

            // 3 - botões
            FlowLayoutPanel buttons = new FlowLayoutPanel();
            buttons.FlowDirection = FlowDirection.LeftToRight;
            buttons.AutoSize = true;
            buttons.Dock = DockStyle.Top;
            ConfigureButton(_btnBuscar, "Buscar impressoras", OnBuscarClick);
            ConfigureButton(_btnConectar, "Conectar ao Florest ERP", OnConectarClick);
            ConfigureButton(_btnDesvincular, "Desvincular", OnDesvincularClick);
            buttons.Controls.Add(_btnBuscar);
            buttons.Controls.Add(_btnConectar);
            buttons.Controls.Add(_btnDesvincular);
            root.Controls.Add(buttons, 0, 3);

            // 4 - pareamento
            _grpPareamento.Text = "Conectar ao Florest ERP";
            _grpPareamento.Dock = DockStyle.Top;
            _grpPareamento.AutoSize = true;
            _grpPareamento.Padding = new Padding(10);
            _grpPareamento.Visible = false;

            FlowLayoutPanel pairingFlow = new FlowLayoutPanel();
            pairingFlow.FlowDirection = FlowDirection.TopDown;
            pairingFlow.WrapContents = false;
            pairingFlow.AutoSize = true;
            pairingFlow.Dock = DockStyle.Top;

            _rowCodigo.FlowDirection = FlowDirection.LeftToRight;
            _rowCodigo.AutoSize = true;
            Label lblCodigo = new Label();
            lblCodigo.Text = "Código de pareamento:";
            lblCodigo.AutoSize = true;
            lblCodigo.Margin = new Padding(3, 8, 3, 3);
            _txtCodigo.Width = 130;
            _txtCodigo.MaxLength = 9;
            _txtCodigo.CharacterCasing = CharacterCasing.Upper;
            _txtCodigo.PlaceholderText = "XXXX-XXXX";
            _txtCodigo.Font = new Font("Consolas", 11F);
            _txtCodigo.KeyDown += OnCodigoKeyDown;
            ConfigureButton(_btnVerificar, "Verificar", OnVerificarClick);
            _rowCodigo.Controls.Add(lblCodigo);
            _rowCodigo.Controls.Add(_txtCodigo);
            _rowCodigo.Controls.Add(_btnVerificar);

            _lblConfirmar.AutoSize = true;
            _lblConfirmar.Font = new Font("Segoe UI", 10F, FontStyle.Bold);
            _lblConfirmar.Margin = new Padding(3, 8, 3, 8);
            _lblConfirmar.Visible = false;

            _rowConfirmar.FlowDirection = FlowDirection.LeftToRight;
            _rowConfirmar.AutoSize = true;
            ConfigureButton(_btnConfirmar, "Confirmar conexão", OnConfirmarClick);
            ConfigureButton(_btnCancelar, "Cancelar", OnCancelarClick);
            _rowConfirmar.Controls.Add(_btnConfirmar);
            _rowConfirmar.Controls.Add(_btnCancelar);
            _rowConfirmar.Visible = false;

            pairingFlow.Controls.Add(_rowCodigo);
            pairingFlow.Controls.Add(_lblConfirmar);
            pairingFlow.Controls.Add(_rowConfirmar);
            _grpPareamento.Controls.Add(pairingFlow);
            root.Controls.Add(_grpPareamento, 0, 4);

            // 5 - impressoras
            _lvImpressoras.Dock = DockStyle.Fill;
            _lvImpressoras.View = View.Details;
            _lvImpressoras.FullRowSelect = true;
            _lvImpressoras.GridLines = true;
            _lvImpressoras.HideSelection = false;
            _lvImpressoras.MultiSelect = false;
            _lvImpressoras.Margin = new Padding(3, 10, 3, 3);
            _lvImpressoras.Columns.Add("Nome", 280);
            _lvImpressoras.Columns.Add("Conexão", 110);
            _lvImpressoras.Columns.Add("Porta", 230);
            _lvImpressoras.Columns.Add("Status", 110);
            root.Controls.Add(_lvImpressoras, 0, 5);

            Controls.Add(root);
        }

        private static void AddInfoRow(TableLayoutPanel table, int row, string caption, Label value)
        {
            table.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            Label name = new Label();
            name.Text = caption;
            name.AutoSize = true;
            name.ForeColor = Color.FromArgb(75, 85, 99);
            name.Margin = new Padding(3, 3, 3, 3);
            value.AutoSize = true;
            value.Margin = new Padding(3, 3, 3, 3);
            table.Controls.Add(name, 0, row);
            table.Controls.Add(value, 1, row);
        }

        private static void ConfigureButton(Button button, string text, EventHandler onClick)
        {
            button.Text = text;
            button.AutoSize = true;
            button.AutoSizeMode = AutoSizeMode.GrowAndShrink;
            button.Padding = new Padding(10, 3, 10, 3);
            button.Margin = new Padding(3, 3, 8, 3);
            button.UseVisualStyleBackColor = true;
            button.Click += onClick;
        }

        // ------------------------------------------------------------------------------------------------------
        // Atualização da tela
        // ------------------------------------------------------------------------------------------------------

        private void OnSnapshotChanged(object? sender, EventArgs e)
        {
            if (IsDisposed) return;
            ApplySnapshot(_controller.Last);
        }

        private void ApplySnapshot(AgentSnapshot snapshot)
        {
            AgentStatusDto? status = snapshot.Status;

            _valComputador.Text = status != null && status.Computador.Length > 0 ? status.Computador : Environment.MachineName;
            _valEmpresa.Text = status != null && !string.IsNullOrEmpty(status.Empresa) ? status.Empresa : "—";
            _valEstacao.Text = status != null && !string.IsNullOrEmpty(status.Estacao) ? status.Estacao : "—";
            _valUltima.Text = FormatTime(status != null ? status.UltimaComunicacaoUtc : null);
            _valVersao.Text = status != null ? status.Versao : AgentConstants.AgentVersion;
            bool printError;
            _valImpressao.Text = PrintStatusText.Describe(status, out printError);
            _valImpressao.ForeColor = printError ? Color.FromArgb(185, 28, 28) : SystemColors.ControlText;

            string kind = snapshot.Kind;
            _lblStatus.Text = "● " + StatusText(kind);
            _lblStatus.ForeColor = StatusIcons.ColorFor(kind);

            // mensagem: a do estado do serviço tem prioridade quando há erro; senão, a da última operação
            string? serviceMessage = status != null ? status.Mensagem : snapshot.ServiceError;
            if (!string.IsNullOrEmpty(serviceMessage) && (status == null || kind == AgentStatusKind.Erro || kind == AgentStatusKind.SemConexao))
            {
                ShowMessage(serviceMessage, true);
            }
            else if (_messageText.Length > 0)
            {
                ShowMessage(_messageText, _messageIsError);
            }
            else if (!string.IsNullOrEmpty(serviceMessage))
            {
                ShowMessage(serviceMessage, false);
            }
            else
            {
                ShowMessage(string.Empty, false);
            }

            bool reachable = status != null;
            bool linked = status != null && status.Vinculado;

            if (linked && _step != PairingStep.Hidden) SetPairingStep(PairingStep.Hidden);
            UpdateButtons(reachable, linked);

            UpdatePrinterList(snapshot.Printers);
        }

        private void UpdateButtons(bool reachable, bool linked)
        {
            _btnBuscar.Enabled = reachable && !_busy;
            _btnDesvincular.Visible = linked;
            _btnDesvincular.Enabled = reachable && !_busy;
            _btnConectar.Visible = reachable && !linked && _step == PairingStep.Hidden;
            _btnConectar.Enabled = !_busy;

            bool pairingBusy = _busy;
            _btnVerificar.Enabled = !pairingBusy;
            _btnConfirmar.Enabled = !pairingBusy;
            _btnCancelar.Enabled = !pairingBusy;
            _txtCodigo.Enabled = !pairingBusy;
        }

        private void RefreshButtons()
        {
            AgentSnapshot snap = _controller.Last;
            UpdateButtons(snap.Status != null, snap.Status != null && snap.Status.Vinculado);
        }

        private void UpdatePrinterList(List<PrinterInfo> printers)
        {
            StringBuilder key = new StringBuilder();
            foreach (PrinterInfo p in printers)
            {
                key.Append(p.Identificador).Append('|').Append(p.Nome).Append('|').Append(p.Conexao).Append('|')
                   .Append(p.PortaWindows).Append('|').Append(p.Ip).Append('|').Append(p.Porta).Append('|').Append(p.Status).Append('\n');
            }
            string newKey = key.ToString();
            if (string.Equals(newKey, _printersKey, StringComparison.Ordinal)) return;
            _printersKey = newKey;

            _lvImpressoras.BeginUpdate();
            try
            {
                _lvImpressoras.Items.Clear();
                foreach (PrinterInfo p in printers.OrderBy(x => x.Nome, StringComparer.CurrentCultureIgnoreCase))
                {
                    ListViewItem item = new ListViewItem(p.Nome);
                    item.SubItems.Add(ConnectionText(p.Conexao));
                    item.SubItems.Add(PortText(p));
                    item.SubItems.Add(PrinterStatusText(p.Status));
                    _lvImpressoras.Items.Add(item);
                }
            }
            finally
            {
                _lvImpressoras.EndUpdate();
            }
        }

        private void ShowMessage(string text, bool isError)
        {
            _lblMensagem.Text = text;
            _lblMensagem.ForeColor = isError ? Color.FromArgb(185, 28, 28) : Color.FromArgb(55, 65, 81);
        }

        private void SetOperationMessage(string text, bool isError)
        {
            _messageText = text;
            _messageIsError = isError;
            ShowMessage(text, isError);
        }

        private static string StatusText(string kind)
        {
            switch (kind)
            {
                case AgentStatusKind.Conectado: return "Conectado";
                case AgentStatusKind.SemConexao: return "Sem conexão";
                case AgentStatusKind.NaoVinculado: return "Não vinculado";
                default: return "Erro";
            }
        }

        private static string FormatTime(DateTime? utc)
        {
            if (!utc.HasValue) return "—";
            DateTime local = DateTime.SpecifyKind(utc.Value, DateTimeKind.Utc).ToLocalTime();
            return local.ToString("dd/MM/yyyy HH:mm:ss", CultureInfo.InvariantCulture);
        }

        private static string ConnectionText(string connection)
        {
            switch (connection)
            {
                case PrinterConnection.Usb: return "USB";
                case PrinterConnection.Rede: return "Rede";
                case PrinterConnection.Compartilhada: return "Compartilhada";
                case PrinterConnection.Windows: return "Windows";
                default: return "Outro";
            }
        }

        private static string PrinterStatusText(string status)
        {
            switch (status)
            {
                case PrinterStatus.Disponivel: return "Disponível";
                case PrinterStatus.Offline: return "Offline";
                case PrinterStatus.Erro: return "Erro";
                default: return "Desconhecido";
            }
        }

        private static string PortText(PrinterInfo p)
        {
            string port = p.PortaWindows ?? string.Empty;
            if (!string.IsNullOrEmpty(p.Ip))
            {
                string address = p.Porta.HasValue ? p.Ip + ":" + p.Porta.Value.ToString(CultureInfo.InvariantCulture) : p.Ip;
                return port.Length > 0 ? port + " (" + address + ")" : address;
            }
            return port;
        }

        // ------------------------------------------------------------------------------------------------------
        // Pareamento
        // ------------------------------------------------------------------------------------------------------

        private void SetPairingStep(PairingStep step)
        {
            _step = step;
            _grpPareamento.Visible = step != PairingStep.Hidden;
            _rowCodigo.Visible = step == PairingStep.EnterCode;
            _lblConfirmar.Visible = step == PairingStep.Confirm;
            _rowConfirmar.Visible = step == PairingStep.Confirm;
            if (step == PairingStep.Hidden)
            {
                _txtCodigo.Text = string.Empty; // o código nunca fica guardado
                _lblConfirmar.Text = string.Empty;
            }
            RefreshButtons();
            if (step == PairingStep.EnterCode) _txtCodigo.Focus();
        }

        private void OnConectarClick(object? sender, EventArgs e)
        {
            _txtCodigo.Text = string.Empty;
            SetOperationMessage(string.Empty, false);
            SetPairingStep(PairingStep.EnterCode);
        }

        private void OnCancelarClick(object? sender, EventArgs e)
        {
            SetOperationMessage(string.Empty, false);
            SetPairingStep(PairingStep.Hidden);
        }

        private void OnCodigoKeyDown(object? sender, KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Enter)
            {
                e.SuppressKeyPress = true;
                OnVerificarClick(sender, EventArgs.Empty);
            }
        }

        private async void OnVerificarClick(object? sender, EventArgs e)
        {
            if (_busy) return;
            string code;
            if (!PairingCode.TryNormalize(_txtCodigo.Text, out code))
            {
                SetOperationMessage("Digite o código no formato XXXX-XXXX (gerado no Florest ERP).", true);
                return;
            }

            await RunBusyAsync(async () =>
            {
                SetOperationMessage("Verificando o código...", false);
                OperationOutcome r = await _controller.VerifyPairingAsync(code, _cts.Token);
                if (!r.Ok || r.Preview == null)
                {
                    SetOperationMessage(r.Message, true);
                    return;
                }

                string text = "Conectar este computador à empresa " + r.Preview.Empresa + "?";
                if (!string.IsNullOrEmpty(r.Preview.Estacao)) text += "\nEstação: " + r.Preview.Estacao;
                if (r.Preview.Reinstalacao) text += "\nEste computador já esteve vinculado; a instalação anterior será substituída.";
                _lblConfirmar.Text = text;
                _txtCodigo.Text = code;
                SetOperationMessage(string.Empty, false);
                SetPairingStep(PairingStep.Confirm);
            });
        }

        private async void OnConfirmarClick(object? sender, EventArgs e)
        {
            if (_busy) return;
            string code;
            if (!PairingCode.TryNormalize(_txtCodigo.Text, out code))
            {
                SetOperationMessage("O código não é mais válido. Digite novamente.", true);
                SetPairingStep(PairingStep.EnterCode);
                return;
            }

            await RunBusyAsync(async () =>
            {
                SetOperationMessage("Conectando...", false);
                OperationOutcome r = await _controller.ConfirmPairingAsync(code, _cts.Token);
                if (r.Ok)
                {
                    SetOperationMessage(r.Message, false);
                    SetPairingStep(PairingStep.Hidden);
                }
                else
                {
                    SetOperationMessage(r.Message, true);
                    if (r.Erro == "codigo_invalido" || r.Erro == "pareamento_nao_verificado" || r.Erro == "pareamento_em_andamento")
                        SetPairingStep(PairingStep.EnterCode);
                }
            });
        }

        // ------------------------------------------------------------------------------------------------------
        // Buscar impressoras e desvincular
        // ------------------------------------------------------------------------------------------------------

        private async void OnBuscarClick(object? sender, EventArgs e)
        {
            await StartScanAsync();
        }

        /// <summary>Usado também pelo menu da bandeja.</summary>
        public async Task StartScanAsync()
        {
            if (_busy) return;
            await RunBusyAsync(async () =>
            {
                SetOperationMessage("Buscando impressoras...", false);
                OperationOutcome r = await _controller.ScanAsync(_cts.Token);
                SetOperationMessage(r.Message, !r.Ok);
            });
        }

        private async void OnDesvincularClick(object? sender, EventArgs e)
        {
            if (_busy) return;
            DialogResult answer = MessageBox.Show(
                this,
                "Desvincular este computador do Florest ERP?\n\nAs impressoras deste computador deixarão de ser atualizadas no sistema até que ele seja conectado novamente.",
                "Desvincular",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Question,
                MessageBoxDefaultButton.Button2);
            if (answer != DialogResult.Yes) return;

            await RunBusyAsync(async () =>
            {
                SetOperationMessage("Desvinculando...", false);
                OperationOutcome r = await _controller.UnlinkAsync(false, _cts.Token);
                if (r.Ok)
                {
                    SetOperationMessage(r.Message, false);
                    return;
                }

                if (r.Erro == "credencial_recusada" || r.Erro == "identidade_invalida")
                {
                    DialogResult force = MessageBox.Show(
                        this,
                        r.Message + "\n\nRemover o vínculo apenas deste computador?",
                        "Desvincular",
                        MessageBoxButtons.YesNo,
                        MessageBoxIcon.Warning,
                        MessageBoxDefaultButton.Button2);
                    if (force == DialogResult.Yes)
                    {
                        OperationOutcome forced = await _controller.UnlinkAsync(true, _cts.Token);
                        SetOperationMessage(forced.Message, !forced.Ok);
                        return;
                    }
                }

                // servidor indisponível ou recusa: o vínculo foi mantido e o usuário é avisado
                SetOperationMessage(r.Message, true);
            });
        }

        private async Task RunBusyAsync(Func<Task> action)
        {
            _busy = true;
            UseWaitCursor = true;
            RefreshButtons();
            try
            {
                await action();
            }
            catch (OperationCanceledException)
            {
                // janela fechando
            }
            catch (Exception)
            {
                SetOperationMessage("Ocorreu um erro inesperado. Tente novamente.", true);
            }
            finally
            {
                _busy = false;
                UseWaitCursor = false;
                if (!IsDisposed) RefreshButtons();
            }
        }

        // ------------------------------------------------------------------------------------------------------
        // Janela
        // ------------------------------------------------------------------------------------------------------

        /// <summary>Mostra a janela e a traz para frente.</summary>
        public void ShowWindow()
        {
            if (!Visible) Show();
            if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
            ApplySnapshot(_controller.Last);
            Activate();
            BringToFront();
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (e.CloseReason == CloseReason.UserClosing)
            {
                // o "X" só esconde a janela; para sair do Tray use o menu da bandeja
                e.Cancel = true;
                Hide();
                return;
            }
            base.OnFormClosing(e);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                _controller.SnapshotChanged -= OnSnapshotChanged;
                _cts.Cancel();
                _cts.Dispose();
            }
            base.Dispose(disposing);
        }
    }
}
