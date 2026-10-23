'use strict';
const path = require('node:path');
const crypto = require('node:crypto');
const Database = require('better-sqlite3');

function openLocalDatabase(userDataPath) {
  const db = new Database(path.join(userDataPath, 'florest-pdv.sqlite'));
  db.pragma('journal_mode = WAL');
  db.pragma('foreign_keys = ON');
  db.pragma('busy_timeout = 5000');
  db.exec(`
    CREATE TABLE IF NOT EXISTS configuracoes (chave TEXT PRIMARY KEY, valor TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS produtos_cache (empresa_id TEXT NOT NULL, produto_id TEXT NOT NULL, dados_json TEXT NOT NULL, atualizado_em TEXT NOT NULL, PRIMARY KEY (empresa_id, produto_id));
    CREATE TABLE IF NOT EXISTS clientes_cache (empresa_id TEXT NOT NULL, cliente_id TEXT NOT NULL, dados_json TEXT NOT NULL, atualizado_em TEXT NOT NULL, PRIMARY KEY (empresa_id, cliente_id));
    CREATE TABLE IF NOT EXISTS vendas_locais (
      id_local TEXT PRIMARY KEY,
      empresa_id TEXT NOT NULL,
      numero_local INTEGER NOT NULL,
      dados_json TEXT NOT NULL,
      criada_em TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
      estado_sync TEXT NOT NULL DEFAULT 'pendente' CHECK (estado_sync IN ('pendente','enviando','sincronizada','erro')),
      id_remoto TEXT,
      erro_sync TEXT,
      UNIQUE(empresa_id, numero_local)
    );
    CREATE INDEX IF NOT EXISTS idx_vendas_sync ON vendas_locais (empresa_id, estado_sync);
    CREATE TABLE IF NOT EXISTS sync_estado (empresa_id TEXT NOT NULL, recurso TEXT NOT NULL, cursor TEXT, atualizado_em TEXT, PRIMARY KEY (empresa_id,recurso));
    CREATE TABLE IF NOT EXISTS sequencias_locais (empresa_id TEXT PRIMARY KEY, ultimo_numero INTEGER NOT NULL DEFAULT 0);
  `);

  // Criação atômica: número local e venda são gravados juntos, sem depender de internet.
  const registrarVenda = db.transaction(({ empresaId, dados }) => {
    if (typeof empresaId !== 'string' || !empresaId.trim()) throw new Error('Empresa obrigatória');
    if (!dados || typeof dados !== 'object' || Array.isArray(dados)) throw new Error('Dados da venda inválidos');
    const valor = JSON.stringify(dados);
    db.prepare('INSERT INTO sequencias_locais (empresa_id, ultimo_numero) VALUES (?, 0) ON CONFLICT(empresa_id) DO NOTHING').run(empresaId);
    db.prepare('UPDATE sequencias_locais SET ultimo_numero = ultimo_numero + 1 WHERE empresa_id = ?').run(empresaId);
    const numeroLocal = db.prepare('SELECT ultimo_numero FROM sequencias_locais WHERE empresa_id = ?').get(empresaId).ultimo_numero;
    const idLocal = crypto.randomUUID();
    db.prepare('INSERT INTO vendas_locais (id_local, empresa_id, numero_local, dados_json) VALUES (?, ?, ?, ?)').run(idLocal, empresaId, numeroLocal, valor);
    return { idLocal, numeroLocal, estadoSync: 'pendente' };
  });

  function pendentes(empresaId, limite = 50) {
    if (!empresaId) throw new Error('Empresa obrigatória');
    return db.prepare("SELECT id_local, numero_local, dados_json, criada_em, estado_sync FROM vendas_locais WHERE empresa_id = ? AND estado_sync IN ('pendente','erro') ORDER BY numero_local LIMIT ?").all(empresaId, Math.max(1, Math.min(100, Math.trunc(limite) || 50)));
  }

  // Só marcar sincronizada após confirmação do servidor de que o mesmo id_local foi aceito.
  function confirmarSincronizacao({ empresaId, idLocal, idRemoto }) {
    if (!empresaId || !idLocal || !idRemoto) throw new Error('Confirmação incompleta');
    const result = db.prepare("UPDATE vendas_locais SET estado_sync = 'sincronizada', id_remoto = ?, erro_sync = NULL WHERE empresa_id = ? AND id_local = ? AND (id_remoto IS NULL OR id_remoto = ?)").run(idRemoto, empresaId, idLocal, idRemoto);
    if (result.changes !== 1) throw new Error('Venda inexistente ou confirmação conflitante');
  }

  function registrarErro({ empresaId, idLocal, mensagem }) {
    if (!empresaId || !idLocal) throw new Error('Venda obrigatória');
    db.prepare("UPDATE vendas_locais SET estado_sync = 'erro', erro_sync = ? WHERE empresa_id = ? AND id_local = ? AND estado_sync <> 'sincronizada'").run(String(mensagem || 'Falha de sincronização').slice(0, 500), empresaId, idLocal);
  }

  // Atualização atômica do catálogo local, isolada por empresa.
  const atualizarProdutos = db.transaction((empresaId, produtos) => {
    if (typeof empresaId !== 'string' || !empresaId.trim()) throw new Error('Empresa obrigatória');
    if (!Array.isArray(produtos)) throw new Error('Produtos inválidos');
    const gravar = db.prepare('INSERT INTO produtos_cache (empresa_id, produto_id, dados_json, atualizado_em) VALUES (?, ?, ?, ?) ON CONFLICT(empresa_id, produto_id) DO UPDATE SET dados_json=excluded.dados_json, atualizado_em=excluded.atualizado_em');
    const agora = new Date().toISOString();
    for (const produto of produtos) {
      if (!produto || (typeof produto.id !== 'string' && typeof produto.id !== 'number')) throw new Error('Produto sem ID');
      gravar.run(empresaId, String(produto.id), JSON.stringify(produto), agora);
    }
    return produtos.length;
  });

  function buscarProdutos(empresaId, termo = '', limite = 30) {
    if (typeof empresaId !== 'string' || !empresaId.trim()) throw new Error('Empresa obrigatória');
    const busca = String(termo).trim().toLowerCase();
    const itens = db.prepare('SELECT dados_json FROM produtos_cache WHERE empresa_id = ? ORDER BY produto_id').all(empresaId);
    return itens.map(item => JSON.parse(item.dados_json)).filter(p => {
      if (!busca) return true;
      return [p.nome, p.descricao, p.codigo_barras, p.gtin, p.codigo].some(v => String(v ?? '').toLowerCase().includes(busca));
    }).slice(0, Math.max(1, Math.min(100, Math.trunc(limite) || 30)));
  }

  return { db, registrarVenda, pendentes, confirmarSincronizacao, registrarErro, atualizarProdutos, buscarProdutos, fechar: () => db.close() };
}
module.exports = { openLocalDatabase };
