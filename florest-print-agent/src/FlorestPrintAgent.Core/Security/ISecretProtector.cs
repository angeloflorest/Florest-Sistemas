using System;
using System.Runtime.Versioning;
using System.Security.Cryptography;
using System.Text;

namespace FlorestPrintAgent.Core.Security
{
    /// <summary>Proteção de segredos em repouso (abstração para permitir testes sem Windows).</summary>
    public interface ISecretProtector
    {
        byte[] Protect(byte[] plain);
        byte[] Unprotect(byte[] protectedData);
    }

    /// <summary>
    /// Windows DPAPI com escopo da MÁQUINA (LocalMachine): o Service (SYSTEM) consegue ler após reiniciar,
    /// independente de qualquer usuário logado. A pasta data\ só é legível por SYSTEM/Administradores (ACL).
    /// </summary>
    [SupportedOSPlatform("windows")]
    public sealed class DpapiSecretProtector : ISecretProtector
    {
        // "Entropia" opcional da DPAPI: amarra o blob a este aplicativo (não é um segredo).
        private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("FlorestPrintAgent.Credential.v1|Florest Sistemas");

        public byte[] Protect(byte[] plain)
        {
            return ProtectedData.Protect(plain, Entropy, DataProtectionScope.LocalMachine);
        }

        public byte[] Unprotect(byte[] protectedData)
        {
            return ProtectedData.Unprotect(protectedData, Entropy, DataProtectionScope.LocalMachine);
        }
    }
}
