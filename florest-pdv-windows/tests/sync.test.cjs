'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { createSync } = require('../src/sync.cjs');
function fixture() {
  const rows = [{ id_local: 'a', numero_local: 1, dados_json: '{"total":10}' }];
  const confirmations = [], errors = [], catalogs = [];
  const storage = {
    pendentes: () => rows.filter(r => !confirmations.some(c => c.idLocal === r.id_local)),
    confirmarSincronizacao: c => confirmations.push(c), registrarErro: e => errors.push(e),
    atualizarCatalogo: (...args) => catalogs.push(args), resumoPendencias: () => ({ pendente: rows.length - confirmations.length })
  };
  const transport = {
    sendSale: async v => ({ empresaId: v.empresaId, idLocal: v.idLocal, idRemoto: 'remote-a' }),
    receiveCatalog: async () => ({ empresaId: 'empresa-a', produtos: [], clientes: [] })
  };
  return { storage, transport, confirmations, errors, catalogs };
}
test('confirma apenas a venda e empresa recebidas e recebe catálogo', async () => {
  const f = fixture(), sync = createSync({ ...f, empresaId: 'empresa-a' });
  const result = await sync.run();
  assert.equal(result.enviados, 1); assert.equal(f.confirmations.length, 1); assert.equal(f.catalogs.length, 1);
  await sync.run(); assert.equal(f.confirmations.length, 1);
  await sync.stop();
});
test('resposta perdida mantém mesmo UUID no reenvio', async () => {
  const f = fixture(), ids = []; let primeira = true;
  f.transport.sendSale = async v => {
    ids.push(v.idLocal);
    if (primeira) { primeira = false; throw new Error('Resposta perdida'); }
    return { ...v, idRemoto: 'remote-a' };
  };
  const sync = createSync({ ...f, empresaId: 'empresa-a' });
  assert.equal((await sync.run()).enviados, 0);
  assert.equal((await sync.run()).enviados, 1);
  assert.deepEqual(ids, ['a', 'a']); assert.equal(f.errors.length, 1);
  await sync.stop();
});
test('confirmações e catálogos de outra empresa são recusados', async () => {
  const f = fixture();
  f.transport.sendSale = async () => ({ empresaId: 'empresa-b', idLocal: 'a', idRemoto: 'x' });
  f.transport.receiveCatalog = async () => ({ empresaId: 'empresa-b', produtos: [], clientes: [] });
  const sync = createSync({ ...f, empresaId: 'empresa-a' });
  const result = await sync.run();
  assert.equal(result.erros.length, 2); assert.equal(f.confirmations.length, 0); assert.equal(f.catalogs.length, 0);
  await sync.stop();
});
test('botões e rodada automática simultâneos não enviam duas vezes', async () => {
  const f = fixture(); let release, calls = 0;
  f.transport.sendSale = v => { calls++; return new Promise(resolve => { release = () => resolve({ ...v, idRemoto: 'remote-a' }); }); };
  const sync = createSync({ ...f, empresaId: 'empresa-a' });
  const first = sync.run(), second = sync.run();
  assert.equal(first, second); release(); await first;
  assert.equal(calls, 1); await sync.stop();
  await assert.rejects(sync.run(), /encerrada/);
});
