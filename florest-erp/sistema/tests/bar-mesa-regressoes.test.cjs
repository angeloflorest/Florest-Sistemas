const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const html = fs.readFileSync(process.env.BAR_MESA_HTML || path.join(__dirname, '../index.html'), 'utf8');
function trecho(inicio, fim){
  const i=html.indexOf(inicio), j=html.indexOf(fim,i+inicio.length);
  assert.ok(i>=0 && j>i, 'Marcadores do código real encontrados');
  return html.slice(i,j);
}
function preparar(){
  const nodes=new Map(), calls=[];
  const el=id=>{
    if(!nodes.has(id)){
      const classes=new Set(['hidden']);
      nodes.set(id,{value:'',innerHTML:'',textContent:'',disabled:false,handlers:{},
        addEventListener(event,fn){this.handlers[event]=fn;},querySelectorAll(){return [];},
        blur(){calls.push('blur:'+id);},focus(){calls.push('focus:'+id);},
        scrollIntoView(){calls.push('scroll:'+id);},
        classList:{contains:x=>classes.has(x),add:x=>classes.add(x),remove:x=>classes.delete(x),
          toggle(x,on){if(on)classes.add(x);else classes.delete(x);}}});
    }
    return nodes.get(id);
  };
  const context=vm.createContext({$:el,console,crypto:{randomUUID:()=> 'uuid-operacao'},
    escapeHtml:v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])),
    formatarReais:v=>'R$ '+Number(v).toFixed(2),formatarQuantidade:String,
    nomeUsuarioBar:()=> 'Operador',mensagemBancoAcesso:e=>e.message,
    modulosComerciais:{bar:true},abrirModalCancelarItem:()=>{},
    renderResumoFinanceiroMesa:()=>{},atualizarBotaoCancelarMesa:()=>{},
    atualizarBotaoTransferirMesa:()=>{},carregarBarMesas:async()=>{},
    podeAcessarBar:()=>true,
    resolverNomesFuncionariosBar:async()=>({}),
    buscarTodos:async()=>({data:[{id:'item',estornado:false}]}),
    supabase:{rpc:async name=>name==='bar_pedido_lancar'?{data:[{comanda_id:'comanda'}]}:{data:[{}]},
      from(){const q={select:()=>q,eq:()=>q,order:()=>q};return q;}},
    carregarHistoricoPagamentosMesa:async()=>{},
  });
  vm.runInContext("let barComandaAtualId='comanda',barMesaAtual={id:'mesa'},barMesaQtdItensValidos=0,barMesaQtdPagamentos=0,barMesaResumoAtual={},barMesaCarrinho=[],barMesaItemSelecionado=null,barSubViewAtual='mesas';",context);
  vm.runInContext(trecho('function atualizarBotaoRelatorioMesa(){','// Acompanha o papel na fila'),context);
  return {el,calls,context,run:s=>vm.runInContext(s,context)};
}
test('consumo preserva produto, autor, horário e escolhas, com seis colunas e cancelamento apenas do item elegível',()=>{
  const t=preparar();
  t.run(trecho('function renderItensComandaMesa(itens, nomesPorId){','function abrirModalCancelarItem(itemId){'));
  t.context.itens=[
    {id:'aberto',pedido_id:'p',quantidade:2,preco_unitario:15,produtos:{nome:'<Brahma>'},bar_pedidos:{criado_por:'autor',criado_em:'2026-10-23T15:41:40Z'},bar_pedidos_itens_escolhas:[{produto_nome:'Espeto',destino_operacional:'cozinha'}]},
    {id:'pago',quantidade:1,preco_unitario:5,pagamento_id:'pago',produtos:{nome:'Pago'}},
    {id:'cancelado',quantidade:1,preco_unitario:5,estornado:true,produtos:{nome:'Cancelado'}},
  ];
  t.run('renderItensComandaMesa(itens,{})');
  const body=t.el('bar-mesa-itens-body').innerHTML;
  assert.match(body,/&lt;Brahma&gt;/);assert.match(body,/Lançado por Operador/);assert.match(body,/Espeto/);assert.match(body,/Cozinha/);
  assert.equal((body.match(/<td>/g)||[]).length,18);
  assert.equal((body.match(/data-cancelar-item=/g)||[]).length,1);
  assert.doesNotMatch(body,/data-florest-cancelar-pedido|status-badge/);
  const table=html.slice(html.indexOf('id="bar-mesa-consumo-scroll"'),html.indexOf('id="bar-mesa-itens-body"'));
  assert.equal((table.match(/<th>/g)||[]).length,6);
});
test('adicionar produto deixa o carrinho visível e fecha a busca sem perder quantidade e observação',()=>{
  const t=preparar();
  t.run(trecho("$('btn-bar-mesa-add-carrinho').addEventListener",'function renderItensComandaMesa(itens, nomesPorId){'));
  t.run("barMesaItemSelecionado={id:'produto',tipo:'simples',produtos:{nome:'Brahma',preco_venda:15}};");
  t.el('bar-mesa-item-qtd').value='2';t.el('bar-mesa-item-obs').value='Sem gelo';
  t.el('bar-mesa-busca-resultados').classList.remove('hidden');
  t.el('btn-bar-mesa-add-carrinho').handlers.click();
  assert.equal(t.run('barMesaCarrinho[0].quantidade'),2);
  assert.equal(t.run('barMesaCarrinho[0].observacao'),'Sem gelo');
  assert.equal(t.el('bar-mesa-carrinho-wrap').classList.contains('hidden'),false);
  assert.equal(t.el('bar-mesa-busca-resultados').classList.contains('hidden'),true);
  assert.ok(t.calls.includes('scroll:bar-mesa-carrinho-wrap'));
  assert.ok(!t.calls.includes('focus:bar-mesa-busca-produto'));
});
test('produto composto incompleto não entra no pedido e mantém a escolha aberta',()=>{
  const t=preparar();
  t.run(trecho("$('btn-bar-mesa-add-carrinho').addEventListener",'function renderItensComandaMesa(itens, nomesPorId){'));
  t.run("barMesaItemSelecionado={id:'produto',tipo:'composto',bar_produto_grupos:[{id:'grupo'}]};");
  t.el('bar-mesa-item-qtd').value='1';
  t.el('bar-mesa-escolhas').querySelectorAll=()=>[{value:'',dataset:{escolhaGrupo:'grupo'}}];
  t.el('btn-bar-mesa-add-carrinho').handlers.click();
  assert.equal(t.run('barMesaCarrinho.length'),0);
  assert.match(t.el('bar-mesa-msg').innerHTML,/Responda todas as escolhas/);
});
test('lançar pedido fecha resultados e preserva itens enviados e vínculo da comanda',async()=>{
  const t=preparar();
  t.context.atualizarSaldoEItensMesa=async()=>{};
  const requests=[];t.context.supabase.rpc=async(name,args)=>{requests.push({name,args});return {data:[{comanda_id:'nova-comanda'}]};};
  t.run(trecho("$('btn-bar-mesa-add-carrinho').addEventListener",'function renderItensComandaMesa(itens, nomesPorId){'));
  t.run("barMesaCarrinho=[{barProdutoId:'produto',quantidade:2,precoUnitario:15,observacao:'Sem gelo',escolhas:null}];");
  t.el('bar-mesa-busca-resultados').classList.remove('hidden');
  await t.el('btn-bar-mesa-lancar').handlers.click();
  assert.equal(requests[0].name,'bar_pedido_lancar');assert.equal(requests[0].args.p_itens[0].quantidade,2);
  assert.equal(t.run('barComandaAtualId'),'nova-comanda');assert.equal(t.run('barMesaCarrinho.length'),0);
  assert.equal(t.el('bar-mesa-busca-resultados').classList.contains('hidden'),true);
});
test('impressão aparece com itens carregados mesmo enquanto histórico de pagamentos está pendente',async()=>{
  const t=preparar();let release;
  t.context.carregarHistoricoPagamentosMesa=()=>new Promise(resolve=>{release=resolve;});
  t.context.renderItensComandaMesa=()=>{};
  t.run(trecho('async function atualizarSaldoEItensMesa(){','// "TOTAL CONSUMIDO / JÁ PAGO / FALTA PAGAR"'));
  const pending=t.run('atualizarSaldoEItensMesa()');
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(typeof release,'function');
  assert.equal(t.el('btn-bar-mesa-relatorio').classList.contains('hidden'),false);
  release();await pending;
});
test('impressão continua oculta sem permissão, sem comanda ou sem consumo válido',()=>{
  const t=preparar();t.run('barMesaQtdItensValidos=1; atualizarBotaoRelatorioMesa();');
  assert.equal(t.el('btn-bar-mesa-relatorio').classList.contains('hidden'),false);
  t.context.podeAcessarBar=()=>false;t.run('atualizarBotaoRelatorioMesa();');
  assert.equal(t.el('btn-bar-mesa-relatorio').classList.contains('hidden'),true);
  t.context.podeAcessarBar=()=>true;t.run('barComandaAtualId=null; atualizarBotaoRelatorioMesa();');
  assert.equal(t.el('btn-bar-mesa-relatorio').classList.contains('hidden'),true);
  t.run("barComandaAtualId='comanda';barMesaQtdItensValidos=0;atualizarBotaoRelatorioMesa();");
  assert.equal(t.el('btn-bar-mesa-relatorio').classList.contains('hidden'),true);
});
