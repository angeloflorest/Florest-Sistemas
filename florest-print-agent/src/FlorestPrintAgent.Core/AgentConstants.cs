using System;

namespace FlorestPrintAgent.Core
{
    /// <summary>
    /// Constantes centrais do agente. O endpoint do servidor existe SOMENTE aqui.
    /// </summary>
    public static class AgentConstants
    {
        public const string ProductName = "Florest Print Agent";
        public const string AgentVersion = "1.2.0";
        public const string UserAgent = "FlorestPrintAgent/" + AgentVersion;

        // Endpoint fixo desta versão (Edge Function publicada, Verify JWT = OFF). A barra final é necessária
        // para que as rotas relativas ("pair/verify", "agent/heartbeat"...) sejam resolvidas abaixo dele.
        public const string EdgeBaseUrl = "https://etulhyboogqhyyevpnlo.supabase.co/functions/v1/florest-print-agent/";

        // Windows Service e IPC
        public const string ServiceName = "FlorestPrintAgent";
        public const string ServiceDisplayName = "Florest Print Agent";
        public const string PipeName = "FlorestPrintAgent.Ipc.v1";
        public const string ServiceMutexName = "Global\\FlorestPrintAgent.Service";
        public const string TrayMutexName = "Local\\FlorestPrintAgent.Tray";
        public const string TrayShowEventName = "Local\\FlorestPrintAgent.Tray.Show";

        // Heartbeat
        public const int DefaultHeartbeatSeconds = 120;
        public const int MinHeartbeatSeconds = 15;
        public const int MaxHeartbeatSeconds = 3600;
        public const double JitterFraction = 0.10; // ±10%

        // Backoff (falhas de rede/servidor)
        public static readonly TimeSpan BackoffStart = TimeSpan.FromSeconds(15);
        public static readonly TimeSpan BackoffCap = TimeSpan.FromMinutes(5);
        // Credencial recusada pelo servidor: tenta de novo devagar (nunca apaga o vínculo sozinho)
        public static readonly TimeSpan CredentialRejectedRetry = TimeSpan.FromMinutes(15);

        // Sincronização
        public static readonly TimeSpan SyncInterval = TimeSpan.FromMinutes(30);
        public static readonly TimeSpan SyncRetryAfterDiscoveryFailure = TimeSpan.FromMinutes(5);
        public static readonly TimeSpan MinSpacingBetweenSyncs = TimeSpan.FromSeconds(30);
        public static readonly TimeSpan MinSpacingBetweenServerRequestedSyncs = TimeSpan.FromSeconds(60);
        public static readonly TimeSpan MinSpacingBetweenManualScans = TimeSpan.FromSeconds(5);
        /// <summary>Quanto tempo uma verificação de código (PairVerify) vale para o PairConfirm do mesmo chamador.</summary>
        public static readonly TimeSpan PairingVerifyTtl = TimeSpan.FromMinutes(5);
        public static readonly TimeSpan DiscoveryTimeout = TimeSpan.FromSeconds(45);

        // Limites do contrato com o servidor (Migration 030 / Edge Function)
        public const int MaxPrintersPerSync = 100;
        public const int MaxSyncBodyBytes = 240 * 1024; // folga sobre o limite de 256 KB da Edge Function
        public const int MaxPrinterNameLength = 160;
        public const int MaxPortNameLength = 200;
        public const int MaxIdentifierLength = 200;

        // HTTP
        public static readonly TimeSpan HttpTimeout = TimeSpan.FromSeconds(30);
        public const int MaxResponseBytes = 1024 * 1024;

        // Credencial renovada que não pôde ser gravada em disco: após este tempo passa a ser usada da memória
        public static readonly TimeSpan PendingCredentialMaxAge = TimeSpan.FromMinutes(10);

        // Impressoras informadas pelo Tray (sessão do usuário)
        public static readonly TimeSpan UserPrintersMaxAge = TimeSpan.FromDays(7);
        public const int MaxUserSessions = 8;

        // IPC
        public const int MaxIpcRequestBytes = 16 * 1024;
        public const int MaxIpcSubmitBytes = 256 * 1024;
        public const int MaxIpcResponseBytes = 512 * 1024;
        public const int MaxIpcConcurrentClients = 8;
        /// <summary>
        /// Tamanho dos buffers de entrada/saída do pipe. NUNCA usar 0: com buffer zero, uma escrita só termina quando o outro
        /// lado a lê (encontro síncrono), o que trava quem escreve antes de o outro lado estar lendo.
        /// </summary>
        public const int IpcPipeBufferBytes = 64 * 1024;
        public static readonly TimeSpan IpcReadTimeout = TimeSpan.FromSeconds(15);
        public static readonly TimeSpan IpcClientConnectTimeout = TimeSpan.FromSeconds(3);
        public static readonly TimeSpan IpcClientResponseTimeout = TimeSpan.FromSeconds(150);

        // Fila de impressão (Fase C / versão 1.1.0)
        /// <summary>Jobs pedidos por consulta (o servidor ainda limita a 5).</summary>
        public const int JobClaimLimit = 3;
        /// <summary>Espera do long-poll no servidor (o HttpClient tem timeout de 30 s; sobra folga).</summary>
        public const int JobLongPollSeconds = 15;
        /// <summary>Intervalo mínimo entre duas consultas quando a resposta veio vazia (proteção contra laço apertado).</summary>
        public static readonly TimeSpan JobMinPollSpacing = TimeSpan.FromSeconds(1);
        /// <summary>Quando o computador não está vinculado / sem credencial: nada a consultar.</summary>
        public static readonly TimeSpan JobNotLinkedDelay = TimeSpan.FromSeconds(5);
        public static readonly TimeSpan JobBackoffStart = TimeSpan.FromSeconds(5);
        public static readonly TimeSpan JobBackoffCap = TimeSpan.FromSeconds(60);
        public static readonly TimeSpan JobCredentialRejectedDelay = TimeSpan.FromMinutes(2);
        /// <summary>Servidor sem a rota de fila (função não publicada na versão nova): tenta de novo devagar.</summary>
        public static readonly TimeSpan JobUnsupportedServerDelay = TimeSpan.FromMinutes(1);
        /// <summary>Margem de segurança antes do fim da reserva: job que não dá mais tempo de imprimir é deixado para o servidor reciclar.</summary>
        public static readonly TimeSpan JobLeaseSafetyMargin = TimeSpan.FromSeconds(20);
        /// <summary>Tempo máximo para o Windows aceitar e concluir o documento na fila do spooler.</summary>
        public static readonly TimeSpan SpoolerJobTimeout = TimeSpan.FromSeconds(25);
        /// <summary>Tempo que o diário local guarda "impresso, mas ainda não confirmado ao servidor".</summary>
        public static readonly TimeSpan PrintedJournalMaxAge = TimeSpan.FromHours(24);
        public const int PrintedJournalMaxEntries = 500;
        public const int DefaultTicketColumns = 48;
        public const int MinTicketColumns = 24;
        public const int MaxTicketColumns = 80;

        // Variável de ambiente que redireciona a pasta de dados (SOMENTE para desenvolvimento/testes)
        public const string DataDirEnvVar = "FLORESTPRINTAGENT_DATA_DIR";
    }
}
