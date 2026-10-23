const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const html = fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
const source = html.slice(html.indexOf('const barNovoDia ='),html.indexOf('// ---------- Fim dos cálculos puros'));
const ctx=vm.createContext({Intl,Date,Map,Set,Number,JSON,Error}); vm.runInContext(source,ctx);
const calc=(tipo,f,d)=>JSON.parse(JSON.stringify(ctx.barNovoCalcular(tipo,f,d)));
const filtros={dataInicio:'2026-10-01',dataFim:'2026-10-31',produtos:[]};
function dados(){return {
  produtos:[1,2,3,4,5,6].map(id=>({id:String(id),nome:'Produto '+id,unidade_comercial:id===3?'KG':'UN'})),
  mesas:[{id:'mesa',numero:1}], caixas:[{id:'cx',numero:7,aberto_por_nome:'Operador',aberto_em:'2026-10-01T10:00:00Z'}],
  comandas:[{id:'c',mesa_id:'mesa',venda_id:'v',status:'aberta'},{id:'cancelada',venda_id:'vc',cancelada_em:'2026-10-10T12:00:00Z'}],
  vendas:[{id:'v',numero_venda:1,total:100,tipo:'bar',criado_em:'2026-10-02T12:00:00Z'},{id:'vc',total:50,criado_em:'2026-10-02T12:00:00Z',cancelada_em:'2026-10-10T12:00:00Z'}],
  pagamentos:[{id:'p1',comanda_id:'c',caixa_id:'cx',total:30,criado_em:'2026-10-02T12:00:00Z'},
    {id:'p2',comanda_id:'c',caixa_id:'cx',total:20,criado_em:'2026-10-03T12:00:00Z'},
    {id:'p3',comanda_id:'c',caixa_id:'cx',total:10,criado_em:'2026-09-30T12:00:00Z',estornado:true,estornado_em:'2026-10-04T12:00:00Z'}],
  formas:[{pagamento_id:'p1',forma_pagamento:'PIX',valor:20},{pagamento_id:'p1',forma_pagamento:'Dinheiro',valor:10},{pagamento_id:'p2',forma_pagamento:'PIX',valor:20},{pagamento_id:'p3',forma_pagamento:'PIX',valor:10}],
  barProdutos:[], itens:[
    {id:'i1',comanda_id:'c',produto_id:'1',quantidade:2,preco_unitario:10,criado_em:'2026-10-02T12:00:00Z'},
    {id:'i2',comanda_id:'c',produto_id:'2',quantidade:1,preco_unitario:30,criado_em:'2026-10-02T12:00:00Z'},
    {id:'i3',comanda_id:'c',produto_id:'1',quantidade:50,preco_unitario:10,criado_em:'2026-10-02T12:00:00Z',estornado:true},
    {id:'i4',comanda_id:'cancelada',produto_id:'1',quantidade:100,preco_unitario:10,criado_em:'2026-10-02T12:00:00Z'},
  ], baixas:[
    {id:'b1',pedido_item_id:'i1',produto_id:'1',quantidade:2,criado_em:'2026-10-02T12:00:00Z'},
    {id:'b2',pedido_item_id:'i2',produto_id:'1',quantidade:3,criado_em:'2026-10-02T12:00:00Z'},
    {id:'b3',pedido_item_id:'i2',produto_id:'3',quantidade:0.25,criado_em:'2026-10-02T12:00:00Z'},
    {id:'b4',pedido_item_id:'i2',produto_id:'4',quantidade:1,criado_em:'2026-10-02T12:00:00Z',estornada:true},
    {id:'b5',pedido_item_id:'i3',produto_id:'5',quantidade:100,criado_em:'2026-10-02T12:00:00Z'},
    {id:'b6',pedido_item_id:'i4',produto_id:'5',quantidade:100,criado_em:'2026-10-02T12:00:00Z'},
  ]};}

