using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using FlorestPrintAgent.Core.Printers;

namespace FlorestPrintAgent.Core.Agent
{
    /// <summary>Operações que o Tray pode pedir ao Service (via IPC). O Service continua sendo a única autoridade com o servidor.</summary>
    public interface IAgentController
    {
        AgentStatusDto GetStatus();

        IReadOnlyList<PrinterInfo> GetPrinters();

        /// <summary>POST /pair/verify. O código é normalizado (XXXX-XXXX) antes de chegar aqui.</summary>
        Task<ControllerResult> VerifyPairingAsync(string normalizedCode, CallerIdentity caller, CancellationToken ct);

        /// <summary>POST /pair/confirm. Só aceito se o MESMO chamador (usuário+sessão) verificou o MESMO código há pouco.</summary>
        Task<ControllerResult> ConfirmPairingAsync(string normalizedCode, CallerIdentity caller, CancellationToken ct);

        /// <summary>Descobre as impressoras agora e, se vinculado, sincroniza com o servidor.</summary>
        Task<ControllerResult> ScanPrintersAsync(CancellationToken ct);

        /// <summary>Recebe a lista de impressoras da sessão do usuário (Tray). A lista já veio sanitizada.</summary>
        ControllerResult SubmitUserPrinters(string session, IReadOnlyList<PrinterInfo> printers);

        /// <summary>POST /agent/unlink. Só quem conectou este computador (ou um Administrador elevado) pode; só apaga a credencial local depois do sucesso (ou remoção forçada permitida).</summary>
        Task<ControllerResult> UnlinkAsync(bool force, CallerIdentity caller, CancellationToken ct);
    }
}
