const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// Executa as funções reais da tela com DOM e transporte controlados, sem emissão ou acesso à rede.
const html = fs.readFileSync(path.join(__dirname, '../index.html'), 'utf8');
const source = html.slice(html.indexOf('const FPQ ='), html.indexOf('// Gerador de QR Code'));
function setup(){
  const nodes = new Map();
  const el = id => {
    if(!nodes.has(id)){
      const classes = new Set();
      nodes.set(id, { value: '', innerHTML: '', textContent: '', disabled: false,
        classList: { add: x => classes.add(x), remove: x => classes.delete(x), contains: x => classes.has(x),
          toggle: (x, on) => on ? classes.add(x) : classes.delete(x) },
        addEventListener(){}, appendChild(){}, querySelector(){ return null; } });
    }
    return nodes.get(id);
  };
  const calls = [], pending = [], renders = [];
  const context = vm.createContext({ $: el, Map, Number, String, Object, Date,
    supabase: { rpc(name, args){
      calls.push({ name, args });
      return new Promise((resolve, reject) => pending.push({ resolve, reject }));
    }, from(){
      const q = { select(){ return q; }, eq(){ return q; }, maybeSingle(){
        return new Promise(resolve => pending.push({ resolve }));
      }, in(_, ids){
        return Promise.resolve({ data: ids.map(id => ({ id, numero: id })) });
      }};
      return q;
    } },
    obterEmpresaId: async () => 'empresa', escapeHtml: String,
    ctgFuncaoAusente: () => false, ctgMsgErro: e => e.message,
    fiscalVendaAbertaId: 'venda-anterior',
    recordRender: (...args) => renders.push(args),
  });
  vm.runInContext(source + '\nfiscalRenderLinhas = recordRender;', context);
  return { el, calls, pending, renders, run: s => vm.runInContext(s, context),
    reply(i, ids = [], total = ids.length){ pending[i].resolve({ data: { ids, total } }); } };
}

test('pesquisas consecutivas leem o campo atual e substituem os resultados', async () => {
  const s = setup();
  for(const [i, numero] of ['7666', '7667', '7668'].entries()){
    s.el('fpq-nota').value = numero;
    const pesquisa = s.run('fiscalPesquisar(0, false)');
    assert.equal(s.calls[i].args.p_numero_nota, numero);
    s.reply(i, [numero]); await pesquisa;
    assert.equal(s.renders.at(-1)[0][0].numero, numero);
    assert.equal(s.el('btn-fpq-pesquisar').disabled, false);
  }
});

test('nova pesquisa limpa detalhes antigos e resultado vazio não mantém a nota anterior', async () => {
  const s = setup();
  s.el('fpq-nota').value = '999999';
  s.el('tabela-fiscal-body').innerHTML = 'nota anterior';
  s.el('fiscal-venda-documentos').innerHTML = 'detalhes anteriores';
  const p = s.run('fiscalPesquisar(0, false)');
  assert.equal(s.el('tabela-fiscal-body').innerHTML, '');
  assert.equal(s.el('fiscal-venda-documentos').innerHTML, '');
  assert.ok(s.el('fiscal-venda-resultado').classList.contains('hidden'));
  assert.equal(s.run('fiscalVendaAbertaId'), null);
  s.reply(0); await p;
  assert.equal(s.renders[0][0].length, 0);
  assert.equal(s.el('fpq-resumo').textContent, 'Nenhum documento encontrado.');
});

test('resposta atrasada não substitui a pesquisa mais recente', async () => {
  const s = setup();
  s.el('fpq-nota').value = '7666'; const a = s.run('fiscalPesquisar(0, false)');
  s.el('fpq-nota').value = '7667'; const b = s.run('fiscalPesquisar(0, false)');
  s.reply(1, ['7667']); await b;
  s.reply(0, ['7666']); await a;
  assert.equal(s.renders.length, 1);
  assert.equal(s.renders[0][0][0].numero, '7667');
});