test('período soma cada venda uma vez, exclui cancelamento e distingue recebimento parcial',()=>{
  const r=calc('periodo',filtros,dados());
  assert.deepEqual(r.resumos.slice(0,2),[['Total geral do período',100],['Quantidade de vendas',1]]);
  assert.equal(r.linhas[0][7],50); assert.equal(r.linhas[0][8],50); assert.equal(r.linhas[1][5],0);
});
test('caixa soma pagamentos mistos e parciais uma vez e estorno na data do estorno',()=>{
  const r=calc('caixa',filtros,dados());
  assert.deepEqual(r.resumos.slice(0,3),[['Total recebido',50],['Estornos',10],['Total líquido',40]]);
  assert.equal(r.resumos[3][1],1);
  assert.equal(calc('caixa',{...filtros,caixaId:'outro'},dados()).linhas.length,0);
});
test('produto conta o composto comercial, nunca seus componentes, e conserva preços históricos',()=>{
  const d=dados(); d.itens.push({...d.itens[0],id:'novo',preco_unitario:12});
  const r=calc('produto',filtros,d);
  assert.equal(r.resumos[0][1],74); assert.equal(r.linhas.length,3);
  assert.equal(calc('produto',{...filtros,produtos:['2']},d).resumos[0][1],30);
});
test('cinco produtos: baixa direta não duplica, componentes históricos somam e estornos são excluídos',()=>{
  const r=calc('comparativo',{...filtros,produtos:['1','2','3','4','5']},dados());
  assert.deepEqual(r.resumos.map(x=>x[1]),[5,1,0.25,0,0]);
  assert.deepEqual(r.comparacao.linhas,[['2026-10-02',5,1,0.25,0,0]]);
  assert.ok(r.linhas.some(row=>row[4]==='Componente de produto composto'&&row[5]==='Produto 2'));
});
test('comparativo aceita menos de cinco, rejeita duplicados e produto fora do catálogo da empresa',()=>{
  assert.equal(calc('comparativo',{...filtros,produtos:['1']},dados()).resumos[0][1],5);
  for(const ids of [[],['1','1'],['outra-empresa'],['1','2','3','4','5','6']]) assert.throws(()=>calc('comparativo',{...filtros,produtos:ids},dados()));
});
test('datas são filtradas pelo dia de São Paulo e incluem o último dia',()=>{
  const d=dados(); d.itens=[{id:'i',produto_id:'1',quantidade:1,preco_unitario:1,criado_em:'2026-11-01T02:59:59Z'}];
  assert.equal(calc('produto',filtros,d).linhas[0][1],'2026-10-31');
  d.itens[0].criado_em='2026-11-01T03:00:00Z'; assert.equal(calc('produto',filtros,d).linhas.length,0);
});
test('origens novas mantêm os dez relatórios anteriores no catálogo',()=>{
  const lista=html.slice(html.indexOf('const SECOES_RELATORIOS_BAR ='),html.indexOf('function carregarBarRelatorios'));
  assert.equal((lista.match(/id: '/g)||[]).length,14);
  for(const id of ['bar_historico_mesa','bar_mesas_caixa','bar_faturamento_periodo','bar_comparativo_garcons']) assert.ok(lista.includes(id));
});

// Snapshot temporário opcional, obtido somente por SELECT; nunca versionar dados da empresa.
if(process.env.BAR_REL_SNAPSHOT){
  const {d,esperado,produtos}=JSON.parse(fs.readFileSync(process.env.BAR_REL_SNAPSHOT,'utf8'));
  test('dados reais: quatro relatórios conferem com agregações SQL independentes',()=>{
    const f={dataInicio:'2020-01-01',dataFim:'2030-12-31',produtos:[]};
    assert.equal(calc('periodo',f,d).resumos[0][1],Number(esperado.vendas));
    assert.equal(calc('caixa',f,d).resumos[2][1],Number(esperado.caixa));
    assert.equal(calc('produto',f,d).resumos[0][1],Number(esperado.itens));
    const r=calc('comparativo',{...f,produtos},d);
    for(let i=0;i<produtos.length;i++) assert.ok(Math.abs(r.resumos[i][1]-Number(esperado.consumo[produtos[i]]||0))<1e-9);
    assert.equal(r.resumos.length,5);
    assert.ok(r.linhas.some(x=>x[4]==='Venda direta')); assert.ok(r.linhas.some(x=>x[4]==='Componente de produto composto'));
  });
}
