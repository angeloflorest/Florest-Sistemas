using System;
using FlorestPrintAgent.Core.Security;

namespace FlorestPrintAgent.Core.Storage
{
    /// <summary>
    /// Mantém a credencial ativa em memória e cuida da substituição segura:
    ///   1) o novo token é protegido e gravado de forma atômica; 2) SÓ DEPOIS a memória passa a usá-lo.
    /// Se a gravação falhar depois que o servidor já rotacionou, o novo token fica "pendente" em memória, a
    /// gravação é repetida a cada ciclo e, passado PendingCredentialMaxAge, o token pendente passa a ser usado
    /// (a janela de graça do servidor é de 15 min), para nunca perder o vínculo por uma falha de disco.
    /// Nunca registra token em log.
    /// </summary>
    public sealed class CredentialVault
    {
        private readonly ICredentialStore _store;
        private readonly IClock _clock;
        private readonly object _lock = new object();
        private AgentToken? _current;
        private AgentToken? _pending;
        private DateTime _pendingSinceUtc;

        public CredentialVault(ICredentialStore store, IClock clock)
        {
            _store = store;
            _clock = clock;
        }

        /// <summary>Lê a credencial do disco. Corrupt = existe mas não pode ser usada (não é apagada automaticamente).</summary>
        public CredentialLoadStatus Load()
        {
            CredentialLoadResult r = _store.Load();
            lock (_lock)
            {
                _current = r.Status == CredentialLoadStatus.Ok ? r.Token : null;
                _pending = null;
            }
            return r.Status;
        }

        public bool HasCredential
        {
            get { lock (_lock) { return _current != null || _pending != null; } }
        }

        /// <summary>Token a ser usado nas requisições (ou null se não vinculado).</summary>
        public AgentToken? GetActive()
        {
            lock (_lock)
            {
                if (_pending != null && _current != null && (_clock.UtcNow - _pendingSinceUtc) > AgentConstants.PendingCredentialMaxAge)
                {
                    return _pending;
                }
                return _current ?? _pending;
            }
        }

        public bool HasPendingPersistence
        {
            get { lock (_lock) { return _pending != null; } }
        }

        /// <summary>Primeira credencial (pareamento). Grava antes de ativar; lança exceção se não conseguir gravar.</summary>
        public void SetInitial(AgentToken token)
        {
            lock (_lock)
            {
                _store.Save(token);
                _current = token;
                _pending = null;
            }
        }

        /// <summary>Credencial renovada. Devolve true se já foi gravada; false se ficou pendente (gravação falhou).</summary>
        public bool StageRenewed(AgentToken renewed)
        {
            lock (_lock)
            {
                try
                {
                    _store.Save(renewed);
                    _current = renewed;
                    _pending = null;
                    return true;
                }
                catch (Exception)
                {
                    _pending = renewed;
                    _pendingSinceUtc = _clock.UtcNow;
                    return false;
                }
            }
        }

        /// <summary>Repete a gravação de uma credencial pendente. True quando não há mais nada pendente.</summary>
        public bool TryFlushPending()
        {
            lock (_lock)
            {
                if (_pending == null) return true;
                try
                {
                    _store.Save(_pending);
                    _current = _pending;
                    _pending = null;
                    return true;
                }
                catch (Exception)
                {
                    return false;
                }
            }
        }

        /// <summary>Remove a credencial (desvinculação confirmada pelo servidor, ou remoção local forçada).</summary>
        public void Clear()
        {
            lock (_lock)
            {
                _store.Delete();
                _current = null;
                _pending = null;
            }
        }
    }
}
