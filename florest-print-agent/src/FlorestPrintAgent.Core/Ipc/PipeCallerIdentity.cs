using System;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Security.Principal;
using FlorestPrintAgent.Core.Agent;
using Microsoft.Win32.SafeHandles;

namespace FlorestPrintAgent.Core.Ipc
{
    /// <summary>
    /// Descobre QUEM abriu o pipe, perguntando ao Windows (token do cliente) — nunca confiando em texto da mensagem.
    /// O cliente conecta com nível de representação "Identification": o Service consegue consultar o usuário e os grupos,
    /// mas não consegue agir em nome dele.
    /// </summary>
    [SupportedOSPlatform("windows")]
    public static class PipeCallerIdentity
    {
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetNamedPipeClientSessionId(SafePipeHandle pipe, out uint clientSessionId);

        /// <summary>Só pode ser chamado depois de ter LIDO a primeira mensagem do cliente (exigência do Windows para representar o cliente).</summary>
        /// <exception cref="InvalidOperationException">Cliente anônimo/convidado ou identidade indisponível: o pedido deve ser recusado.</exception>
        public static CallerIdentity Identify(NamedPipeServerStream pipe)
        {
            string? sid = null;
            bool isSystem = false;
            bool isAdministrator = false;
            bool anonymous = false;

            pipe.RunAsClient(() =>
            {
                using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
                {
                    anonymous = identity.IsAnonymous || identity.IsGuest;
                    sid = identity.User != null ? identity.User.Value : null;
                    isSystem = identity.IsSystem;
                    try
                    {
                        // true só com token ELEVADO (UAC): um administrador que abriu o Tray normalmente NÃO conta como administrador aqui
                        isAdministrator = new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
                    }
                    catch (Exception)
                    {
                        isAdministrator = false; // na dúvida, sem privilégio
                    }
                }
            });

            if (anonymous || string.IsNullOrEmpty(sid))
                throw new InvalidOperationException("Cliente do pipe sem identidade válida.");

            // Sem o número da sessão, duas sessões do mesmo usuário se confundiriam: recusa (falha fechada).
            uint session;
            if (!GetNamedPipeClientSessionId(pipe.SafePipeHandle, out session))
                throw new InvalidOperationException("Sessão do cliente do pipe indisponível.");
            int sessionId = unchecked((int)session);

            return new CallerIdentity(sid, sessionId, isAdministrator, isSystem);
        }
    }
}
