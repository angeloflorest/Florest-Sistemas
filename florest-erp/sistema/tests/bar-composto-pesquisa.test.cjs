const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const html = fs.readFileSync(path.join(__dirname, '../index.html'), 'utf8');
const source = html.slice(html.indexOf('// ---------- Produtos Compostos (ex-'), html.indexOf('// ---------- Garçons (Fase 4'));
const pagination = html.slice(html.indexOf('async function buscarTodos('), html.indexOf('// Texto de busca seguro'));
const EMPRESA = '4d71f26f-20ed-4c79-936f-8f71d487425f';
const PRODUTO = 'c3fa0e69-f6c8-4db3-ba9d-4be91ea49601';

function node(){
  const classes = new Set();
  return { value: '', textContent: '', disabled: false, options: [], handlers: {}, style: {},
    set innerHTML(v){ this.markup = v; this.options = []; this.value = ''; }, get innerHTML(){ return this.markup || ''; },
    appendChild(o){ this.options.push(o); }, reset(){},
    addEventListener(name, fn){ this.handlers[name] = fn; },
    classList: { add: x => classes.add(x), remove: x => classes.delete(x), contains: x => classes.has(x) } };
}
function setup(){
  const nodes = new Map(), calls = [], rpcCalls = [];
  const el = id => { if(!nodes.has(id)) nodes.set(id, node()); return nodes.get(id); };
  const db = {
    produtos: [
      { id: PRODUTO, empresa_id: EMPRESA, nome:'JANTINHA + ESPETO', ativo:true, preco_venda:25 },
      { id:'opcao', empresa_id:EMPRESA, nome:'ESPETO', ativo:true, preco_venda:10 },
      { id:'inativo', empresa_id:EMPRESA, nome:'INATIVO', ativo:false },
      { id:'outra-empresa', empresa_id:'empresa-bar', nome:'JANTINHA + ESPETO', ativo:true },
    ],
    bar_produtos: [{ id:'bar-original', empresa_id:EMPRESA, produto_id:PRODUTO, tipo:'simples',ativo_cardapio:true,bar_produto_grupos:[] }],
  };
  let empresa = EMPRESA, failure = null, permitido = true, confirmar = true, refreshes = 0;
  const confirmations=[];
  const context = vm.createContext({
    $:el, document: { createElement:node, querySelectorAll:()=>[] }, recursos:{produtoAtivo:true},
    debounce:fn=>fn, termoSeguro:String, podeAcessarBar:()=>permitido,
    confirm:msg=>{confirmations.push(msg);return confirmar;},
    obterEmpresaId:async () => empresa,
    escapeHtml:String, mensagemBancoAcesso:e => e.message, formatarReais:String,
    refresh:()=>{refreshes++;},
    supabase: { from(table){
      const filters = [], orders = [];
      const q = { select(){ return q; }, eq(k,v){ filters.push([k,v]); return q; },
        order(k){ orders.push(k); return q; },
        async range(a,b){
          calls.push({table,filters:[...filters],orders:[...orders],a,b});
          if(failure) return { error: {message:failure} };
          const rows = db[table].filter(r => filters.every(([k,v]) => r[k] === v));
          rows.sort((x,y) => { for(const k of orders){ const c=String(x[k]).localeCompare(String(y[k])); if(c) return c; } return 0; });
          return { data:rows.slice(a,b+1) };
        }, async single(){ return q.maybeSingle(); }, async maybeSingle(){
          calls.push({table,filters:[...filters],orders:[]});
          if(failure) return {error:{message:failure}};
          return { data: db[table].find(r => filters.every(([k,v]) => r[k] === v)) || null };
        },
      }; return q;
    }, async rpc(name,args){
      rpcCalls.push({name,args});
      const row=db.bar_produtos.find(p=>p.empresa_id===empresa && p.id===args.p_id);
      if(name==='bar_produto_salvar'){
        if(!row || row.produto_id!==args.p_produto_id) return {error:{message:'Vínculo incorreto'}};
        row.tipo=args.p_tipo; row.bar_produto_grupos=args.p_grupos.map((g,i)=>({...g,id:'g'+i,bar_produto_grupo_opcoes:g.opcoes}));
        return {data:row.id,error:null};
      }
      if(name==='bar_produto_composto_excluir'){
        if(!row || row.tipo!=='composto') return {error:{message:'Não encontrado'}};
        if(args.p_confirmar) row.ativo_cardapio=false;
        return {data:{id:row.id,empresa_id:empresa,nome:'JANTINHA + ESPETO',ativo_cardapio:row.ativo_cardapio,pedidos_itens:3,escolhas_historicas:2,dependencias:0},error:null};
      }
      return {error:{message:'RPC inesperada'}};
    } },
  });
  vm.runInContext('let barProdutosCatalogoCache=null, barProdutoModalReq=0, barProdutoBarEditandoId=null, barGruposEdicao=[],barProdutoBaseEditandoId=null,barProdutoSalvando=false,barProdutoExcluindo=false,barProdutosListaReq=0;\n' + pagination + source + '\nrenderGruposEdicao = () => {}; const carregarListaReal=carregarBarProdutos; carregarBarProdutos = async () => refresh();', context);
  return { el,db,calls,rpcCalls,run:s=>vm.runInContext(s,context),
    setEmpresa:v=>{empresa=v;}, fail:v=>{failure=v;},
    setPermissao:v=>{permitido=v;}, setConfirmar:v=>{confirmar=v;}, confirmations, getRefreshes:()=>refreshes,
    search(term){el('bar-produto-busca').value=term;el('bar-produto-busca').oninput();},
  };
}

