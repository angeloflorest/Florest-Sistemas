'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { openLocalDatabase } = require('../src/local-db.cjs');

test('vendas offline recebem ids distintos, numeração por empresa e confirmação segura', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'florest-pdv-test-'));
  let storage;
  try {
    storage = openLocalDatabase(dir);
    const primeira = storage.registrarVenda({ empresaId: 'empresa-a', dados: { total: 10 } });
    const segunda = storage.registrarVenda({ empresaId: 'empresa-a', dados: { total: 20 } });
    const outra = storage.registrarVenda({ empresaId: 'empresa-b', dados: { total: 30 } });
    assert.equal(primeira.numeroLocal, 1);
    assert.equal(segunda.numeroLocal, 2);
    assert.equal(outra.numeroLocal, 1);
    assert.notEqual(primeira.idLocal, segunda.idLocal);
    assert.equal(storage.pendentes('empresa-a').length, 2);
    storage.confirmarSincronizacao({ empresaId: 'empresa-a', idLocal: primeira.idLocal, idRemoto: 'remota-1' });
    assert.equal(storage.pendentes('empresa-a').length, 1);
    assert.throws(() => storage.confirmarSincronizacao({ empresaId: 'empresa-a', idLocal: primeira.idLocal, idRemoto: 'remota-2' }), /conflitante/);
    assert.throws(() => storage.registrarVenda({ empresaId: '', dados: {} }), /Empresa obrigatória/);
    storage.fechar();
    storage = openLocalDatabase(dir);
    assert.equal(storage.pendentes('empresa-a').length, 1);
    assert.equal(storage.registrarVenda({ empresaId: 'empresa-a', dados: { total: 40 } }).numeroLocal, 3);
  } finally {
    if (storage) storage.fechar();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
