const { test } = require('node:test');
const assert = require('node:assert/strict');
const { load } = require('./helpers.cjs');
const d = load('domain');
const profile = () => ({ id: 'user-a', empresa_id: 'company-a', nome: 'Ana', papel: 'funcionario', permissoes: ['pdv'], ativo: true, empresas: { nome: 'Loja A', bloqueado: false, status_conta: 'ativo' } });
test('empresa vem exclusivamente do perfil do usuário; acessos inválidos são recusados', () => {
  assert.equal(d.validateProfile(profile(), 'user-a').empresa_id, 'company-a');
  for (const p of [null, { ...profile(), id: 'user-b' }, { ...profile(), empresa_id: '' }, { ...profile(), ativo: false }, { ...profile(), papel: 'desconhecido' }, { ...profile(), permissoes: [] }, { ...profile(), empresas: null }, { ...profile(), empresas: { bloqueado: true } }, { ...profile(), empresas: { status_conta: 'pendente' } }]) assert.throws(() => d.validateProfile(p, 'user-a'));
  assert.equal(d.validateProfile({ ...profile(), papel: 'proprietario', permissoes: [] }, 'user-a').id, 'user-a');
});
test('quantidade decimal e total arredondam por item como no PDV', () => {
  assert.equal(d.parseQuantity('1,125'), 1.125);
  for (const v of ['0', '-2', 'NaN', '1e3', '1.1234', '1,2,3', '']) assert.throws(() => d.parseQuantity(v));
  assert.equal(d.totalCents([{ product: { preco_venda: 0.1 }, quantity: 3 }, { product: { preco_venda: 12.99 }, quantity: 0.125 }]), 192);
});
test('código exato prioriza GTIN equivalente e não escolhe o primeiro produto arbitrariamente', () => {
  const p = [{ id: 'internal', codigo: '12345678', gtin: null }, { id: 'barcode', gtin: '0000012345678' }];
  assert.equal(d.exactProduct(p, '12345678').id, 'barcode');
  assert.equal(d.exactProduct(p, 'outro'), null);
  assert.ok(d.gtinVariants('12345678').includes('0000012345678'));
  assert.equal(d.gtinVariants('invalid').length, 0);
});
test('preço inválido é rejeitado e produto inativo é removido', () => {
  assert.throws(() => d.validateProducts([{ id: '1', nome: 'Produto', preco_venda: 'oops' }]));
  assert.equal(d.validateProducts([{ id: '1', nome: 'Produto', preco_venda: 5, ativo: false }]).length, 0);
});
test('atualizações recusam downgrade, origem diferente e protocolos inseguros', () => {
  const url = 'https://aplicativos.florestsistemas.com.br/pdv.json';
  assert.ok(d.validUpdate({ version: '0.3.0', apkUrl: 'https://aplicativos.florestsistemas.com.br/app.apk' }, '0.2.0', url));
  for (const m of [{ version: '0.1.0', apkUrl: url }, { version: '0.3.0', apkUrl: 'http://aplicativos.florestsistemas.com.br/a.apk' }, { version: '0.3.0', apkUrl: 'https://outro.test/a.apk' }, { version: 'latest', apkUrl: url }]) assert.equal(d.validUpdate(m, '0.2.0', url), null);
});
