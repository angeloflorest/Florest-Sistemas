const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path');
const modelo='data:text/javascript;base64,'+Buffer.from(fs.readFileSync(path.join(__dirname,'../fiscal-nfe55-modelo.js'),'utf8')).toString('base64');
const source=fs.readFileSync(path.join(__dirname,'../fiscal-nfe55.js'),'utf8').replace("'./fiscal-nfe55-modelo.js'",JSON.stringify(modelo));
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
const moduleUrl='data:text/javascript;base64,'+Buffer.from(source).toString('base64');
test('NF-e é modelo 55 e usa a série do cadastro, sem constante fixa',async()=>{const m=await import(moduleUrl);assert.equal(m.NFE55_MODELO,'55');assert.equal(m.NFE55_SERIE,undefined);});
test('pesquisa exige venda ou período válido, sem interpretar código como SQL',async()=>{
 const m=await import(moduleUrl);
 assert.doesNotThrow(()=>m.validarBuscaNfe55('123','',''));
 assert.doesNotThrow(()=>m.validarBuscaNfe55('','2026-11-01','2026-11-06'));
 for(const args of [['','',''],['-1','',''],['1 or 1=1','',''],['','2026-02-30','2026-03-01'],['','2026-11-07','2026-11-06']])assert.throws(()=>m.validarBuscaNfe55(...args));
});
test('conferência identifica venda cancelada, documento autorizado e resposta incerta',async()=>{
 const m=await import(moduleUrl);
 assert.match(m.impedimentoDocumentoNfe55({cancelada_em:'2026-11-06'},[]),/cancelada/);
 for(const type of ['nfe','nfce'])for(const status of ['autorizada','processando','nao_emitida','desconhecida'])assert.ok(m.impedimentoDocumentoNfe55({},[{tipo_documento:type,status}]));
 assert.equal(m.impedimentoDocumentoNfe55({},[{tipo_documento:'nfce',status:'cancelada'}]),'');
 assert.equal(m.impedimentoDocumentoNfe55({},[{tipo_documento:'nfce',status:'rejeitada'}]),'');
});
test('navegador: nova aba consulta somente a empresa, mostra a venda, impede transmissão e descarta resposta antiga', {skip:!process.env.NFE55_BROWSER},async()=>{
 const {chromium}=require(process.env.NFE55_BROWSER);
 const browser=await chromium.launch({executablePath:'/usr/bin/chromium',headless:true,args:['--no-sandbox']});
 try{
  const page=await browser.newPage({viewport:{width:1200,height:1000}}),errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  const pane=html.slice(html.indexOf('      <div id="fiscal-aba-nfe55"'),html.indexOf('      <div id="fiscal-aba-xml-contador"'));
  const siblings=['docs','corrigir','contingencia','xml-contador'];
  await page.setContent('<style>.hidden{display:none}label{display:block}input,button{padding:8px;margin:5px}table{width:100%}td,th{padding:8px;text-align:left}.lista-item{padding:10px}</style>'+siblings.map(id=>`<button id="fiscal-aba-btn-${id}">${id}</button><div id="fiscal-aba-${id}">${id}</div>`).join('')+'<button id="fiscal-aba-btn-nfe55">Emitir NF-e (55)</button>'+pane);
  await page.evaluate(async url=>{
   window.state={empresa:'empresa-a',usuario:'user-a',documentos:[],calls:[],writes:0,hold:false};
   const result=(table,filters,columns)=>{
    if(!filters.some(([key,value])=>key==='empresa_id'&&value===window.state.empresa))throw Error('Consulta sem filtro da empresa');
    if(table==='configuracoes_fiscais')return {empresa_id:window.state.empresa,nfe_serie:'1',crt:'1',razao_social:'Loja <img src=x onerror=alert(1)>',cnpj:'00000000000000',nfce_ambiente:'homologacao',certificado_status:'válido'};
    if(table==='contadores_fiscais')return {ultimo_numero:99};
    if(table==='documentos_fiscais')return window.state.documentos;
    if(table==='itens_venda')return [{empresa_id:window.state.empresa,quantidade:2,preco_unitario:10,subtotal:20,produtos:{nome:'Produto cadastrado',ncm:'12345678',cfop:'5102',tipo_fiscal:'produto'}}];
    const v={id:'venda-a',empresa_id:window.state.empresa,numero_venda:123,total:20,criado_em:'2026-11-06T12:00:00Z',forma_pagamento:'Pix',clientes:{nome:'Cliente cadastrado',cpf:'00000000000'}};
    return filters.some(([key])=>key==='id')?v:[v];
   };
   const client={auth:{getSession:async()=>({data:{session:{user:{id:window.state.usuario}}}}),onAuthStateChange:fn=>{window.authChanged=fn;return{data:{subscription:{unsubscribe(){}}}};}},from(table){const filters=[];let columns;
    const read=async()=>{window.state.calls.push({table,filters:[...filters],columns});const data=result(table,filters,columns);if(window.state.hold&&table==='vendas')return new Promise(resolve=>{window.release=()=>resolve({data});});return {data};};
    return {select(value){columns=value;return this;},eq(k,v){filters.push([k,v]);return this;},gte(){return this;},lte(){return this;},order(){return this;},limit(){return this;},maybeSingle:read,single:read,then(resolve,reject){return read().then(resolve,reject);},insert(){window.state.writes++;throw Error('Gravação proibida');},update(){window.state.writes++;throw Error('Gravação proibida');}};
   },rpc(){window.state.writes++;throw Error('RPC proibida');},functions:{invoke(_name,{body}){if(body.acao==='preparar')return Promise.resolve({error:{message:'Backend indisponível no mock'}});window.state.writes++;throw Error('Emissão proibida');}}};
   const {instalarAbaNfe55}=await import(url);
   window.controller=instalarAbaNfe55({document,supabase:client,obterEmpresaId:async()=>window.state.empresa,podeAcessar:()=>true,formatarReais:n=>'R$ '+Number(n).toFixed(2)});
   window.nfe55Abrir=()=>window.controller.abrir();window.FCP={};window.$=id=>document.getElementById(id);window.fcpAbrir=()=>{};window.ctgAbrirAba=()=>{};window.xmlcAbrir=()=>{};
  },moduleUrl);
  const switcher=html.slice(html.indexOf('function fcpTrocarAba('),html.indexOf('async function fcpAbrir(')).replace('function fcpTrocarAba(', 'window.trocar=function(').replaceAll('nfe55Painel','window.controller');
  await page.addScriptTag({content:switcher});
  await page.evaluate(()=>document.getElementById('fiscal-aba-btn-nfe55').onclick=()=>window.trocar('nfe55'));
  await page.click('#fiscal-aba-btn-nfe55');
  await page.waitForFunction(()=>document.getElementById('nfe55-emitente').textContent.includes('99'));
  assert.equal(await page.locator('#fiscal-aba-nfe55 input[readonly]').count(),2);
  assert.equal(await page.locator('#nfe55-emitente img').count(),0);
  assert.equal(await page.locator('#fiscal-aba-docs').isVisible(),false);
  await page.fill('#nfe55-numero','123');await page.click('#nfe55-pesquisar');await page.getByRole('button',{name:'Conferir para NF-e'}).waitFor();await page.getByRole('button',{name:'Conferir para NF-e'}).click();
  await page.waitForFunction(()=>document.getElementById('nfe55-detalhes').textContent.includes('Produto cadastrado'));
  assert.equal(await page.locator('#nfe55-transmitir').isDisabled(),true);
  await page.evaluate(()=>window.state.documentos=[{empresa_id:window.state.empresa,tipo_documento:'nfce',status:'autorizada',numero:'15'}]);
  await page.getByRole('button',{name:'Conferir para NF-e'}).click();await page.waitForFunction(()=>document.getElementById('nfe55-msg').textContent.includes('NFC-e'));
  await page.evaluate(()=>{window.state.hold=true;window.state.documentos=[];});await page.fill('#nfe55-numero','123');await page.click('#nfe55-pesquisar');await page.waitForFunction(()=>typeof window.release==='function');
  await page.evaluate(()=>{window.state.usuario='user-b';window.state.empresa='empresa-b';window.authChanged();window.release();});
  await page.waitForTimeout(50);assert.equal(await page.locator('#nfe55-resultados').textContent(),'');assert.equal(await page.locator('#nfe55-detalhes').textContent(),'');
  await page.evaluate(()=>window.trocar('docs'));assert.equal(await page.locator('#fiscal-aba-docs').isVisible(),true);assert.equal(await page.locator('#fiscal-aba-nfe55').isVisible(),false);
  // A failed lazy import must be contained in the new pane, not crash the app.
  const lazy=html.slice(html.indexOf('async function nfe55Abrir('),html.indexOf("$('fiscal-aba-btn-nfe55').addEventListener",html.indexOf('async function nfe55Abrir(')));
  await page.addScriptTag({content:'let nfe55Painel=null,nfe55Carregamento=null;const podeAcessar=()=>true;'+lazy});
  await page.evaluate(async()=>{window.FCP.aba='nfe55';await window.nfe55Abrir();});
  assert.match(await page.locator('#nfe55-msg').textContent(),/outras funções do ERP continuam disponíveis/);
  await page.evaluate(()=>window.trocar('docs'));
  assert.equal(await page.locator('#fiscal-aba-docs').isVisible(),true);
  assert.equal(await page.evaluate(()=>window.state.writes),0);assert.deepEqual(errors,[]);
 }finally{await browser.close();}
});

