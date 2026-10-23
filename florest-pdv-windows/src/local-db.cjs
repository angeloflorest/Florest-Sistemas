'use strict';
const path = require('node:path');
const Database = require('better-sqlite3');
function openLocalDatabase(userDataPath) {
  const db = new Database(path.join(userDataPath, 'florest-pdv.sqlite'));
  db.pragma('journal_mode = WAL');
  db.pragma('foreign_keys = ON');
  db.exec(`
    CREATE TABLE IF NOT EXISTS configuracoes (chave TEXT PRIMARY KEY, valor TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS produtos_cache (empresa_id TEXT NOT NULL, produto_id TEXT NOT NULL, dados_json TEXT NOT NULL, atualizado_em TEXT NOT NULL, PRIMARY KEY (empresa_id, produto_id));
    CREATE TABLE IF NOT EXISTS clientes_cache (empresa_id TEXT NOT NULL, cliente_id TEXT NOT NULL, dados_json TEXT NOT NULL, atualizado_em TEXT NOT NULL, PRIMARY KEY (empresa_id, cliente_id));
    CREATE TABLE IF NOT EXISTS vendas_locais (id_local TEXT PRIMARY KEY, empresa_id TEXT NOT NULL, numero_local INTEGER NOT NULL, dados_json TEXT NOT NULL, criada_em TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, estado_sync TEXT NOT NULL DEFAULT 'pendente' CHECK (estado_sync IN ('pendente','enviando','sincronizada','erro')), id_remoto TEXT, erro_sync TEXT, UNIQUE(empresa_id, numero_local));
    CREATE INDEX IF NOT EXISTS idx_vendas_sync ON vendas_locais (empresa_id, estado_sync);
    CREATE TABLE IF NOT EXISTS sync_estado (empresa_id TEXT NOT NULL, recurso TEXT NOT NULL, cursor TEXT, atualizado_em TEXT, PRIMARY KEY (empresa_id,recurso));
  `);
  return db;
}
module.exports = { openLocalDatabase };
