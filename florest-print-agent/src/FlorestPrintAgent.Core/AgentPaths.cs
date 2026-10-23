using System;
using System.IO;

namespace FlorestPrintAgent.Core
{
    /// <summary>
    /// Pastas e arquivos locais. Padrão: C:\ProgramData\Florest Sistemas\Print Agent\
    ///   data\  identidade, credencial protegida (DPAPI) e estado  (somente SYSTEM e Administradores)
    ///   logs\  logs rotativos                                     (usuários comuns: somente leitura)
    /// </summary>
    public sealed class AgentPaths
    {
        public string Root { get; }
        public string DataDir { get; }
        public string LogDir { get; }
        public string IdentityFile { get; }
        public string CredentialFile { get; }
        public string StateFile { get; }
        /// <summary>Diário local: jobs que JÁ saíram na impressora mas cuja confirmação ao servidor ainda não foi aceita.</summary>
        public string PrintedJournalFile { get; }
        /// <summary>Ajustes opcionais do ticket (colunas, página de código, corte), editáveis por um Administrador.</summary>
        public string LayoutFile { get; }

        public AgentPaths(string root)
        {
            if (string.IsNullOrWhiteSpace(root)) throw new ArgumentException("Pasta raiz inválida.", nameof(root));
            Root = root;
            DataDir = Path.Combine(root, "data");
            LogDir = Path.Combine(root, "logs");
            IdentityFile = Path.Combine(DataDir, "instalacao.json");
            CredentialFile = Path.Combine(DataDir, "credencial.dpapi");
            StateFile = Path.Combine(DataDir, "estado.json");
            PrintedJournalFile = Path.Combine(DataDir, "impressoes-pendentes.json");
            LayoutFile = Path.Combine(DataDir, "impressao.json");
        }

        /// <summary>
        /// Pasta definida por FLORESTPRINTAGENT_DATA_DIR. Só é honrada em compilação DEBUG (desenvolvimento);
        /// em Release a variável é ignorada, para ninguém redirecionar o serviço (LocalSystem) para uma pasta sem proteção.
        /// </summary>
        public static string? DevelopmentOverrideDir()
        {
#if DEBUG
            string? overrideDir = Environment.GetEnvironmentVariable(AgentConstants.DataDirEnvVar);
            if (!string.IsNullOrWhiteSpace(overrideDir)) return overrideDir.Trim();
#endif
            return null;
        }

        /// <summary>Caminho padrão (ProgramData) ou, somente em DEBUG, o definido por FLORESTPRINTAGENT_DATA_DIR.</summary>
        public static AgentPaths CreateDefault()
        {
            string? overrideDir = DevelopmentOverrideDir();
            if (overrideDir != null) return new AgentPaths(overrideDir);
            string common = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
            return new AgentPaths(Path.Combine(common, "Florest Sistemas", "Print Agent"));
        }

        /// <summary>Pasta de logs do Tray (o usuário comum não grava em ProgramData).</summary>
        public static string CreateTrayLogDir()
        {
            string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            return Path.Combine(local, "Florest Sistemas", "Print Agent", "logs");
        }
    }
}