test('navegador: conferência → confirmação produção → pendência → consulta → XML e DANFE, sem novo POST', {skip:!process.env.NFE55_BROWSER},async()=>{
 const {chromium}=require(process.env.NFE55_BROWSER),browser=await chromium.launch({executablePath:'/usr/bin/chromium',headless:true,args:['--no-sandbox']});
 try{
  const page=await browser.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));page.on('dialog',d=>d.accept());
  const pane=html.slice(html.indexOf('      <div id="fiscal-aba-nfe55"'),html.indexOf('      <div id="fiscal-aba-xml-contador"'));
  await page.setContent(pane.replace('class="hidden"',''));
  await page.evaluate(async url=>{
   const empresa='empresa-a',id='venda-a';window.calls=[];
   const cliente={nome:'Cliente exemplo',cpf:'52998224725'},venda={id,empresa_id:empresa,numero_venda:123,total:20,forma_pagamento:'Dinheiro',criado_em:'2026-11-06T12:00:00Z',clientes:cliente};
   const item={id:1,empresa_id:empresa,quantidade:2,preco_unitario:10,subtotal:20,produtos:{nome:'Produto exemplo',codigo:'1',ncm:'12345678',cfop:'5102',unidade_comercial:'UN',tipo_fiscal:'produto'}};
   let registro=null;window.mockCrt='3';window.mockVazios=false;window.resetRegistro=()=>{registro=null;};
   const client={auth:{getSession:async()=>({data:{session:{user:{id:'user-a'}}}}),onAuthStateChange:()=>({data:{subscription:{unsubscribe(){}}}})},from(table){let byid=false;const value=()=>table==='vendas'?(byid?venda:[venda]):table==='itens_venda'?[item]:table==='documentos_fiscais'?[]:table==='contadores_fiscais'?{ultimo_numero:123}:{empresa_id:empresa,nfe_serie:'4',crt:'3',razao_social:'Empresa exemplo'};
    const q={select(){return q},eq(k){if(k==='id')byid=true;return q},gte(){return q},lte(){return q},order(){return q},limit(){return q},single:async()=>({data:value()}),maybeSingle:async()=>({data:value()}),then(resolve,reject){return Promise.resolve({data:value()}).then(resolve,reject)}};return q;
   },functions:{async invoke(name,{body}){window.calls.push({name,body});
    if(body.acao==='preparar')return {data:{conferencia_hash:'hash-simulado',snapshot:{emitente:{nfe_serie:'4',crt:window.mockCrt},venda:{...venda,cliente},itens:[{...item,produto:{...item.produtos,id:'produto-a',gtin:'SEM GTIN',origem_mercadoria:'0',cst_csosn:window.mockCrt==='1'?'102':'90',cst_pis:window.mockVazios?'':'07',cst_cofins:window.mockVazios?'':'07'}}]},registro}};
    if(body.acao==='clientes')return {data:{empresa_id:empresa,clientes:[{id:'cliente-cnpj',empresa_id:empresa,nome:'Cliente CNPJ',cpf:'11222333000181',logradouro:'Rua CNPJ',numero:'1',bairro:'Centro',cidade:'Belo Horizonte',uf:'MG',cep:'30000000'},{id:'cliente-cpf',empresa_id:empresa,nome:'Cliente CPF',cpf:'52998224725',logradouro:'Rua CPF',numero:'2',bairro:'Centro',cidade:'Belo Horizonte',uf:'MG',cep:'30000000'}]}};
    if(body.acao==='lista')return {data:{tipo:body.tipo,itens:[{codeCST:'90',description:'Outros — lista oficial simulada',CRT:[2,3]}],aviso:'Página retornada pelo fornecedor; consulta parcial.'}};
    if(body.acao==='calcular')return {data:{revisao:{...body.revisao,totais:Object.fromEntries(['vBC','vICMS','vICMSDeson','vFCP','vBCST','vFCPST','vFCPSTRet','vFrete','vSeg','vDesc','vII','vIPI','vIPIDevol','vPIS','vCOFINS','vOutro'].map(k=>[k,'0.00']))},aviso:'Cálculo oficial simulado; nenhuma nota foi transmitida.'}};
    if(body.acao==='validar'){const faltas=[];for(const item of body.revisao.itens)for(const group of ['PIS','COFINS'])if(!item.imposto[group].CST)faltas.push('CST de '+group+' ausente');return {data:{valida:faltas.length===0,pendencias:faltas}};}
    if(body.acao==='emitir'){await new Promise(r=>setTimeout(r,80));registro={id:'nota-a',numero:124,serie:'4',status:'pendente',mensagem:'Resposta ainda não confirmada'};return {data:{registro}};}
    if(body.acao==='consultar'){registro={...registro,status:'autorizada',chave_acesso:'chave de teste',protocolo:'protocolo teste'};return {data:{registro}};}
    return {data:{numero:124,conteudo:body.acao==='xml'?'<nfeProc>arquivo-simulado</nfeProc>':btoa('%PDF-1.4 arquivo-simulado')}};
   }}};
   const {instalarAbaNfe55}=await import(url);window.controller=instalarAbaNfe55({document,supabase:client,obterEmpresaId:async()=>empresa,podeAcessar:()=>true,formatarReais:n=>'R$ '+n});await window.controller.abrir();
  },moduleUrl);
  await page.fill('#nfe55-numero','123');await page.click('#nfe55-pesquisar');await page.getByRole('button',{name:'Conferir para NF-e'}).click();await page.locator('#nfe55-confirmar').waitFor();
  assert.equal(await page.locator('#nfe55-transmitir').isDisabled(),true);
  // Seleciona destinatários CNPJ e CPF da mesma empresa, sem alterar a venda.
  await page.getByLabel('Pesquisar destinatário',{exact:true}).fill('Cliente');await page.getByRole('button',{name:'Buscar destinatário',exact:true}).click();
  await page.getByRole('button',{name:'Usar Cliente CNPJ · 11222333000181',exact:true}).click();assert.equal(await page.getByLabel('CPF/CNPJ',{exact:true}).inputValue(),'11222333000181');
  await page.getByLabel('Pesquisar destinatário',{exact:true}).fill('Cliente');await page.getByRole('button',{name:'Buscar destinatário',exact:true}).click();
  await page.getByRole('button',{name:'Usar Cliente CPF · 52998224725',exact:true}).click();assert.equal(await page.getByLabel('CPF/CNPJ',{exact:true}).inputValue(),'52998224725');
  assert.equal(await page.getByRole('button',{name:'Calcular impostos no Dados Já',exact:true}).count(),0);assert.equal(await page.getByText('Consultar listas fiscais oficiais',{exact:true}).count(),0);
  assert.equal(await page.evaluate(()=>window.calls.filter(c=>c.body.acao==='emitir').length),0);
  await page.getByLabel('Natureza da operação',{exact:true}).fill('VENDA DE MERCADORIA');
  await page.locator('#nfe55-confirmar').check();assert.equal(await page.locator('#nfe55-transmitir').isEnabled(),true);
  await page.getByLabel('Natureza da operação',{exact:true}).fill('VENDA CONFERIDA');assert.equal(await page.locator('#nfe55-confirmar').isChecked(),false);
  await page.locator('#nfe55-confirmar').check();await page.click('#nfe55-transmitir');await page.waitForFunction(()=>document.getElementById('nfe55-msg').textContent==='Situação NF-e: pendente');
  assert.equal(await page.locator('#nfe55-transmitir').isDisabled(),true);
  const sent=await page.evaluate(()=>window.calls.find(c=>c.body.acao==='emitir'));assert.equal(await page.locator('#nfe55-serie').inputValue(),'4');assert.equal(sent.name,'fiscal-nfe55');assert.equal(sent.body.venda_id,'venda-a');assert.equal(sent.body.confirmar_producao,true);assert.equal(sent.body.usar_calculo,undefined);assert.equal(sent.body.revisao.sem_acessorios,true);assert.equal(sent.body.conferencia_hash,'hash-simulado');assert.equal(sent.body.revisao.ide.natOp,'VENDA CONFERIDA');assert.equal(sent.body.revisao.itens[0].ncm,'12345678');
  await page.getByRole('button',{name:'Consultar situação',exact:true}).click();await page.getByRole('button',{name:'Baixar XML',exact:true}).waitFor();
  const xmlDownload=page.waitForEvent('download');await page.getByRole('button',{name:'Baixar XML',exact:true}).click();assert.equal((await xmlDownload).suggestedFilename(),'NFE_124.xml');
  const pdfDownload=page.waitForEvent('download');await page.getByRole('button',{name:'Baixar DANFE (PDF)',exact:true}).click();assert.equal((await pdfDownload).suggestedFilename(),'NFE_124.pdf');
  await page.evaluate(()=>{window.mockCrt='1';window.mockVazios=true;window.resetRegistro();});await page.getByRole('button',{name:'Conferir para NF-e'}).click();
  await page.getByText('Dados fiscais dos produtos — carregados do cadastro',{exact:true}).evaluate(s=>s.parentElement.open=true);
  await page.getByLabel('CSOSN (confirmar com responsável fiscal)',{exact:true}).waitFor();
  assert.equal(await page.getByLabel('CSOSN (confirmar com responsável fiscal)',{exact:true}).inputValue(),'102');
  assert.equal(await page.getByLabel('CST ICMS',{exact:true}).count(),0);
  await page.click('#nfe55-confirmar');assert.equal(await page.locator('#nfe55-transmitir').isDisabled(),true);
  assert.match(await page.locator('#nfe55-pendencias').textContent(),/CST de PIS ausente/);assert.doesNotMatch(await page.locator('#nfe55-pendencias').textContent(),/confirmar o JSON/);
  await page.getByLabel('CST PIS',{exact:true}).fill('49');await page.getByLabel('CST COFINS',{exact:true}).fill('49');
  await page.getByLabel('PIS CST 49/99: ausência de destaque conferida com o responsável fiscal.',{exact:true}).check();await page.getByLabel('COFINS CST 49/99: ausência de destaque conferida com o responsável fiscal.',{exact:true}).check();
  await page.locator('#nfe55-confirmar').check();await page.waitForFunction(()=>!document.getElementById('nfe55-transmitir').disabled);
  page.removeAllListeners('dialog');page.once('dialog',d=>d.dismiss());await page.click('#nfe55-transmitir');
  assert.equal(await page.locator('#nfe55-transmitir').isEnabled(),true);
  assert.equal(await page.evaluate(()=>window.calls.filter(c=>['calcular','lista'].includes(c.body.acao)).length),0);
  assert.equal(await page.evaluate(()=>window.calls.filter(c=>c.body.acao==='emitir').length),1);assert.deepEqual(errors,[]);
 }finally{await browser.close();}
});
