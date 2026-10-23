const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

test('tela: converter simples, editar grupos, cancelar Excluir e excluir com confirmação',
  {skip:!process.env.BAR_COMPOSTO_BROWSER},async()=>{
  const {chromium}=require(process.env.BAR_COMPOSTO_BROWSER);
  const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
  const section=html.slice(html.indexOf('<div id="bar-sub-produtos"'),html.indexOf('<div id="bar-sub-relatorios"'));
  const modal=html.slice(html.indexOf('<div id="modal-bar-produto"'),html.indexOf('<!-- ---- MODAL: GARÇOM'));
  const source=html.slice(html.indexOf('// ---------- Produtos Compostos (ex-'),html.indexOf('// ---------- Garçons (Fase 4'));
  const pagination=html.slice(html.indexOf('async function buscarTodos('),html.indexOf('// Texto de busca seguro'));
  const browser=await chromium.launch({channel:'msedge',headless:true});
  try {
    const page=await browser.newPage(); const errors=[];
    page.on('pageerror',e=>errors.push(e.message));
    await page.setContent('<style>'+html.split('<style>')[1].split('</style>')[0]+'</style>'+section+modal);
    await page.addScriptTag({content:`
      const $=id=>document.getElementById(id);
      const escapeHtml=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
      const obterEmpresaId=async()=> 'empresa';const podeAcessarBar=()=>true;
      const recursos={produtoAtivo:true},formatarReais=String,mensagemBancoAcesso=e=>e.message,termoSeguro=String,debounce=fn=>fn;
      let barProdutosCatalogoCache=null,barProdutoModalReq=0,barProdutoBarEditandoId=null,barGruposEdicao=[],barProdutoBaseEditandoId=null,barProdutoSalvando=false,barProdutoExcluindo=false,barProdutosListaReq=0;
      window.dados={produtos:[{id:'base',empresa_id:'empresa',nome:'JANTINHA + ESPETO',ativo:true,preco_venda:25},{id:'opcao',empresa_id:'empresa',nome:'ESPETO',ativo:true,preco_venda:10}],bar_produtos:[{id:'vinculo-existente',empresa_id:'empresa',produto_id:'base',tipo:'simples',ativo_cardapio:true,bar_produto_grupos:[]}]};
      window.chamadas=[];window.historico=[{pedido:'preservado',baixa:'preservada'}];
      const supabase={from(t){const filters=[];const rows=()=>window.dados[t].filter(r=>filters.every(([k,v])=>r[k]===v));const q={
        select(){return q},eq(k,v){filters.push([k,v]);return q},order(){return q},
        async range(a,b){if(!filters.some(([k,v])=>k==='empresa_id'&&v==='empresa'))throw Error('Falta empresa');return {data:rows().slice(a,b+1).map(r=>({...r,produtos:window.dados.produtos.find(p=>p.id===r.produto_id)}))}},
        async maybeSingle(){return {data:rows()[0]||null}},async single(){return q.maybeSingle()}
      };return q},async rpc(n,a){window.chamadas.push({n,a});const r=window.dados.bar_produtos.find(r=>r.id===a.p_id);
        if(!r)return {error:{message:'Vínculo não encontrado'}};
        if(n==='bar_produto_salvar'){
          if(r.produto_id!==a.p_produto_id)return {error:{message:'Este produto já está cadastrado no cardápio do bar.'}};
          r.tipo=a.p_tipo;r.ativo_cardapio=a.p_ativo_cardapio;
          r.bar_produto_grupos=a.p_grupos.map((g,i)=>({...g,id:'grupo'+i,bar_produto_grupo_opcoes:g.opcoes}));
          return {data:r.id};
        }
        if(n==='bar_produto_composto_excluir'){
          if(a.p_confirmar){if(a.p_nome_confirmado!=='JANTINHA + ESPETO')throw Error('Sem nome confirmado');r.ativo_cardapio=false;}
          return {data:{id:r.id,empresa_id:'empresa',nome:'JANTINHA + ESPETO',ativo_cardapio:r.ativo_cardapio,pedidos_itens:1,escolhas_historicas:1,dependencias:0}};
        }
        throw Error('RPC não prevista');
      }};
      ${pagination}
      ${source}
      $('bar-sub-produtos').classList.remove('hidden');
      carregarBarProdutos();
    `});
    await page.locator('#btn-novo-produto-bar').click();
    await page.locator('#bar-produto-produto option[value="base"]').waitFor({state:'attached'});
    await page.locator('#bar-produto-produto').selectOption('base');
    await page.locator('#btn-bar-produto-add-grupo').click();
    await page.locator('#bar-produto-grupos-lista input[type="text"]').fill('Escolha o espeto');
    await page.locator('#bar-produto-grupos-lista label').filter({hasText:/^ESPETO$/}).locator('input').check();
    await page.locator('#btn-salvar-produto-bar').click();
    await page.locator('[data-editar-produto-bar="vinculo-existente"]').waitFor();
    assert.equal(await page.evaluate(()=>window.chamadas[0].a.p_id),'vinculo-existente');
    await page.locator('[data-editar-produto-bar="vinculo-existente"]').click();
    await page.locator('#bar-produto-grupos-lista input[type="text"]').waitFor();
    assert.equal(await page.locator('#bar-produto-produto').isDisabled(),true);
    await page.locator('#bar-produto-grupos-lista input[type="text"]').fill('Grupo editado');
    await page.locator('#btn-salvar-produto-bar').click();
    await page.locator('#modal-bar-produto').waitFor({state:'hidden'});
    const before=await page.evaluate(()=>JSON.stringify({produtos:window.dados.produtos,grupos:window.dados.bar_produtos[0].bar_produto_grupos,historico:window.historico}));
    page.once('dialog',dialog=>dialog.dismiss());
    await page.locator('[data-excluir-produto-bar="vinculo-existente"]').click();
    await page.waitForFunction(()=>window.chamadas.some(c=>c.n==='bar_produto_composto_excluir'));
    assert.equal(await page.locator('[data-excluir-produto-bar="vinculo-existente"]').count(),1);
    let mensagem='';page.once('dialog',dialog=>{mensagem=dialog.message();return dialog.accept();});
    await page.locator('[data-excluir-produto-bar="vinculo-existente"]').click();
    await page.waitForFunction(()=>document.querySelectorAll('[data-excluir-produto-bar]').length===0);
    assert.match(mensagem,/JANTINHA \+ ESPETO/);
    assert.equal(await page.evaluate(()=>window.dados.bar_produtos.length),1);
    assert.equal(await page.evaluate(()=>window.dados.bar_produtos[0].ativo_cardapio),false);
    assert.equal(await page.evaluate(()=>JSON.stringify({produtos:window.dados.produtos,grupos:window.dados.bar_produtos[0].bar_produto_grupos,historico:window.historico})),before);
    assert.deepEqual(errors,[]);
  } finally {await browser.close();}
});
