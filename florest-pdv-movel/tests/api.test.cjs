const { test } = require('node:test');
const assert = require('node:assert/strict');
const { load } = require('./helpers.cjs');
const api = load('api', { '@supabase/supabase-js': { createClient() { throw Error('No config must not create client'); } }, './secureStorage': {} });
test('configuração só aceita chave pública apropriada', () => {
  const jwt = role => 'a.' + Buffer.from(JSON.stringify({ role })).toString('base64url') + '.c';
  assert.ok(api.publicConfigValid('https://project.supabase.co', jwt('anon')));
  assert.equal(api.publicConfigValid('https://project.supabase.co', jwt('service_role')), false);
  assert.equal(api.publicConfigValid('https://project.supabase.co', 'sb_secret_invalid'), false);
  assert.equal(api.publicConfigValid('http://project.supabase.co', jwt('anon')), false);
});
test('pesquisa usa a RPC existente sem empresa escolhida ou leitura direta de produtos', async () => {
  let calls = [];
  const c = { async rpc(name, args) { calls.push({ name, args }); return { data: [{ id: 'p', nome: 'Produto', preco_venda: '12.50', codigo: 'A' }] }; }, from() { throw Error('Leitura direta proibida'); } };
  const products = await api.searchProducts(c, 'Produto');
  assert.equal(products[0].preco_venda, 12.5);
  assert.equal(calls[0].name, 'pdv_produtos_consultar');
  assert.equal(calls[0].args.p_busca, 'Produto');
  assert.equal(Object.keys(calls[0].args).some(k => k.includes('empresa')), false);
  assert.equal((await api.searchProducts(c, 'OUTRO', true)).length, 0);
});
test('erro de autorização não ativa fallback e não é apresentado como catálogo vazio', async () => {
  await assert.rejects(() => api.searchProducts({ rpc: async () => ({ error: { code: '42501', message: 'negado' } }) }, 'a'), e => e.code === '42501');
});
test('perfil sempre filtra id do usuário e valida a permissão devolvida', async () => {
  let id;
  const c = { from(table) { assert.equal(table, 'perfis'); return { select() { return this; }, eq(k, v) { assert.equal(k, 'id'); id = v; return this; }, async single() { return { data: { id, empresa_id: 'company', ativo: true, papel: 'funcionario', permissoes: ['pdv'], empresas: { nome: 'Loja', bloqueado: false } } }; } }; } };
  assert.equal((await api.loadProfile(c, 'u')).empresa_id, 'company');
  assert.equal(id, 'u');
});
