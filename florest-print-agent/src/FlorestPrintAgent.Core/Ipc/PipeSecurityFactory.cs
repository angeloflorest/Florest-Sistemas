using System;
using System.IO.Pipes;
using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Principal;

namespace FlorestPrintAgent.Core.Ipc
{
    /// <summary>
    /// Proteção (ACL) do Named Pipe do Service:
    ///  - Deny NETWORK (logon de rede nunca acessa);
    ///  - SYSTEM, Administradores e a identidade do próprio processo: controle total (só eles criam instâncias do pipe);
    ///  - usuários com logon INTERATIVO (console/RDP): somente ler/escrever (+ Synchronize) — o Tray de um usuário comum.
    /// Quem pode fazer o QUÊ depois de conectar é decidido pelo AgentCoordinator, com a identidade obtida do Windows.
    /// </summary>
    [SupportedOSPlatform("windows")]
    public static class PipeSecurityFactory
    {
        public static PipeSecurity Create()
        {
            PipeSecurity security = new PipeSecurity();

            // Negações primeiro: logon de rede nunca acessa este pipe.
            security.AddAccessRule(new PipeAccessRule(
                new SecurityIdentifier(WellKnownSidType.NetworkSid, null),
                PipeAccessRights.FullControl,
                AccessControlType.Deny));

            security.AddAccessRule(new PipeAccessRule(
                new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
                PipeAccessRights.FullControl,
                AccessControlType.Allow));

            security.AddAccessRule(new PipeAccessRule(
                new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null),
                PipeAccessRights.FullControl,
                AccessControlType.Allow));

            // A identidade que executa este processo (LocalSystem no serviço; o próprio desenvolvedor no modo console)
            // precisa poder criar as próximas instâncias do pipe.
            using (WindowsIdentity self = WindowsIdentity.GetCurrent())
            {
                if (self.User != null)
                {
                    security.AddAccessRule(new PipeAccessRule(self.User, PipeAccessRights.FullControl, AccessControlType.Allow));
                }
            }

            // Usuários que fizeram logon na máquina (console ou área de trabalho remota): só ler/escrever.
            security.AddAccessRule(new PipeAccessRule(
                new SecurityIdentifier(WellKnownSidType.InteractiveSid, null),
                PipeAccessRights.ReadWrite | PipeAccessRights.Synchronize,
                AccessControlType.Allow));

            return security;
        }
    }
}
