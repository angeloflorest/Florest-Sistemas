'use strict';
const {chromium}=require('playwright'),fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
function source(name){const start=html.indexOf('function '+name+'(');assert.ok(start>=0,name);const tail=html.slice(start),end=tail.search(/^}\r?$/m);assert.ok(end>0,name+' fim');return tail.slice(0,end+1)}
(async()=>{const browser=await chromium.launch({headless:true,executablePath:'/usr/bin/chromium'});try{const page=await browser.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));page.on('dialog',d=>d.accept());
 const field=html.match(/<div class="pdx-cpf-nota">[\s\S]*?<\/div>/)[0];
 const fixture=`<!doctype html><html lang="pt-BR"><body>${field}<select id="pdv-cliente"><option value="">Consumidor Final</option><option value="c1">Empresa de teste</option><option value="c2">Pessoa de teste</option></select><input id="pdx-cliente-busca"><div id="pdx-cliente-lista"></div><div id="pdx-modal-cliente"></div><div id="pdx-cliente-nome"></div><div id="pdv-msg"></div><button id="btn-finalizar-venda">Finalizar venda</button></body></html>`;
 await page.route('https://pdv.test/**',r=>r.fulfill({contentType:'text/html',body:fixture}));await page.goto('https://pdv.test/');
 const submit=html.slice(html.indexOf("$('btn-finalizar-venda').addEventListener('click', async () =>"),html.indexOf('// ---------- PDV em tela cheia:'));
 await page.addScriptTag({content:`const $=id=>document.getElementById(id),somenteDigitos=v=>String(v??'').replace(/\\D/g,'');
 let pdvCarrinho=[{produto_id:'produto-teste'}],pdvFinalizando=false,pdvNotaPrazo=false,pdvPagamentos=[{forma:'Dinheiro',centavos:1000}];
 const pdvClientesCpf=new Map([['c1','04252011000110'],['c2','52998224725']]);window.calls=[];
 const pdvMensagem=m=>$('pdv-msg').textContent=m,pdvMontarItensVenda=()=>[{produto_id:'produto-teste',quantidade:1,preco_unitario:10}],pdvTotalCentavosServidor=()=>1000,pdvSomaPagamentos=()=>1000,atualizarTotalPdv=()=>{},atualizarPainelPagamentoPdv=()=>{$('btn-finalizar-venda').disabled=false;},pdxAbrirCliente=()=>{},pdvPrazoLerTentativa=()=>null,pdvPrazoSalvarTentativa=()=>{},pdxNovoId=()=>crypto.randomUUID(),pdvCentavosParaReais=String,escapeHtml=String,focarCampoPdv=()=>{};
 const supabase={rpc:async(name,args)=>{calls.push({name,args});return {data:null,error:{code:'TEST_STOP',message:'Teste sem registro real'}}}};
 ${source('cpfValido')}
 ${source('normalizarDocumentoNota')}
 ${source('cnpjValido')}
 ${source('documentoNotaValido')}
 ${source('pdxValidarCpfNota')}
 ${source('pdxAtualizarClienteRotulo')}
 ${source('pdxRenderClientes')}
 $('pdv-cpf-nota').addEventListener('input',pdxValidarCpfNota);$('pdv-cpf-nota').addEventListener('blur',pdxValidarCpfNota);$('pdx-cliente-busca').oninput=pdxRenderClientes;
 ${source('pdvClienteCadastradoId')}
 ${submit}
 window.setMode=prazo=>{pdvNotaPrazo=prazo;pdvPagamentos=prazo?[]:[{forma:'Dinheiro',centavos:1000}];};
 `});
 for(const [value,expected] of [['04.252.011/0001-10','04252011000110'],['00.000.000/0001-91','00000000000191'],['529.982.247-25','52998224725'],['',null]]){
  await page.getByLabel('CPF/CNPJ na nota:').fill(value);const before=await page.evaluate(()=>calls.length);await page.locator('#btn-finalizar-venda').click();await page.waitForFunction(n=>calls.length===n+1,before);const call=await page.evaluate(()=>calls.at(-1));assert.equal(call.name,'registrar_venda_mista');assert.equal(call.args.p_cpf_nota,expected);
 }
 for(const value of ['04252011000111','123','ABC52998224725']){await page.getByLabel('CPF/CNPJ na nota:').fill(value);const before=await page.evaluate(()=>calls.length);await page.locator('#btn-finalizar-venda').click();assert.equal(await page.evaluate(()=>calls.length),before);assert.match(await page.textContent('#pdx-cpf-nota-erro'),/inválido/)}
 await page.locator('#pdx-cliente-busca').fill('04.252.011/0001-10');assert.equal(await page.locator('#pdx-cliente-lista button').count(),1);await page.getByRole('button',{name:'Empresa de teste',exact:true}).click();assert.equal(await page.getByLabel('CPF/CNPJ na nota:').inputValue(),'04252011000110');assert.equal(await page.getByLabel('CPF/CNPJ na nota:').getAttribute('aria-invalid'),'false');
 await page.evaluate(()=>setMode(true));const before=await page.evaluate(()=>calls.length);await page.locator('#btn-finalizar-venda').click();await page.waitForFunction(n=>calls.length===n+1,before);const prazo=await page.evaluate(()=>calls.at(-1));assert.equal(prazo.name,'registrar_venda_prazo');assert.equal(prazo.args.p_cpf_nota,'04252011000110');assert.deepEqual(errors,[]);
 console.log('PASS: Chromium, campo real, CPF/CNPJ com pontuação e zeros, documento inválido bloqueado, consumidor sem documento, pesquisa/autopreenchimento de CNPJ e envio à vista/a prazo. Nenhuma venda ou nota real.');
 }finally{await browser.close()}})().catch(e=>{console.error(e);process.exit(1)});