test('JANTINHA + ESPETO simples aparece na busca e pode ser selecionado pelo UUID original', async () => {
  const s=setup(); await s.run('abrirModalProdutoBar(null)'); s.search('jantinha + espeto');
  const options=s.el('bar-produto-produto').options;
  assert.deepEqual(options.filter(o=>o.value).map(o=>o.value),[PRODUTO]);
  s.el('bar-produto-produto').value=PRODUTO; s.el('bar-produto-produto').onchange();
  assert.match(s.el('bar-produto-preco-atual').textContent,/25/);
  assert.equal(s.el('btn-salvar-produto-bar').disabled,false);
  assert.equal(s.rpcCalls.length,0);
});

test('novo produto aparece ao reabrir o composto sem recarregar a página', async () => {
  const s=setup(); await s.run('abrirModalProdutoBar(null)');
  s.db.produtos.push({id:'novo',empresa_id:EMPRESA,nome:'NOVO PRODUTO TESTE',ativo:true});
  await s.run('abrirModalProdutoBar(null)'); s.search('novo produto');
  assert.deepEqual(s.el('bar-produto-produto').options.filter(o=>o.value).map(o=>o.value),['novo']);
});

test('paginação recupera mais de 1000 produtos com ordem estável e empresa em todas as páginas', async () => {
  const s=setup();
  for(let i=0;i<1201;i++) s.db.produtos.push({id:`p${i}`,empresa_id:EMPRESA,nome:'AAA MESMO NOME',ativo:true});
  await s.run('abrirModalProdutoBar(null)'); s.search('jantinha');
  assert.equal(s.el('bar-produto-produto').options[1].value,PRODUTO);
  assert.ok(s.calls.filter(c=>c.table==='produtos').length>=3);
  for(const c of s.calls){
    assert.ok(c.filters.some(([k,v])=>k==='empresa_id'&&v===EMPRESA));
    assert.ok(c.orders.includes('id'));
  }
});

test('produtos inativos e de outra empresa não aparecem; mudança de sessão renova o catálogo', async () => {
  const s=setup(); await s.run('abrirModalProdutoBar(null)');
  const values=s.el('bar-produto-produto').options.map(o=>o.value);
  assert.ok(!values.includes('outra-empresa')); assert.ok(!values.includes('inativo'));
  s.setEmpresa('empresa-bar'); await s.run('abrirModalProdutoBar(null)');
  assert.deepEqual(s.el('bar-produto-produto').options.filter(o=>o.value).map(o=>o.value),['outra-empresa']);
});

test('seleção é enviada à RPC existente com grupos válidos e sem criar produto', async () => {
  const s=setup(); await s.run('abrirModalProdutoBar(null)'); s.search('jantinha');
  s.el('bar-produto-produto').value=PRODUTO;
  s.run("barGruposEdicao=[{nome:'Escolha o espeto',quantidade_escolhas:1,opcoes:[{produto_id:'opcao'}]}]");
  await s.el('form-bar-produto').handlers.submit({preventDefault(){}});
  const {name,args}=s.rpcCalls[0];
  assert.equal(name,'bar_produto_salvar'); assert.equal(args.p_id,'bar-original');
  assert.equal(args.p_produto_id,PRODUTO); assert.equal(args.p_tipo,'composto');
  assert.equal(args.p_componentes,null); assert.equal(args.p_grupos[0].opcoes[0].produto_id,'opcao');
  assert.equal(s.db.produtos.length,4);
});

