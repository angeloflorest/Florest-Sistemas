using System;
using System.IO;

namespace FlorestPrintAgent.Core.Storage
{
    /// <summary>
    /// A identidade da instalação (identificador_instalacao) não pôde ser obtida COM SEGURANÇA. Nenhuma identidade nova foi criada.
    ///  - Transient = true : erro temporário de leitura (arquivo bloqueado, permissão); tentar de novo resolve.
    ///  - Transient = false: identidade e cópia ausentes/corrompidas, mas existe um vínculo local (credencial). Criar outro GUID
    ///    deixaria a credencial presa à identidade antiga e o servidor responderia "instalacao_divergente".
    /// A mensagem é segura para exibir ao usuário (não contém segredo).
    /// </summary>
    public sealed class IdentityProblemException : IOException
    {
        public bool Transient { get; }

        public IdentityProblemException(string message, bool transient) : base(message)
        {
            Transient = transient;
        }
    }
}
