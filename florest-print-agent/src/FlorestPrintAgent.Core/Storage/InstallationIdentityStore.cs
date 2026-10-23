using System;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace FlorestPrintAgent.Core.Storage
{
    /// <summary>
    /// Identidade permanente da instalação (identificador_instalacao). Gerada UMA vez (Guid.NewGuid) na primeira
    /// execução e mantida entre reinícios, atualizações e fechamento do Tray. Desvincular NÃO apaga a identidade.
    /// Gravação atômica, com cópia de segurança (.bak) para sobreviver a corrupção do arquivo principal.
    /// </summary>
    public sealed class InstallationIdentityStore
    {
        // mesmo formato aceito pela Edge Function/banco
        private static readonly Regex ValidId = new Regex("^[A-Za-z0-9._:{}-]{8,128}$", RegexOptions.CultureInvariant | RegexOptions.Compiled);

        private readonly string _file;
        private readonly string _backup;
        private readonly Func<bool>? _linkEvidence;
        private readonly object _lock = new object();

        /// <param name="file">Arquivo da identidade (instalacao.json).</param>
        /// <param name="linkEvidence">
        /// Diz se já existe um vínculo local (credencial) que depende da identidade atual. Se existir e a identidade (e o backup)
        /// estiverem ausentes/corrompidos, NÃO se cria identidade nova: lança <see cref="IdentityProblemException"/>.
        /// Primeira instalação limpa (sem vínculo) continua gerando Guid.NewGuid().
        /// </param>
        public InstallationIdentityStore(string file, Func<bool>? linkEvidence = null)
        {
            _file = file;
            _backup = file + ".bak";
            _linkEvidence = linkEvidence;
        }

        public const string TransientMessage =
            "A identificação deste computador não pôde ser lida agora (arquivo bloqueado ou sem permissão). Nenhuma identificação nova foi criada; uma nova tentativa será feita automaticamente.";

        public const string RecoveryMessage =
            "A identificação deste computador (instalacao.json e sua cópia .bak) está ausente ou corrompida, mas existe um vínculo salvo. " +
            "Para não gerar um vínculo inconsistente, nenhuma identificação nova foi criada. Restaure o arquivo instalacao.json (ou instalacao.json.bak) " +
            "da pasta de dados ou, como Administrador, remova o vínculo apenas deste computador e conecte novamente ao Florest ERP.";

        private bool HasLinkEvidence()
        {
            if (_linkEvidence == null) return false;
            try
            {
                return _linkEvidence();
            }
            catch (Exception ex) when (ex is IOException || ex is UnauthorizedAccessException)
            {
                // não dá para provar que NÃO há vínculo: trata como se houvesse (mais seguro)
                return true;
            }
        }

        public static bool IsValidId(string? id)
        {
            return id != null && ValidId.IsMatch(id);
        }

        public string GetOrCreate()
        {
            lock (_lock)
            {
                string? id;
                ReadStatus main = ReadWithRetry(_file, out id);
                if (main == ReadStatus.Ok && id != null) return id;

                if (main == ReadStatus.Unavailable)
                {
                    // Erro transitório (antivírus, bloqueio de arquivo, permissão): NUNCA gerar outra identidade por causa disso.
                    // Se o backup estiver legível, usa-o (é a mesma identidade); senão falha e o serviço tenta de novo no reinício.
                    string? fromBackup;
                    if (ReadWithRetry(_backup, out fromBackup) == ReadStatus.Ok && fromBackup != null) return fromBackup;
                    throw new IdentityProblemException(TransientMessage, true);
                }

                // arquivo principal ausente ou com conteúdo inválido: tenta a cópia de segurança
                string? restored;
                ReadStatus backup = ReadWithRetry(_backup, out restored);
                if (backup == ReadStatus.Ok && restored != null)
                {
                    AtomicFile.WriteAllBytes(_file, Serialize(restored));
                    return restored;
                }
                if (backup == ReadStatus.Unavailable)
                    throw new IdentityProblemException(TransientMessage, true);

                // Identidade e backup ausentes/corrompidos. Se já existe um vínculo local, uma identidade nova o deixaria inválido
                // (instalacao_divergente): estado de erro RECUPERÁVEL, sem criar nada e sem mexer nos arquivos.
                if (HasLinkEvidence())
                    throw new IdentityProblemException(RecoveryMessage, false);

                // primeira instalação realmente limpa (ou dados removidos): preserva um eventual arquivo corrompido e gera nova identidade
                if (main == ReadStatus.Invalid) Quarantine(_file);

                string created = Guid.NewGuid().ToString("D");
                byte[] content = Serialize(created);
                AtomicFile.WriteAllBytes(_file, content);
                AtomicFile.WriteAllBytes(_backup, content);
                return created;
            }
        }

        private static byte[] Serialize(string id)
        {
            IdentityDocument doc = new IdentityDocument();
            doc.Id = id;
            doc.CreatedUtc = DateTime.UtcNow;
            return System.Text.Encoding.UTF8.GetBytes(JsonSerializer.Serialize(doc, AgentJson.IndentedOptions));
        }

        private enum ReadStatus
        {
            Ok,
            Absent,
            Invalid,
            Unavailable,
        }

        private static ReadStatus ReadWithRetry(string path, out string? id)
        {
            ReadStatus status = ReadStatus.Unavailable;
            id = null;
            for (int attempt = 0; attempt < 4; attempt++)
            {
                status = TryRead(path, out id);
                if (status != ReadStatus.Unavailable) return status;
                System.Threading.Thread.Sleep(150);
            }
            return status;
        }

        private static ReadStatus TryRead(string path, out string? id)
        {
            id = null;
            string text;
            try
            {
                text = File.ReadAllText(path);
            }
            catch (FileNotFoundException)
            {
                return ReadStatus.Absent;
            }
            catch (DirectoryNotFoundException)
            {
                return ReadStatus.Absent;
            }
            catch (Exception ex) when (ex is IOException || ex is UnauthorizedAccessException)
            {
                return ReadStatus.Unavailable;
            }

            try
            {
                IdentityDocument? doc = JsonSerializer.Deserialize<IdentityDocument>(text, AgentJson.Options);
                if (doc == null || !IsValidId(doc.Id)) return ReadStatus.Invalid;
                id = doc.Id;
                return ReadStatus.Ok;
            }
            catch (JsonException)
            {
                return ReadStatus.Invalid;
            }
        }

        private static void Quarantine(string path)
        {
            try
            {
                if (!File.Exists(path)) return;
                string target = path + ".corrompido-" + DateTime.UtcNow.ToString("yyyyMMddHHmmss", System.Globalization.CultureInfo.InvariantCulture);
                File.Move(path, target);
            }
            catch (Exception ex) when (ex is IOException || ex is UnauthorizedAccessException)
            {
                // se não der para mover, a gravação atômica abaixo substitui o arquivo
            }
        }

        private sealed class IdentityDocument
        {
            [JsonPropertyName("identificador_instalacao")]
            public string? Id { get; set; }

            [JsonPropertyName("criado_em_utc")]
            public DateTime? CreatedUtc { get; set; }
        }
    }
}