test('Editar mantém o produto-base e recarrega os grupos salvos sem duplicar vínculo', async()=>{
  const s=setup(); await s.run('abrirModalProdutoBar(null)');
  s.el('bar-produto-produto').value=PRODUTO;
  s.run("barGruposEdicao=[{nome:'Escolha',quantidade_escolhas:1,opcoes:[{produto_id:'opcao'}]}]");
  await s.el('form-bar-produto').handlers.submit({preventDefault(){}});
  assert.equal(s.db.bar_produtos.length,1);
  await s.run("abrirModalProdutoBar('bar-original')");
  assert.equal(s.el('bar-produto-produto').disabled,true);
  assert.equal(s.el('bar-produto-busca').disabled,true);
  assert.equal(s.run('barGruposEdicao[0].opcoes[0].produto_id'),'opcao');
  s.el('bar-produto-produto').value='opcao';
  await s.el('form-bar-produto').handlers.submit({preventDefault(){}});
  assert.equal(s.rpcCalls.length,1);
  assert.match(s.el('bar-produto-msg').innerHTML,/produto-base não pode ser trocado/);
});

test('Excluir exige confirmação nominal e desativa sem apagar produto, grupos ou histórico', async()=>{
  const s=setup(); s.db.bar_produtos[0].tipo='composto';
  s.db.bar_produtos[0].bar_produto_grupos=[{id:'grupo-historico'}];
  const produtosAntes=JSON.stringify(s.db.produtos), gruposAntes=JSON.stringify(s.db.bar_produtos[0].bar_produto_grupos);
  await s.run("excluirProdutoCompostoBar('bar-original')");
  assert.equal(s.rpcCalls.length,2);
  assert.equal(s.rpcCalls[0].args.p_confirmar,false);
  assert.equal(s.rpcCalls[1].args.p_nome_confirmado,'JANTINHA + ESPETO');
  assert.match(s.confirmations[0],/JANTINHA \+ ESPETO/);
  assert.match(s.confirmations[0],/3 item/);
  assert.equal(s.db.bar_produtos[0].ativo_cardapio,false);
  assert.equal(s.db.bar_produtos.length,1);
  assert.equal(JSON.stringify(s.db.produtos),produtosAntes);
  assert.equal(JSON.stringify(s.db.bar_produtos[0].bar_produto_grupos),gruposAntes);
  assert.equal(s.getRefreshes(),1);
});

test('cancelar Excluir não executa a mutação', async()=>{
  const s=setup(); s.db.bar_produtos[0].tipo='composto'; s.setConfirmar(false);
  await s.run("excluirProdutoCompostoBar('bar-original')");
  assert.equal(s.rpcCalls.length,1);
  assert.equal(s.db.bar_produtos[0].ativo_cardapio,true);
  assert.equal(s.getRefreshes(),0);
});

test('sem permissão não salva nem exclui; outra empresa não consegue excluir o vínculo', async()=>{
  const s=setup(); s.setPermissao(false);
  await s.run("excluirProdutoCompostoBar('bar-original')"); assert.equal(s.rpcCalls.length,0);
  s.setPermissao(true); s.setEmpresa('empresa-bar');
  await s.run("excluirProdutoCompostoBar('bar-original')");
  assert.equal(s.rpcCalls.length,1); assert.equal(s.confirmations.length,0);
  assert.equal(s.db.bar_produtos[0].ativo_cardapio,true);
});

test('erro ao resolver o vínculo não insere nem chama a RPC e permite tentar novamente', async()=>{
  const s=setup(); await s.run('abrirModalProdutoBar(null)');
  s.el('bar-produto-produto').value=PRODUTO;
  s.run("barGruposEdicao=[{nome:'Escolha',quantidade_escolhas:1,opcoes:[{produto_id:'opcao'}]}]");
  s.fail('Erro de consulta');
  await s.el('form-bar-produto').handlers.submit({preventDefault(){}});
  assert.equal(s.rpcCalls.length,0); assert.equal(s.el('btn-salvar-produto-bar').disabled,false);
  assert.match(s.el('bar-produto-msg').innerHTML,/Erro de consulta/);
});

test('erro de consulta não usa cache antigo nem libera salvar', async () => {
  const s=setup(); await s.run('abrirModalProdutoBar(null)');
  s.fail('Sem conexão'); await s.run('abrirModalProdutoBar(null)');
  assert.equal(s.el('bar-produto-produto').options.length,0);
  assert.equal(s.el('btn-salvar-produto-bar').disabled,true);
  assert.match(s.el('bar-produto-msg').innerHTML,/Sem conexão/);
});

test('pesquisa sem resultado limpa seleção e não salva produto anterior', async () => {
  const s=setup(); await s.run('abrirModalProdutoBar(null)');
  s.el('bar-produto-produto').value=PRODUTO; s.search('não existe');
  assert.equal(s.el('bar-produto-produto').value,'');
  await s.el('form-bar-produto').handlers.submit({preventDefault(){}});
  assert.equal(s.rpcCalls.length,0);
  assert.match(s.el('bar-produto-msg').innerHTML,/Selecione um produto/);
});
