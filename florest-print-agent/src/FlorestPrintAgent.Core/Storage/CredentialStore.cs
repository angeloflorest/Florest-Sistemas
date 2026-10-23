using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using FlorestPrintAgent.Core.Security;

namespace FlorestPrintAgent.Core.Storage
{
    public enum CredentialLoadStatus
    {
        Missing,
        Ok,
        /// <summary>Existe, mas o conteúdo é inválido/não decifra (formato, DPAPI). Só um novo pareamento resolve.</summary>
        Corrupt,
        /// <summary>Erro transitório de leitura (arquivo bloqueado, permissão). NÃO é definitivo: ler de novo mais tarde.</summary>
        Unreadable,
    }

    public sealed class CredentialLoadResult
    {
        public CredentialLoadStatus Status { get; }
        public AgentToken? Token { get; }

        public CredentialLoadResult(CredentialLoadStatus status, AgentToken? token)
        {
            Status = status;
            Token = token;
        }
    }

    public interface ICredentialStore
    {
        CredentialLoadResult Load();
        void Save(AgentToken token);
        void Delete();
    }

    /// <summary>
    /// Guarda SOMENTE o conteúdo protegido (DPAPI) do token. O arquivo não é JSON legível: "FPA1" + blob DPAPI.
    /// A pasta data\ só é acessível a SYSTEM/Administradores.
    /// </summary>
    public sealed class CredentialStore : ICredentialStore
    {
        private static readonly byte[] Magic = new byte[] { (byte)'F', (byte)'P', (byte)'A', (byte)'1' };
        private readonly string _file;
        private readonly ISecretProtector _protector;

        public CredentialStore(string file, ISecretProtector protector)
        {
            _file = file;
            _protector = protector;
        }

        public CredentialLoadResult Load()
        {
            byte[]? raw = null;
            for (int attempt = 0; attempt < 4 && raw == null; attempt++)
            {
                try
                {
                    raw = File.ReadAllBytes(_file);
                }
                catch (FileNotFoundException)
                {
                    return new CredentialLoadResult(CredentialLoadStatus.Missing, null);
                }
                catch (DirectoryNotFoundException)
                {
                    return new CredentialLoadResult(CredentialLoadStatus.Missing, null);
                }
                catch (Exception ex) when (ex is IOException || ex is UnauthorizedAccessException)
                {
                    if (attempt == 3) return new CredentialLoadResult(CredentialLoadStatus.Unreadable, null);
                    System.Threading.Thread.Sleep(150);
                }
            }
            if (raw == null) return new CredentialLoadResult(CredentialLoadStatus.Unreadable, null);

            if (raw.Length <= Magic.Length) return new CredentialLoadResult(CredentialLoadStatus.Corrupt, null);
            for (int i = 0; i < Magic.Length; i++)
            {
                if (raw[i] != Magic[i]) return new CredentialLoadResult(CredentialLoadStatus.Corrupt, null);
            }

            byte[] blob = new byte[raw.Length - Magic.Length];
            Buffer.BlockCopy(raw, Magic.Length, blob, 0, blob.Length);

            byte[]? plain = null;
            try
            {
                plain = _protector.Unprotect(blob);
                string text = Encoding.UTF8.GetString(plain);
                AgentToken? token;
                if (!TokenParser.TryParse(text, out token) || token == null)
                    return new CredentialLoadResult(CredentialLoadStatus.Corrupt, null);
                return new CredentialLoadResult(CredentialLoadStatus.Ok, token);
            }
            catch (CryptographicException)
            {
                return new CredentialLoadResult(CredentialLoadStatus.Corrupt, null);
            }
            finally
            {
                if (plain != null) Array.Clear(plain, 0, plain.Length);
            }
        }

        public void Save(AgentToken token)
        {
            byte[] plain = Encoding.UTF8.GetBytes(token.RevealForAuthorization());
            try
            {
                byte[] blob = _protector.Protect(plain);
                byte[] file = new byte[Magic.Length + blob.Length];
                Buffer.BlockCopy(Magic, 0, file, 0, Magic.Length);
                Buffer.BlockCopy(blob, 0, file, Magic.Length, blob.Length);
                AtomicFile.WriteAllBytes(_file, file);
            }
            finally
            {
                Array.Clear(plain, 0, plain.Length);
            }
        }

        public void Delete()
        {
            if (File.Exists(_file)) File.Delete(_file);
        }
    }
}