test('Limpar invalida pesquisa em andamento e apaga filtros e detalhes', async () => {
  const s = setup();
  s.el('fpq-nota').value = '7666'; const p = s.run('fiscalPesquisar(0, false)');
  s.run('fpqResetar()'); s.reply(0, ['7666']); await p;
  assert.equal(s.renders.length, 0);
  assert.equal(s.el('fpq-nota').value, '');
  assert.equal(s.run('FPQ.args'), null);
  assert.equal(s.el('btn-fpq-pesquisar').disabled, false);
});

test('erro não preserva nota anterior e permite nova tentativa', async () => {
  const s = setup();
  s.el('fpq-nota').value = '7666'; const a = s.run('fiscalPesquisar(0, false)');
  s.pending[0].reject(new Error('Sem conexão')); await a;
  assert.match(s.el('fpq-msg').innerHTML, /Sem conexão/);
  assert.equal(s.el('btn-fpq-pesquisar').disabled, false);
  s.el('fpq-nota').value = '7667'; const b = s.run('fiscalPesquisar(0, false)');
  s.reply(1, ['7667']); await b;
  assert.equal(s.renders.at(-1)[0][0].numero, '7667');
});

test('todos os filtros são enviados; paginação mantém os filtros da pesquisa', async () => {
  const s = setup();
  for(const [id, value] of Object.entries({ 'fpq-nota':'7667', 'fpq-venda':'123', 'fpq-valor':'1.234,56',
    'fpq-status':'autorizada', 'fpq-ini':'2026-10-01', 'fpq-fim':'2026-10-22', 'fpq-cliente':'Cliente', 'fpq-cpf':'12345678901' })) s.el(id).value = value;
  const a = s.run('fiscalPesquisar(0, false)'); s.reply(0, ['7667'], 101); await a;
  assert.deepEqual(JSON.parse(JSON.stringify(s.calls[0].args)), {
    p_numero_nota:'7667', p_numero_venda:'123', p_valor:1234.56, p_status:'autorizada',
    p_data_ini:'2026-10-01', p_data_fim:'2026-10-22', p_cliente:'Cliente', p_cpf:'12345678901', p_limite:50, p_offset:0 });
  s.el('fpq-nota').value = '7668';
  const b = s.run('fiscalPesquisar(1, true)'); s.reply(1, ['7667'], 101); await b;
  assert.equal(s.calls[1].args.p_numero_nota, '7667');
  assert.equal(s.calls[1].args.p_offset, 50);
});

test('filtros inválidos apagam a pesquisa anterior e não consultam o banco', async () => {
  const s = setup(); s.el('fpq-valor').value = 'inválido';
  s.el('tabela-fiscal-body').innerHTML = 'nota anterior';
  await s.run('fiscalPesquisar(0, false)');
  assert.equal(s.calls.length, 0);
  assert.equal(s.el('tabela-fiscal-body').innerHTML, '');
  assert.equal(s.run('FPQ.args'), null);
});

test('venda antiga que termina de carregar após Limpar não reaparece', async () => {
  const s = setup(); s.el('fiscal-busca-numero').value = '123';
  const p = s.run('buscarVendaFiscal()');
  await new Promise(resolve => setImmediate(resolve));
  s.run('fpqResetar()');
  s.pending[0].resolve({ data: { id: 'venda-antiga', numero_venda: 123 } });
  await p;
  assert.ok(s.el('fiscal-venda-resultado').classList.contains('hidden'));
  assert.equal(s.el('fiscal-venda-titulo').innerHTML, '');
  assert.equal(s.run('fiscalVendaAbertaId'), null);
});

test('atualização após ação fiscal preserva a referência da venda para recarregar detalhes', async () => {
  const s = setup(); s.el('fpq-nota').value = '7666';
  const a = s.run('fiscalPesquisar(0, false)'); s.reply(0, ['7666']); await a;
  s.run("fiscalVendaAbertaId = 'venda-aberta'");
  const b = s.run('carregarFiscal()'); s.reply(1, ['7666']); await b;
  assert.equal(s.run('fiscalVendaAbertaId'), 'venda-aberta');
});
