const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

// Teste opcional da interface real em navegador, com transporte somente de leitura simulado.
// BAR_REL_BROWSER aponta para o pacote playwright; BAR_REL_SNAPSHOT para um SELECT temporário.
test('interface: quatro relatórios, cinco seletores, Limpar, isolamento e XLSX válido',
  {skip:!process.env.BAR_REL_BROWSER || !process.env.BAR_REL_SNAPSHOT}, async()=>{
  const {chromium}=require(process.env.BAR_REL_BROWSER);
  const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
  const snapshot=JSON.parse(fs.readFileSync(process.env.BAR_REL_SNAPSHOT,'utf8'));
  const library=fs.readFileSync(path.join(__dirname,'.sheetjs-test.tmp.mjs'),'utf8');
  const ui=html.slice(html.indexOf('<div id="bar-sub-relatorios"'),html.indexOf('<!-- ---- SUBVIEW: GARÇONS'));
  const code=html.slice(html.indexOf('let barRelRelatorioAtual ='),html.indexOf('// ---------- Geradores de relatório — Módulo Bar'));
  const doc=html.slice(html.indexOf('function montarHtmlDocumentoRelatorio('),html.indexOf('// ---------- Nome da empresa para o cabeçalho'));
  const pagination=html.slice(html.indexOf('async function buscarTodos('),html.indexOf('// Texto de busca seguro'));
  const stubs=[...new Set([...code.matchAll(/gerar: (relatorio\w+)/g)].map(m=>m[1]))].filter(n=>n!=='relatorioBarHistoricoMesaCaixa').map(n=>`function ${n}(){}`).join('\n');
  const browser=await chromium.launch({channel:'msedge',headless:true});
  try {
    const page=await browser.newPage({acceptDownloads:true,viewport:{width:1280,height:900}});
    const errors=[]; page.on('pageerror',e=>errors.push(e.message));
    await page.route('https://cdn.sheetjs.com/**',r=>r.fulfill({status:200,headers:{'access-control-allow-origin':'*'},contentType:'text/javascript',body:library}));
    await page.setContent('<style>'+html.split('<style>')[1].split('</style>')[0]+'</style>'+ui+'<div id="rel-impressao-area"></div>');
    const prelude=`
      const $=id=>document.getElementById(id); const fixture=${JSON.stringify(snapshot.d)};
      const aliases={produtos:'produtos',bar_mesas:'mesas',bar_comandas:'comandas',vendas:'vendas',bar_pagamentos:'pagamentos',bar_pagamentos_formas:'formas',caixas:'caixas',bar_pedidos_itens:'itens',bar_pedidos_itens_baixas:'baixas',bar_produtos:'barProdutos'};
      window.permitido=true;window.consultas=[];
      const visivelBarSubview=()=>window.permitido; const obterEmpresaId=async()=> 'empresa-da-sessao';
      const escapeHtml=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
      const mensagemBancoAcesso=e=>e.message; const dataLocalISO=d=>d.toISOString().slice(0,10);
      const formatarDataBR=String, cxDataHora=String, brl=String;
      const obterNomeEmpresaImpressaoRelatorio=async()=> 'Empresa de teste';
      const supabase={from(t){ const filters=[]; const q={select(){return q},eq(k,v){filters.push([k,v]);return q},order(){return q},async range(a,b){
        window.consultas.push({t,filters});
        if(!filters.some(([k,v])=>k==='empresa_id'&&v==='empresa-da-sessao'))throw Error('Consulta sem empresa');
        return {data:(fixture[aliases[t]]||[]).slice(a,b+1)};
      }};return q;}};
    `;
    await page.addScriptTag({type:'module',content:prelude+stubs+pagination+doc+code+`
      window.abrirTeste=id=>abrirFiltrosRelatorioBar(SECOES_RELATORIOS_BAR.find(r=>r.id===id));
      window.aguardarFiltros=barNovoAguardarFiltros;window.calcularTeste=barNovoCalcular;
      window.trocarDados=fn=>fn(fixture);window.quantidadeRelatorios=SECOES_RELATORIOS_BAR.length;
      $('bar-sub-relatorios').classList.remove('hidden');
    `});
    await page.waitForFunction(()=>window.abrirTeste);
    assert.equal(await page.evaluate(()=>window.quantidadeRelatorios),14);
    for(const tipo of ['periodo','caixa','produto','comparativo']){
      await page.evaluate(t=>window.abrirTeste('bar_novo_'+t),tipo);
      await page.evaluate(()=>window.aguardarFiltros());
      await page.locator('#bar-rel-filtro-data-inicio').fill('2020-01-01');
      await page.locator('#bar-rel-filtro-data-fim').fill('2030-12-31');
      if(tipo==='comparativo'){
        assert.equal(await page.locator('[data-bar-novo-produto]').count(),5);
        for(let i=1;i<=5;i++) await page.locator('#bar-novo-produto-'+i).selectOption(snapshot.produtos[i-1]);
        assert.equal(await page.locator('#bar-novo-produto-2 option[value="'+snapshot.produtos[0]+'"]').count(),0);
      }
      await page.locator('#btn-bar-rel-gerar').click();
      await page.locator('#bar-rel-passo-documento').waitFor({state:'visible'});
      assert.ok(await page.locator('#bar-rel-doc-folha table').count()>0);
      const [download]=await Promise.all([page.waitForEvent('download'),page.locator('#btn-bar-rel-exportar-xlsx').click()]);
      assert.ok(download.suggestedFilename().endsWith('.xlsx'));
      const stream=await download.createReadStream(); const chunks=[]; for await(const chunk of stream)chunks.push(chunk);
      const bytes=Buffer.concat(chunks); assert.equal(bytes.subarray(0,2).toString(),'PK');
      const metadata=await page.evaluate(async base64=>{
        const XLSX=await import('https://cdn.sheetjs.com/xlsx-0.20.3/package/xlsx.mjs');
        const wb=XLSX.read(base64,{type:'base64'});
        return {sheets:wb.SheetNames,totais:XLSX.utils.sheet_to_json(wb.Sheets.Totais,{header:1})};
      },bytes.toString('base64'));
      assert.ok(metadata.sheets.includes('Totais')); assert.ok(metadata.sheets.includes('Dados'));
      assert.equal(typeof metadata.totais[1][1],'number');
      if(tipo==='comparativo') assert.ok(metadata.sheets.includes('Comparação diária'));
      await page.locator('#btn-bar-rel-doc-voltar').click();
      await page.locator('#btn-bar-rel-novos-limpar').click();
      assert.equal(await page.locator('#bar-rel-filtro-data-inicio').inputValue(),'');
      assert.equal(await page.locator('#bar-rel-doc-folha').innerHTML(),'');
    }
    const consultas=await page.evaluate(()=>window.consultas.length);
    await page.evaluate(()=>{window.permitido=false;window.abrirTeste('bar_novo_comparativo');});
    assert.equal(await page.evaluate(()=>window.consultas.length),consultas);
    assert.deepEqual(errors,[]);
  } finally {await browser.close();}
});
