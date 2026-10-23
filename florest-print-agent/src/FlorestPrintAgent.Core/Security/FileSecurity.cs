using System;
using System.IO;
using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Principal;

namespace FlorestPrintAgent.Core.Security
{
    /// <summary>
    /// ACLs das pastas do agente em ProgramData.
    ///   Raiz e logs: SYSTEM e Administradores controle total; usuários comuns somente leitura/lista.
    ///   data:        SYSTEM e Administradores APENAS (herança desativada): o usuário comum não lê nem altera.
    /// A ACL restritiva só é aplicada quando o processo é SYSTEM ou administrador elevado; em modo de desenvolvimento
    /// (usuário comum) é ignorada para não trancar o próprio desenvolvedor fora da pasta.
    /// </summary>
    [SupportedOSPlatform("windows")]
    public static class FileSecurity
    {
        public static bool CanManageAcls()
        {
            using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
            {
                if (identity.IsSystem) return true;
                WindowsPrincipal principal = new WindowsPrincipal(identity);
                return principal.IsInRole(WindowsBuiltInRole.Administrator);
            }
        }

        /// <summary>
        /// Se um usuário comum criou a pasta antes da instalação, ele continuaria DONO dela (e poderia reescrever as permissões).
        /// Passa a propriedade para o grupo Administradores. Falha silenciosa: a ACL restritiva é aplicada em seguida de qualquer forma.
        /// </summary>
        private static void TryTakeOwnership(string path)
        {
            try
            {
                DirectorySecurity owner = new DirectorySecurity();
                owner.SetOwner(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null));
                new DirectoryInfo(path).SetAccessControl(owner);
            }
            catch (Exception ex) when (ex is UnauthorizedAccessException || ex is InvalidOperationException || ex is IOException || ex is PrivilegeNotHeldException)
            {
                // sem privilégio para trocar o dono: segue com a ACL
            }
        }

        public static void ApplyRootAcl(string path)
        {
            TryTakeOwnership(path);
            DirectorySecurity sec = new DirectorySecurity();
            sec.SetAccessRuleProtection(true, false);
            AddAllow(sec, WellKnownSidType.LocalSystemSid, FileSystemRights.FullControl);
            AddAllow(sec, WellKnownSidType.BuiltinAdministratorsSid, FileSystemRights.FullControl);
            AddAllow(sec, WellKnownSidType.BuiltinUsersSid, FileSystemRights.ReadAndExecute);
            new DirectoryInfo(path).SetAccessControl(sec);
        }

        public static void ApplyDataAcl(string path)
        {
            TryTakeOwnership(path);
            DirectorySecurity sec = new DirectorySecurity();
            sec.SetAccessRuleProtection(true, false);
            AddAllow(sec, WellKnownSidType.LocalSystemSid, FileSystemRights.FullControl);
            AddAllow(sec, WellKnownSidType.BuiltinAdministratorsSid, FileSystemRights.FullControl);
            new DirectoryInfo(path).SetAccessControl(sec);
        }

        private static void AddAllow(DirectorySecurity sec, WellKnownSidType sidType, FileSystemRights rights)
        {
            SecurityIdentifier sid = new SecurityIdentifier(sidType, null);
            sec.AddAccessRule(new FileSystemAccessRule(
                sid,
                rights,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
                PropagationFlags.None,
                AccessControlType.Allow));
        }
    }
}
